// graidctl: native replacement for "G-RAID with Thunderbolt Configurator" 1.1.
// Talks to the enclosure's ASMedia bridge using its read-sequence protocol (see PROTOCOL.md).
// No driver needed: only 512-byte reads of /dev/rdiskN, as root.

import CryptoKit
import Foundation
import DiskArbitration
import IOKit

// MARK: - Errors and status codes

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

func ackText(_ s: UInt8) -> String {
    switch s {
    case 0x00: return "Command Success"
    case 0x10: return "Command in process"
    case 0x20: return "Command complete without error"
    case 0xC0: return "Command is blocked and can't be executed"
    case 0xD0: return "Subcommand mismatched"
    case 0xE0: return "CRC error"
    case 0xF0: return "Command unsupported"
    case 0xF1: return "Read HDD fail or wrong HDD handle"
    case 0xF2: return "Read Acknowledge data timeout"
    case 0xF3: return "Unknown Error"
    case 0xF4: return "Invalid Status"
    case 0xF5: return "Memory Insufficient"
    case 0xF6: return "Invalid parameters"
    case 0xFF: return "Command failure"
    default: return "Unknown"
    }
}

/// Mirrors GetAckStatus: anything outside the known set becomes 0xF4.
func normalizeAck(_ s: UInt8) -> UInt8 {
    [0x00, 0x10, 0x20, 0xC0, 0xD0, 0xE0, 0xF0, 0xFF].contains(s) ? s : 0xF4
}

func modeText(_ m: UInt8) -> String {
    switch m {
    case 0: return "Individual Disk"
    case 1: return "Performance - RAID 0"
    case 2: return "Protected - RAID 1"
    case 3: return "SPAN"
    case 4: return "SideWinder"
    case 5: return "Split Volumes"
    case 0xF: return "VHDD"
    default: return "Unknown (\(hex(m)))"
    }
}

func volumeStatusText(_ s: UInt8) -> String {
    let t = ["Online", "Degraded", "Rebuilding", "Rebuild Failed", "Data Lost", "Migrating",
             "Verifying", "Verify Failed", "Rebuilding Paused", "Verifying Paused"]
    if s < t.count { return t[Int(s)] }
    if s == 0x10 { return "Not Configured" }
    if s == 0x11 { return "Broken" }
    return "Unknown (\(hex(s)))"
}

func diskStatusText(_ s: UInt8) -> String {
    let t = ["Online", "Rebuilding", "Empty", "Missing", "Blank", "ID Mismatch", "Rejected",
             "Predictive Failure", "Failed", "Spare", "Not Participating", "Verifying", "Migrating"]
    if s < t.count { return t[Int(s)] }
    if s == 0x11 { return "Rebuilding Paused" }
    if s == 0x1B { return "Verifying Paused" }
    return "Unknown (\(hex(s)))"
}

func vhddReasonText(_ r: UInt8) -> String {
    switch r {
    case 0x00: return "No ATA Disk connected"
    case 0x10: return "RAID 0 Offline"
    case 0x11: return "Normal crashed"
    case 0x12: return "RAID 1 disk mismatched"
    case 0x13: return "RAID 1 missing"
    case 0x14: return "SideWinder disk mismatched"
    case 0x15: return "Rejected"
    case 0x20: return "RAID type mismatched"
    case 0x30: return "Force VHDD"
    default: return "Unknown (\(hex(r)))"
    }
}

func hex(_ v: UInt8) -> String { String(format: "0x%02X", v) }

// MARK: - CRC-32 (zlib)

let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
    var c = UInt32(i)
    for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    return c
}

func crc32(_ bytes: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for b in bytes { c = (c >> 8) ^ crcTable[Int((c ^ UInt32(b)) & 0xFF)] }
    return ~c
}

// MARK: - Packet encoding

struct Command {
    var control: [UInt8]      // flags, class, cascade, port
    var command: [UInt8]      // opcode, 0xCF, p1, p2
    var data: [UInt8]? = nil  // 128 bytes for long packets
    var replyLength = 0
    var timeout: TimeInterval = 3

    static let identify = Command(control: [0x00, 0x04, 0xEF, 0xFF], command: [0x10, 0xCF, 0xDF, 0xEF], timeout: 1.5)
    static let capabilities = Command(control: [0x00, 0x04, 0x00, 0x00], command: [0x11, 0xCF, 0xDF, 0xEF], replyLength: 0x48)
    static let raidStatus = Command(control: [0x00, 0x04, 0x00, 0x00], command: [0x15, 0xCF, 0xDF, 0xEF], replyLength: 0xA4)
    static let diskStatus = Command(control: [0x00, 0x04, 0x00, 0x00], command: [0x17, 0xCF, 0xDF, 0xEF], replyLength: 0x180)
    /// Read 128 bytes of the controller's SPI flash (IFCmdReadFlashRom, opcode 0x20, query
    /// class). `address` must be 128-byte aligned and below 8 MB; it travels as address >> 7.
    /// The flash erase (0x23) and write (0x25) commands are deliberately not implemented.
    static func readFlash(address: UInt32, select: UInt8 = 0) -> Command {
        precondition(address % 128 == 0 && address < 0x80_0000)
        let block = UInt16(address >> 7)
        return Command(control: [0x00, 0x04, 0xEF, 0xFF], command: [0x20, select, UInt8(block >> 8), UInt8(block & 0xFF)],
                       replyLength: 0x80, timeout: 2)
    }
    static func modeChange(payload: [UInt8]) -> Command {
        precondition(payload.count == 128)
        return Command(control: [0x01, 0x05, 0x00, 0x00], command: [0xB0, 0xCF, 0x13, 0x88], data: payload, timeout: 8)
    }

    /// The in-memory packet the CRC is computed over.
    var crcInput: [UInt8] {
        [0x43, 0x00, 0x71, 0x00, 0xA7, 0x00, 0xDF, 0x00] + control + command + (data ?? [])
    }

    var crcBytes: [UInt8] {
        let c = crc32(crcInput)
        return [UInt8(c >> 24), UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF)]
    }

    /// Sector numbers to read, in order (before the separator rule is applied).
    var lbas: [UInt32] {
        var out: [UInt32] = [0x43, 0x71, 0xA7, 0xDF]
        out += control.map { UInt32($0) | 0x100 }
        out += command.map { UInt32($0) | 0x200 }
        if let d = data { out += d.map { UInt32($0) | 0x300 } }
        out += crcBytes.map { UInt32($0) | 0x400 }
        return out
    }

    /// The exact read sequence including 0x5FFF separators (SendPhysicalLBA).
    var wireSequence: [UInt32] {
        var out: [UInt32] = []
        var prev: UInt32 = 0
        for l in lbas {
            if l == prev { out.append(separatorLBA) }
            out.append(l)
            prev = l
        }
        return out
    }
}

let separatorLBA: UInt32 = 0x5FFF
let ackLBA: UInt32 = 0x11
let sectorSize = 512

// MARK: - Device I/O

final class Device {
    let path: String
    let fd: Int32
    let buf: UnsafeMutableRawPointer
    var verbose = false
    /// When set, reads go to the simulated controller instead of a disk.
    let simulator: ControllerSimulator?

    /// A device backed by the simulated controller (tests, previews, `--simulate`).
    init(simulator: ControllerSimulator) {
        path = "simulator"
        fd = -1
        self.simulator = simulator
        var p: UnsafeMutableRawPointer?
        posix_memalign(&p, 4096, 4096)
        buf = p!
    }

    init(path: String) throws {
        self.path = path
        simulator = nil
        fd = open(path, O_RDONLY)
        if fd < 0 {
            let e = errno
            var msg = "cannot open \(path): \(String(cString: strerror(e)))"
            if e == EACCES { msg += " (run with sudo)" }
            if e == EPERM { msg += " (macOS needs Full Disk Access for the app running this)" }
            throw ToolError(msg)
        }
        var p: UnsafeMutableRawPointer?
        posix_memalign(&p, 4096, 4096)
        buf = p!
        // Raw devices need block-aligned I/O. The protocol uses 512-byte sectors.
        var bs: UInt32 = 0
        let DKIOCGETBLOCKSIZE: UInt = 0x4004_6418
        if ioctl(fd, DKIOCGETBLOCKSIZE, &bs) == 0, bs != 0, bs != UInt32(sectorSize) {
            close(fd); free(buf)
            throw ToolError("\(path) uses \(bs)-byte blocks; this protocol needs 512-byte sectors")
        }
    }

    deinit { if fd >= 0 { close(fd) }; free(buf) }

    func readSector(_ lba: UInt32) throws {
        if let sim = simulator {
            sim.read(lba).withUnsafeBytes { buf.copyMemory(from: $0.baseAddress!, byteCount: sectorSize) }
            return
        }
        let n = pread(fd, buf, sectorSize, off_t(lba) * off_t(sectorSize))
        if n != sectorSize {
            throw ToolError("read of sector \(String(format: "0x%X", lba)) failed: \(n < 0 ? String(cString: strerror(errno)) : "short read")")
        }
    }

    var sector: [UInt8] { Array(UnsafeRawBufferPointer(start: buf, count: sectorSize)) }

    func send(_ cmd: Command) throws {
        if verbose {
            print("  -> " + cmd.wireSequence.map { String(format: "%X", $0) }.joined(separator: " "))
        }
        for l in cmd.wireSequence { try readSector(l) }
    }

    /// Poll the ack sector until it carries both signatures (GetAckData).
    static let sigA = Array("__ASMEDIA2109A__".utf8), sigB = Array("_PORTMULTIPLIER_".utf8)

    func hasSignature(_ s: [UInt8]) -> Bool {
        Array(s[0..<16]) == Device.sigA && Array(s[0x1F0..<0x200]) == Device.sigB
    }

    /// Poll the ack sector (GetAckData). The controller keeps a single result sector whose
    /// signature stays valid between commands, so a read right after sending can still return
    /// the previous command's reply (seen on real hardware). Wait for the sector to differ from
    /// `baseline`; if it never changes within `unchangedGrace`, the new reply is identical.
    ///
    /// Bytes 0x40-0x4F of the result sector echo the packet that produced it (header, control,
    /// command), confirmed on hardware. A sector echoing a different command is ignored.
    /// An all-zero echo is accepted in case some firmware doesn't fill it in.
    func readAck(timeout: TimeInterval, echo: [UInt8], baseline: [UInt8]?, unchangedGrace: TimeInterval) throws -> (status: UInt8, sector: [UInt8]) {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var sawSignature = false
        repeat {
            try readSector(ackLBA)
            let s = sector
            let echoed = Array(s[0x40..<0x50])
            if hasSignature(s) && (echoed == echo || echoed.allSatisfy { $0 == 0 }) {
                sawSignature = true
                if s != baseline || Date().timeIntervalSince(start) >= unchangedGrace {
                    return (normalizeAck(s[0x30]), s)
                }
            }
            usleep(2000)
        } while Date() < deadline
        // Matching sector present but unchanged for the whole timeout: accept it as the reply.
        return sawSignature ? (normalizeAck(sector[0x30]), sector) : (0xF2, sector)
    }

    /// Last ack sector per opcode, for diagnostics.
    var lastAcks: [UInt8: [UInt8]] = [:]

    /// Send a command and wait for a final ack. Retries up to 3 times like the original
    /// app, but stops early on a timeout (0xF2), as the app does.
    /// One command at a time per process: interleaved packets from two threads would corrupt
    /// each other (the controller decodes one read sequence).
    static let ioLock = NSLock()

    func execute(_ cmd: Command) throws -> (status: UInt8, reply: [UInt8]) {
        Device.ioLock.lock()
        defer { Device.ioLock.unlock() }
        let echo = Array(cmd.crcInput.prefix(16))
        var last: UInt8 = 0xFF
        let grace: TimeInterval = cmd.replyLength > 0 ? 1.0 : 0.3
        for _ in 0..<3 {
            try readSector(ackLBA)
            let baseline = sector
            try send(cmd)
            var (st, sec) = try readAck(timeout: cmd.timeout, echo: echo, baseline: baseline, unchangedGrace: grace)
            // "In process": keep reading the ack sector until it settles.
            let settle = Date().addingTimeInterval(cmd.timeout)
            while st == 0x10 && Date() < settle {
                usleep(50_000)
                (st, sec) = try readAck(timeout: cmd.timeout, echo: echo, baseline: sec, unchangedGrace: 0)
            }
            lastAcks[cmd.command[0]] = sec
            if verbose { print("  <- status \(hex(st)) \(ackText(st))\(sec == baseline ? " (sector unchanged)" : "")") }
            last = st
            if st == 0x20 || (cmd.replyLength == 0 && st == 0x00) {
                let reply = cmd.replyLength > 0 ? Array(sec[0x50..<(0x50 + cmd.replyLength)]) : []
                return (st, reply)
            }
            if st == 0xF2 { break }
        }
        return (last, [])
    }
}

// MARK: - Reply parsing

extension Array where Element == UInt8 {
    func u16be(_ o: Int) -> UInt16 { UInt16(self[o]) << 8 | UInt16(self[o + 1]) }
    func u64be(_ o: Int) -> UInt64 { (0..<8).reduce(0) { $0 << 8 | UInt64(self[o + $1]) } }
    func u64le(_ o: Int) -> UInt64 { (0..<8).reversed().reduce(0) { $0 << 8 | UInt64(self[o + $1]) } }
    func cString(_ o: Int, _ n: Int) -> String {
        let bytes = self[o..<(o + n)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
    /// ATA IDENTIFY strings store each 16-bit word byte-swapped.
    func ataString(_ o: Int, _ n: Int) -> String {
        var out = [UInt8]()
        var i = o
        while i + 1 < o + n { out.append(self[i + 1]); out.append(self[i]); i += 2 }
        return String(decoding: out.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}

struct Capabilities {
    let raw: [UInt8]
    var chipID: UInt8 { raw[0] }
    // Little-endian, unlike the version and block counts: real units report 21 1B = 0x1B21 (ASMedia).
    var vendorID: UInt16 { UInt16(raw[2]) | UInt16(raw[3]) << 8 }
    var deviceID: UInt16 { UInt16(raw[4]) | UInt16(raw[5]) << 8 }
    /// The original app formats with %012llx and keeps the first 12 characters.
    var firmware: String { String(String(format: "%012llx", raw.u64be(8)).prefix(12)) }
    var serial: UInt64 { raw.u64be(16) }
    var currentImage: UInt8 { raw[28] }
    var dualImage: UInt8 { raw[29] }
    var currentMode: UInt8 { raw[36] }
    var swModeChange: UInt8 { raw[37] }
    var modeSupported: UInt16 { raw.u16be(38) }
    var raidSetName: String { raw.cString(49, 15) }
    var uniqueID: String { String(format: "%016llx", raw.u64le(64)) }
}

struct Volume {
    let raw: [UInt8]
    var status: UInt8 { raw[0] }
    var mode: UInt8 { raw[1] }
    var stripeSize: UInt8 { raw[2] }
    var bytesPerBlock: UInt16 { raw.u16be(6) }
    var totalBlocks: UInt64 { raw.u64be(8) }
    /// Rebuild position in the generic ASMedia layout. This firmware leaves it zero.
    var tagLBA: UInt64 { raw.u64be(32) }
}

struct RaidStatus {
    let raw: [UInt8]
    var mode: UInt8 { raw[0] }
    var disks: UInt8 { raw[1] }
    var volumeCount: UInt8 { raw[2] }
    var vhddReason: UInt8 { raw[3] }
    func volume(_ i: Int) -> Volume { Volume(raw: Array(raw[(4 + i * 40)..<(4 + (i + 1) * 40)])) }
}

struct Port {
    let index: Int
    let raw: [UInt8]
    var status: UInt8 { raw[0] }
    var order: UInt8 { raw[1] }
    var model: String { raw.ataString(4, 40) }
    var serial: String { raw.ataString(44, 20) }
    var bytesPerBlock: UInt16 { raw.u16be(66) }
    var totalBlocks: UInt64 { raw.u64be(68) }
    var capacityBytes: Double { Double(bytesPerBlock) * Double(totalBlocks) }
}

struct DiskStatus {
    let raw: [UInt8]
    var mode: UInt8 { raw[0] }
    var ports: UInt8 { raw[1] }
    var disks: UInt8 { raw[2] }
    var allPorts: [Port] { (0..<5).map { Port(index: $0, raw: Array(raw[(4 + $0 * 76)..<(4 + ($0 + 1) * 76)])) } }
    /// Slots the controller says exist. Slots beyond that come back zero-filled.
    var validPorts: [Port] {
        let n = (1...5).contains(Int(ports)) ? Int(ports) : 5
        return Array(allPorts.prefix(n))
    }
    /// Bays with a disk in them: skips Empty (2) and zero-filled slots that decode as "Online".
    var presentPorts: [Port] {
        validPorts.filter { p in p.status != 2 && !(p.status == 0 && p.totalBlocks == 0 && p.model.isEmpty) }
    }
}

func formatBytes(_ b: Double) -> String {
    b >= 1e12 ? String(format: "%.2f TB", b / 1e12) : String(format: "%.1f GB", b / 1e9)
}

// MARK: - Disk discovery

struct Candidate {
    let bsdName: String
    let mediaName: String
    let model: String
    let proto: String
    let isInternal: Bool
    let size: UInt64
    var rawPath: String { "/dev/r" + bsdName }
}

func wholeDisks() -> [Candidate] {
    guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
    let matching = IOServiceMatching("IOMedia") as NSMutableDictionary
    matching["Whole"] = true
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iter) }
    var out: [Candidate] = []
    while case let svc = IOIteratorNext(iter), svc != 0 {
        defer { IOObjectRelease(svc) }
        guard let bsd = IORegistryEntryCreateCFProperty(svc, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String,
            let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd),
            let desc = DADiskCopyDescription(disk) as? [String: Any] else { continue }
        out.append(Candidate(
            bsdName: bsd,
            mediaName: desc[kDADiskDescriptionMediaNameKey as String] as? String ?? "",
            model: (desc[kDADiskDescriptionDeviceModelKey as String] as? String ?? "").trimmingCharacters(in: .whitespaces),
            proto: desc[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? "",
            isInternal: desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? true,
            size: (desc[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.uint64Value ?? 0))
    }
    return out.sorted { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
}

struct Found {
    let candidate: Candidate
    let caps: Capabilities?
}

/// Probe external SATA whole disks (the G-RAID shows up as AHCI/SATA over Thunderbolt).
/// Probing only reads sectors; on a non-G-RAID disk the ack signature simply never appears.
func discover(anyProtocol: Bool, verbose: Bool) -> [Found] {
    var found: [Found] = []
    for c in candidateDisks(anyProtocol: anyProtocol) {
        guard let dev = try? Device(path: c.rawPath) else { continue }
        dev.verbose = verbose
        guard let (st, _) = try? dev.execute(.identify), st == 0x00 || st == 0x20 else { continue }
        let caps = (try? dev.execute(.capabilities)).flatMap { $0.status == 0x20 ? Capabilities(raw: $0.reply) : nil }
        found.append(Found(candidate: c, caps: caps))
    }
    return found
}

func fetchAll(_ dev: Device) throws -> (Capabilities, RaidStatus, DiskStatus) {
    let (s1, r1) = try dev.execute(.capabilities)
    guard s1 == 0x20 else { throw ToolError("GetCapabilities failed: \(hex(s1)) \(ackText(s1))") }
    let (s2, r2) = try dev.execute(.raidStatus)
    guard s2 == 0x20 else { throw ToolError("GetRAIDStatus failed: \(hex(s2)) \(ackText(s2))") }
    let (s3, r3) = try dev.execute(.diskStatus)
    guard s3 == 0x20 else { throw ToolError("GetDiskStatus failed: \(hex(s3)) \(ackText(s3))") }
    return (Capabilities(raw: r1), RaidStatus(raw: r2), DiskStatus(raw: r3))
}

// MARK: - Self-test (no hardware needed)

func selfTest() -> Bool {
    var ok = true
    func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); ok = ok && cond }

    check("crc32 check value", crc32(Array("123456789".utf8)) == 0xCBF4_3926)

    let id = Command.identify
    check("identify packet length", id.lbas.count == 16)
    check("identify header/control/command", Array(id.lbas.prefix(12)) ==
          [0x43, 0x71, 0xA7, 0xDF, 0x100, 0x104, 0x1EF, 0x1FF, 0x210, 0x2CF, 0x2DF, 0x2EF])
    check("identify crc tag", id.lbas.suffix(4).allSatisfy { $0 & 0xF00 == 0x400 })
    check("identify crc matches zlib over 16 bytes", id.crcInput.count == 16)

    let mc = Command.modeChange(payload: [UInt8](repeating: 0, count: 128))
    check("mode change packet length", mc.lbas.count == 144)
    check("mode change crc covers 0x90 bytes", mc.crcInput.count == 0x90)
    // Control "00 00" (0x100,0x100) repeats once, and 128 zero data bytes (0x300) repeat 127 times.
    let seq = mc.wireSequence
    check("separator inserted for repeated sectors", seq.filter { $0 == separatorLBA }.count == 128)

    // Parse a synthetic ack sector.
    var sec = [UInt8](repeating: 0, count: 512)
    sec.replaceSubrange(0..<16, with: Array("__ASMEDIA2109A__".utf8))
    sec.replaceSubrange(0x1F0..<0x200, with: Array("_PORTMULTIPLIER_".utf8))
    sec[0x30] = 0x20
    var caps = [UInt8](repeating: 0, count: 0x48)
    caps.replaceSubrange(8..<16, with: [0, 0, 0x16, 0x05, 0x24, 0x00, 0x01, 0x02])
    caps[36] = 2
    caps.replaceSubrange(49..<55, with: Array("G-RAID".utf8))
    let c = Capabilities(raw: caps)
    check("firmware string", c.firmware == "160524000102")
    check("mode decode", modeText(c.currentMode) == "Protected - RAID 1")
    check("set name decode", c.raidSetName == "G-RAID")
    check("ack status normalization", normalizeAck(0x33) == 0xF4 && normalizeAck(0x20) == 0x20)

    var port = [UInt8](repeating: 0, count: 76)
    port.replaceSubrange(4..<12, with: Array("GHTS0100".utf8)) // "HGST1000" byte-swapped per word
    port.replaceSubrange(66..<68, with: [0x02, 0x00])          // 512
    port.replaceSubrange(68..<76, with: [0, 0, 0, 0, 0x74, 0x70, 0x6D, 0xB0]) // 1953525168 blocks
    let p = Port(index: 0, raw: port)
    check("ATA string swap", p.model == "HGST1000")
    check("disk capacity", abs(p.capacityBytes - 1_000_204_886_016) < 1)

    // Firmware keeps the first 12 hex digits, like the original app.
    var caps2 = [UInt8](repeating: 0, count: 0x48)
    caps2.replaceSubrange(8..<16, with: [0x12, 0x34, 0x27, 0x30, 0x02, 0x11, 0x00, 0x00])
    check("firmware keeps leading digits", Capabilities(raw: caps2).firmware == "123427300211")

    // Seen on real hardware: 2 disks, an Empty slot, then zero-filled slots reading as "Online".
    var ds = [UInt8](repeating: 0, count: 0x180)
    ds[1] = 5; ds[2] = 2
    ds.replaceSubrange(4..<80, with: port)
    ds.replaceSubrange(80..<156, with: port)
    ds[4 + 2 * 76] = 2
    let st = DiskStatus(raw: ds)
    check("zero-filled slots are not disks", st.presentPorts.map(\.index) == [0, 1])
    check("spin state: spinning", describeSpinState([0.011, 0.009, 0.027]).hasPrefix("The drives are spinning"))
    check("spin state: RAID 0 drives wake one at a time", describeSpinState([13.6, 14.6, 0.027]).contains("woke one at a time (13.6 s and 14.6 s)"))

    // --- Simulated controller: the real protocol code against a controller model ---
    let sim = ControllerSimulator()
    sim.staleReads = 3   // the first reads after each command return the previous reply
    let sdev = Device(simulator: sim)
    let idOK = (try? sdev.execute(.identify))?.status == 0x00
    check("simulator: identify", idOK)
    if let (c3, r3, d3) = try? fetchAll(sdev) {
        check("simulator: stale replies rejected, firmware from captured caps", c3.firmware == "140827300211")
        check("simulator: model registry picks TB2", DeviceModel.identify(c3) == .graidTB2)
        check("simulator: ASMedia vendor ID", c3.vendorID == 0x1B21)
        check("simulator: RAID 0 volume size", Double(r3.volume(0).bytesPerBlock) * Double(r3.volume(0).totalBlocks) == 8_001_490_518_016)
        check("simulator: two HGST disks", d3.presentPorts.map(\.model) == ["HGST HUS724040ALE640", "HGST HUS724040ALE640"])
        let payload = modeChangePayload(mode: .raid1, name: "MIRROR", disks: d3)
        let outcome = try? performModeChange(dev: sdev, bsdNames: [], payload: payload)
        check("simulator: mode change accepted", outcome == .accepted)
        if let (c4, r4, _) = try? fetchAll(sdev) {
            check("simulator: now RAID 1 named MIRROR", c4.currentMode == 2 && c4.raidSetName == "MIRROR")
            check("simulator: RAID 1 size follows the firmware formula", r4.volume(0).totalBlocks == 7_813_922_816)
        } else { check("simulator: read after mode change", false) }
    } else {
        check("simulator: fetchAll", false)
    }
    var tb3caps = ControllerSimulator.capturedCaps
    tb3caps.replaceSubrange(8..<10, with: [0x16, 0x05])
    check("model registry picks TB3 for firmware 16…", DeviceModel.identify(Capabilities(raw: tb3caps)) == .graidTB3)
    tb3caps.replaceSubrange(8..<10, with: [0x99, 0x00])
    check("unknown firmware is status-only", !DeviceModel.identify(Capabilities(raw: tb3caps)).canChangeMode)

    // --- Event diff ---
    func diskStatus(_ ports: [UInt8]) -> DiskStatus {
        var d = ControllerSimulator.capturedDisks
        for (i, s) in ports.enumerated() { d[4 + i * 76] = s }
        return DiskStatus(raw: d)
    }
    func snap(mode: UInt8 = 2, vol: UInt8 = 0, ports: [UInt8] = [0, 0]) -> UnitSnapshot {
        var c = ControllerSimulator.capturedCaps; c[36] = mode
        var r = ControllerSimulator.capturedRaid; r[4] = vol
        var d = ControllerSimulator.capturedDisks
        for (i, s) in ports.enumerated() { d[4 + i * 76] = s }
        return UnitSnapshot(id: "u", name: "G-RAID", caps: Capabilities(raw: c), raid: RaidStatus(raw: r), disks: DiskStatus(raw: d))
    }
    let base = ["u": snap()]
    check("diff: no change, no events", diffSnapshots(old: base, new: base, confirmedGone: []).isEmpty)
    check("diff: connect", diffSnapshots(old: [:], new: base, confirmedGone: []).first?.category == .connection)
    let degraded = diffSnapshots(old: base, new: ["u": snap(vol: 1, ports: [0, 3])], confirmedGone: [])
    check("diff: degraded array is critical", degraded.contains { $0.category == .array && $0.severity == .critical })
    check("diff: missing disk is critical", degraded.contains { $0.title == "Disk 2 missing" && $0.severity == .critical })
    let predictive = diffSnapshots(old: base, new: ["u": snap(ports: [7, 0])], confirmedGone: [])
    check("diff: predictive failure", predictive.first?.title == "Disk 1 predicts failure")
    let done = diffSnapshots(old: ["u": snap(vol: 2)], new: base, confirmedGone: [])
    check("diff: rebuild finished", done.first?.title == "Rebuild finished")
    let tb4 = 4.0e12, tb2 = 2.0e12
    let hgst: UInt64 = 7_814_037_167, tb8: UInt64 = 15_628_053_168, tb2b: UInt64 = 3_907_029_168
    check("capacity: RAID 0 matches the real unit", arrayBlocks(.raid0, members: [hgst, hgst]) == 15_627_911_168)
    check("capacity: RAID 1 is one disk less the reserve, rounded", arrayBlocks(.raid1, members: [hgst, hgst]) == 7_813_922_816)
    check("capacity: mismatched RAID 0 uses 2x the smaller disk", arrayBlocks(.raid0, members: [hgst, tb8]) == 15_627_911_168)
    check("capacity: mismatched RAID 1 is the smaller disk", arrayBlocks(.raid1, members: [tb2b, hgst]) == (tb2b - 0x10000) & ~0xFFFF)
    check("capacity: individual keeps everything", arrayBlocks(.individual, members: [hgst, tb2b]) == hgst + tb2b)
    check("capacity: a member smaller than the reserve gives nothing", arrayBlocks(.raid0, members: [hgst, 0x8000]) == 0)
    check("capacity: unused part of the larger disk", modeCapacity(.raid1, members: [tb2b, hgst]).unused == Double((hgst - tb2b) * 512))
    let one = unitNames([(id: "68ca4ea78d27834a", arrayName: "Studio", product: "G-RAID with Thunderbolt")])
    check("names: array name when set", one["68ca4ea78d27834a"] == "Studio")
    let two = unitNames([(id: "68ca4ea78d27834a", arrayName: "G-RAID", product: "G-RAID with Thunderbolt"),
                         (id: "1122334455667788", arrayName: "G-RAID", product: "G-RAID with Thunderbolt")])
    check("names: same names get their ID's last digits", two["68ca4ea78d27834a"] == "G-RAID (834A)" && two["1122334455667788"] == "G-RAID (7788)")
    let clash = unitNames([(id: "69ca4ea78d27834a", arrayName: "G-RAID", product: "P"), (id: "6aca4ea78d17834a", arrayName: "G-RAID", product: "P")])
    check("names: longer suffix when the last digits match", clash["69ca4ea78d27834a"] == "G-RAID (27834A)" && clash["6aca4ea78d17834a"] == "G-RAID (17834A)")
    let ind = unitNames([(id: "68ca4ea78d27834a", arrayName: "", product: "G-RAID with Thunderbolt"),
                         (id: "1122334455667788", arrayName: "Backup", product: "G-RAID with Thunderbolt")])
    check("names: Individual mode uses the product name", ind["68ca4ea78d27834a"] == "G-RAID with Thunderbolt" && ind["1122334455667788"] == "Backup")
    check("replace: missing copy asks for a drive", computeReplaceStep(mode: 2, volumeStatus: 1, bays: [0, nil]) == .insert(bay: 1))
    check("replace: failed drive must come out first", computeReplaceStep(mode: 2, volumeStatus: 1, bays: [8, 0]) == .remove(bay: 0))
    check("replace: a foreign drive waits for the copy", computeReplaceStep(mode: 2, volumeStatus: 1, bays: [0, 5]) == .waiting(bay: 1))
    check("replace: copying names the receiving bay", computeReplaceStep(mode: 2, volumeStatus: 2, bays: [0, 1]) == .copying(bay: 1))
    check("replace: paused and failed", computeReplaceStep(mode: 2, volumeStatus: 8, bays: [0, 0x11]) == .paused(bay: 1) && computeReplaceStep(mode: 2, volumeStatus: 3, bays: [0, 0]) == .failed(bay: nil))
    check("replace: nothing to do when online", computeReplaceStep(mode: 2, volumeStatus: 0, bays: [0, 0]) == nil)
    check("replace: no guide when no copy survives", computeReplaceStep(mode: 2, volumeStatus: 0x11, bays: [8, nil]) == nil)
    // --- Manual rebuild ---
    func rebuildSnap(mode: UInt8 = 2, vol: UInt8 = 1, ports: [UInt8]) -> (caps: Capabilities, raid: RaidStatus, disks: DiskStatus) {
        var c = ControllerSimulator.capturedCaps; c[36] = mode
        var r = ControllerSimulator.capturedRaid; r[4] = vol
        let blocks: UInt64 = 7_813_922_816   // RAID 1 of two 4 TB drives
        for i in 0..<8 { r[4 + 8 + i] = UInt8((blocks >> (56 - 8 * UInt64(i))) & 0xFF) }
        var d = ControllerSimulator.capturedDisks
        for (i, st) in ports.enumerated() { d[4 + i * 76] = st }
        return (Capabilities(raw: c), RaidStatus(raw: r), DiskStatus(raw: d))
    }
    func rebuildCheck(_ u: (caps: Capabilities, raid: RaidStatus, disks: DiskStatus), source: Int) -> String? { rebuildProblem(caps: u.caps, raid: u.raid, disks: u.disks, source: source) }
    check("rebuild: Blank bay 1 from Online bay 2 is allowed", rebuildCheck(rebuildSnap(ports: [4, 0]), source: 1) == nil)
    check("rebuild: never from the stale or blank drive", rebuildCheck(rebuildSnap(ports: [4, 0]), source: 0) != nil)
    check("rebuild: refused when the array is Online", rebuildCheck(rebuildSnap(vol: 0, ports: [0, 0]), source: 1) != nil)
    check("rebuild: refused outside RAID 1", rebuildCheck(rebuildSnap(mode: 1, ports: [4, 0]), source: 1) != nil)
    check("rebuild: refused onto a Failed drive", rebuildCheck(rebuildSnap(ports: [8, 0]), source: 1) != nil)
    check("rebuild: refused while a copy is running", rebuildCheck(rebuildSnap(vol: 2, ports: [1, 0]), source: 1) != nil)
    let rp = rebuildPayload(source: 1, name: "G-RAID", disks: rebuildSnap(ports: [4, 0]).disks)
    check("rebuild payload: RAID 1 with the rebuild flag", rp[0x08] == 2 && rp[0x09] == 0x80 && rp[0x0A] == 0x81)
    check("rebuild payload: source bay 2 onto bay 1", rp[0x1C] == 1 && rp[0x1D] == 0 && Array(rp[0x1E...0x20]) == [2, 5, 5])
    check("rebuild payload: rest as a mode change", Array(rp[0x0C..<0x14]) == [UInt8](repeating: 0, count: 8)
          && Array(rp[0x14..<0x1C]) == [UInt8](repeating: 0xFF, count: 8) && String(decoding: rp[0x5C..<0x62], as: UTF8.self) == "G-RAID")
    check("replace: not for RAID 0", computeReplaceStep(mode: 1, volumeStatus: 0x11, bays: [0, nil]) == nil)
    check("replace: minimum size covers the reserve", arrayBlocks(.raid1, members: [replacementMinBlocks(volumeBlocks: 7_813_922_816)]) == 7_813_922_816)
    check("replace: 4 TB mirror takes about 8 hours", abs(rebuildEstimate(volumeBytes: 4.0e12) - 8 * 3600) < 1)
    check("capacity: same-model disks a few sectors apart aren't mismatched", !disksMismatched([4_000_787_030_016, 4_000_785_104_896]))
    check("capacity: 4 TB + 2 TB is mismatched", disksMismatched([tb4, tb2]))

    // Gaps found in the original Configurator (2026-11-08).
    let twoOnline = diskStatus([0, 0])
    check("name: forbidden characters rejected for RAID", modeChangeProblem(mode: .raid1, name: "My,Array", disks: twoOnline) != nil)
    check("name: plain name accepted", modeChangeProblem(mode: .raid0, name: "Studio-01", disks: twoOnline) == nil)
    check("name: ignored for Individual", modeChangeProblem(mode: .individual, name: "a$b", disks: twoOnline) == nil)
    check("spare: accepted for RAID 1", modeChangeProblem(mode: .raid1, name: "G-RAID", disks: diskStatus([0, 9])) == nil)
    check("spare: refused for Individual", modeChangeProblem(mode: .individual, name: "", disks: diskStatus([0, 9])) != nil)
    check("raid1 status: Online with a Missing member reads Degraded", effectiveVolumeStatus(mode: 2, volumeStatus: 0, portStatuses: [0, 3]) == 1)
    check("raid1 status: no surviving member reads Broken", effectiveVolumeStatus(mode: 2, volumeStatus: 0, portStatuses: [3, 3]) == 0x11)
    check("raid1 status: healthy stays Online", effectiveVolumeStatus(mode: 2, volumeStatus: 0, portStatuses: [0, 0]) == 0)
    check("raid1 status: Online with a Failed member reads Degraded", effectiveVolumeStatus(mode: 2, volumeStatus: 0, portStatuses: [0, 8]) == 1)
    check("raid1 status: failing-but-readable copy keeps it Degraded, not Broken", effectiveVolumeStatus(mode: 2, volumeStatus: 0, portStatuses: [7, 8]) == 1)
    check("raid1 status: predictive failure alone stays Online", effectiveVolumeStatus(mode: 2, volumeStatus: 0, portStatuses: [7, 0]) == 0)
    check("raid0 status: untouched", effectiveVolumeStatus(mode: 1, volumeStatus: 0, portStatuses: [0, 3]) == 0)
    let rf = Command.readFlash(address: 0x1F80)
    check("flash read: query class, opcode 0x20, address >> 7", rf.control == [0x00, 0x04, 0xEF, 0xFF] && rf.command == [0x20, 0x00, 0x00, 0x3F])
    let dump = (try? readFlash(dev: sdev, size: 0x400)) ?? []
    check("flash read: simulator returns 1 KB that matches its flash", dump.count == 0x400 && dump == Array(ControllerSimulator.flash.prefix(0x400)))
    check("flash read: no erase or write commands were sent", !sim.executedOpcodes.contains(where: { $0 == 0x23 || $0 == 0x25 }))
    check("wake: simulator answers identify", wakeDisks(primary: sdev, otherPaths: []) == ["simulator"])
    check("partition: EFI is system", classifyPartition(content: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", volumeKind: "msdos", apfsRoles: []) == .system)
    check("partition: Microsoft Reserved is system", classifyPartition(content: "E3C9E316-0B5C-4DB8-817D-F92DF00215AE", volumeKind: nil, apfsRoles: []) == .system)
    check("partition: Apple_Boot by name is system", classifyPartition(content: "Apple_Boot", volumeKind: "hfs", apfsRoles: []) == .system)
    check("partition: exFAT data is a volume", classifyPartition(content: "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", volumeKind: "exfat", apfsRoles: []) == .volume)
    check("partition: APFS Data role is a volume", classifyPartition(content: "41504653-0000-11AA-AA11-00306543ECAC", volumeKind: "apfs", apfsRoles: ["Data"]) == .volume)
    check("partition: APFS Preboot role is system", classifyPartition(content: "41504653-0000-11AA-AA11-00306543ECAC", volumeKind: "apfs", apfsRoles: ["Preboot"]) == .system)
    check("partition: ext4 is unreadable", classifyPartition(content: "0FC63DAF-8483-4772-8E79-3D69D8477DE4", volumeKind: nil, apfsRoles: []) == .unreadable)
    check("partition: format name for Linux swap", formatName(volumeType: nil, volumeKind: nil, content: "0657FD6D-A4AB-43C4-84E5-0933C84B4F4F") == "Linux swap")
    check("partition: format name prefers DA volume type", formatName(volumeType: "MS-DOS (FAT32)", volumeKind: "msdos", content: "") == "MS-DOS (FAT32)")
    check("drive model: vendor word split", splitDriveModel("HGST HUS724040ALE640 ") == ("HGST", "HUS724040ALE640"))
    check("drive model: multi-word rest", splitDriveModel("Samsung SSD 870 EVO 1TB") == ("Samsung", "SSD 870 EVO 1TB"))
    check("drive model: no vendor word", splitDriveModel("ST4000DM004-2CV104") == (nil, "ST4000DM004-2CV104"))
    check("drive model: leading word with digits is not a vendor", splitDriveModel("CT500 MX500SSD1") == (nil, "CT500 MX500SSD1"))
    check("drive size: 4 TB drive", driveSizeText(7_814_037_168 * 512) == "4 TB")
    check("drive size: tenths for comparison", driveSizeText(7_814_037_168 * 512, tenths: true) == "4.0 TB" && driveSizeText(3.94e12, tenths: true) == "3.9 TB")
    check("drive size: 500 GB and 12 TB", driveSizeText(500.1e9) == "500 GB" && driveSizeText(12.0004e12) == "12 TB")
    check("diff: disconnect only when confirmed", diffSnapshots(old: base, new: [:], confirmedGone: []).isEmpty
          && diffSnapshots(old: base, new: [:], confirmedGone: ["u"]).first?.title == "Disconnected")
    return ok
}


// MARK: - Mode change (shared by CLI and app)

enum TargetMode: UInt8, CaseIterable, Identifiable {
    case individual = 0, raid0 = 1, raid1 = 2
    var id: UInt8 { rawValue }
    /// What the mode is for, in plain words. Shown as the mode's name.
    var name: String {
        switch self {
        case .individual: return "Individual"
        case .raid0: return "Performance"
        case .raid1: return "Protected"
        }
    }
    /// The technical term, shown as a chip beside the name.
    var chip: String {
        switch self {
        case .individual: return "JBOD"
        case .raid0: return "RAID 0"
        case .raid1: return "RAID 1"
        }
    }
    /// For running text: "Performance (RAID 0)".
    var label: String { "\(name) (\(chip))" }
    var detail: String {
        switch self {
        case .individual: return "Each disk appears as its own volume."
        case .raid0: return "Performance: both disks striped into one volume. No protection."
        case .raid1: return "Protected: both disks mirrored. Half the total capacity."
        }
    }
}

/// Expected usable space for a mode with these disk sizes, and how much of the disks would go
/// unused. An estimate: the controller decides the real size (the ModeChange command carries no
/// sizes). Striping and mirroring can only use as much of each disk as the smallest one holds.
/// The volume size the controller creates, in blocks, from each member's block count. This is
/// the firmware's own formula (COMPUTE_ARRAY_SIZE 0x9FBE, see FIRMWARE.md "Capacity"), which
/// reproduces the real unit's RAID 0 size exactly. It reserves 0x10000 blocks (32 MiB) on each
/// member and, for RAID 0 and RAID 1, rounds down to a 32 MiB boundary. Mismatched members are
/// sized by the smallest one. Assumes the flash config's ALIGN flag is clear, as on the units seen.
func arrayBlocks(_ mode: TargetMode, members: [UInt64]) -> UInt64 {
    let reserve: UInt64 = 0x10000, mask: UInt64 = ~0xFFFF
    guard let smallest = members.min() else { return 0 }
    switch mode {
    case .individual: return members.reduce(0, +)
    case .raid0, .raid1:
        guard smallest > reserve else { return 0 }
        let member = smallest - reserve
        return (mode == .raid0 ? member * UInt64(members.count) : member) & mask
    }
}

/// What a mode would give with these disks, in bytes, and how much of the larger disks it leaves
/// unused (RAID 0 and RAID 1 only use as much of each disk as the smallest one has).
func modeCapacity(_ mode: TargetMode, members: [UInt64], bytesPerBlock: UInt64 = 512) -> (usable: Double, unused: Double) {
    guard let smallest = members.min() else { return (0, 0) }
    let usable = Double(arrayBlocks(mode, members: members) * bytesPerBlock)
    let unused = mode == .individual ? 0 : Double((members.reduce(0, +) - smallest * UInt64(members.count)) * bytesPerBlock)
    return (usable, unused)
}

/// What to call each connected unit: its array name (chosen in Change RAID Mode and stored on the
/// unit), or the product name in Individual mode, which has none. When two units would share a
/// name, each gets the last four digits of its unique ID, which never change (unlike disk numbers).
func unitNames(_ units: [(id: String, arrayName: String, product: String)]) -> [String: String] {
    func base(_ u: (id: String, arrayName: String, product: String)) -> String {
        let n = u.arrayName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? u.product : n
    }
    var out: [String: String] = [:]
    for group in Dictionary(grouping: units, by: { base($0).lowercased() }).values {
        guard group.count > 1 else { out[group[0].id] = base(group[0]); continue }
        // Four digits, or more if those happen to match.
        let length = (4...16).first { k in Set(group.map { $0.id.suffix(k) }).count == group.count } ?? 16
        for u in group { out[u.id] = "\(base(u)) (\(u.id.suffix(length).uppercased()))" }
    }
    return out
}

/// Where replacing a RAID 1 drive stands, read from what the controller reports. The controller
/// starts the copy by itself as soon as a drive goes into the empty bay of a degraded RAID 1,
/// even a drive that isn't a member (FIRMWARE.md "Rebuild"), so the app only guides and watches.
enum ReplaceStep: Equatable {
    case remove(bay: Int)     // a failed or rejected drive is still in the bay
    case insert(bay: Int)     // the bay is empty, or its drive stopped answering
    case waiting(bay: Int)    // a drive is in, but the copy hasn't started
    case copying(bay: Int?)
    case paused(bay: Int?)
    case failed(bay: Int?)

    var bay: Int? {
        switch self {
        case .remove(let b), .insert(let b), .waiting(let b): return b
        case .copying(let b), .paused(let b), .failed(let b): return b
        }
    }
}

/// `volumeStatus` is the effective status; `bays` holds each bay's disk status, nil when empty.
/// Nil when nothing needs replacing, or when no copy survives (Broken: a rebuild can't help).
func computeReplaceStep(mode: UInt8, volumeStatus: UInt8, bays: [UInt8?]) -> ReplaceStep? {
    guard mode == 2 else { return nil }
    let receiving = bays.firstIndex { $0 == 1 || $0 == 0x11 }
    switch volumeStatus {
    case 2: return .copying(bay: receiving)
    case 8: return .paused(bay: receiving)
    case 3: return .failed(bay: receiving)
    default: break
    }
    if let b = receiving { return bays[b] == 0x11 ? .paused(bay: b) : .copying(bay: b) }
    guard volumeStatus == 1 else { return nil }
    if let b = bays.firstIndex(where: { $0 == 6 || $0 == 8 }) { return .remove(bay: b) }
    if let b = bays.firstIndex(where: { $0 == nil || $0 == 3 }) { return .insert(bay: b) }
    if let b = bays.firstIndex(where: { $0 == 4 || $0 == 5 || $0 == 9 || $0 == 0xA }) { return .waiting(bay: b) }
    return nil
}

/// The smallest drive, in blocks, that can take a RAID 1 member's place: the controller reserves
/// 0x10000 blocks per member, and the volume is already rounded, so this many blocks is enough.
func replacementMinBlocks(volumeBlocks: UInt64) -> UInt64 { volumeBlocks + 0x10000 }

/// A rough rebuild time: the G-RAID manuals give about 2 hours per TB of the mirrored volume.
func rebuildEstimate(volumeBytes: Double) -> TimeInterval { volumeBytes / 1e12 * 2 * 3600 }

/// The volume status to show. For RAID 1 the controller can keep saying Online while a member is
/// Missing; the original then reports Degraded (a copy survives) or Broken (none does). A member
/// that is Failed, ID Mismatch or Rejected holds no usable copy either, so it counts the same.
func effectiveVolumeStatus(mode: UInt8, volumeStatus: UInt8, portStatuses: [UInt8]) -> UInt8 {
    let lost: Set<UInt8> = [3, 5, 6, 8]
    // Still a full copy: Online, Predictive Failure (failing but readable), Verifying, Migrating.
    let holdsCopy: Set<UInt8> = [0, 7, 0xB, 0xC, 0x1B]
    guard mode == 2, volumeStatus == 0, portStatuses.contains(where: lost.contains) else { return volumeStatus }
    return portStatuses.contains(where: holdsCopy.contains) ? 1 : 0x11
}

// MARK: - Drive labels
// Neutral by design: everything comes from what every drive reports (model text, serial,
// sector count). No tables of known models or vendors.

/// Splits an ATA model string that follows the "VENDOR MODEL" convention ("HGST HUS724040ALE640")
/// into its vendor word and the rest. Strings without a leading vendor word ("ST4000DM004-2CV104")
/// come back whole, with no vendor.
func splitDriveModel(_ model: String) -> (vendor: String?, model: String) {
    let t = model.trimmingCharacters(in: .whitespaces)
    guard let space = t.firstIndex(of: " ") else { return (nil, t) }
    let first = String(t[..<space])
    let rest = t[space...].trimmingCharacters(in: .whitespaces)
    guard !rest.isEmpty, (2...12).contains(first.count), first.allSatisfy(\.isLetter) else { return (nil, t) }
    return (first, rest)
}

/// A drive's size the way drives are sold: decimal units, "4 TB", "3.9 TB", "500 GB".
/// `tenths` keeps one decimal place below 10 so two slightly different drives read differently.
func driveSizeText(_ bytes: Double, tenths: Bool = false) -> String {
    guard bytes > 0 else { return "—" }
    let (v, unit) = bytes >= 1e12 ? (bytes / 1e12, "TB") : bytes >= 1e9 ? (bytes / 1e9, "GB") : (bytes / 1e6, "MB")
    if v >= 10 { return String(format: "%.0f %@", v.rounded(), unit) }
    var s = String(format: "%.1f", v)
    if !tenths && s.hasSuffix(".0") { s.removeLast(2) }
    return "\(s) \(unit)"
}

/// True when the disks differ by more than 1 % (same-model disks vary by a few sectors).
func disksMismatched(_ sizes: [Double]) -> Bool {
    guard let lo = sizes.min(), let hi = sizes.max(), lo > 0 else { return false }
    return (hi - lo) / lo > 0.01
}

/// The same preconditions the original app enforces. Returns nil when the change is allowed.
func modeChangeProblem(mode: TargetMode, name: String, disks: DiskStatus) -> String? {
    let present = disks.presentPorts
    if mode != .individual && present.count < 2 { return "RAID 0 and RAID 1 need two disks; found \(present.count)." }
    if present.isEmpty { return "No disks are installed." }
    // Online, Rebuilding, Blank; for RAID 0/1 the original also takes a Spare.
    let ok: Set<UInt8> = mode == .individual ? [0, 1, 4] : [0, 1, 4, 9]
    if let bad = present.first(where: { !ok.contains($0.status) }) {
        let allowed = mode == .individual ? "Online, Rebuilding or Blank" : "Online, Rebuilding, Spare or Blank"
        return "Disk \(bad.index + 1) is \(diskStatusText(bad.status)). Only \(allowed) disks can be reconfigured."
    }
    // Individual mode has no array name (the original disables the field).
    guard mode != .individual else { return nil }
    if name.utf8.count > 15 || !name.allSatisfy({ $0.isASCII }) { return "The array name must be at most 15 ASCII characters." }
    if let bad = name.first(where: { forbiddenNameCharacters.contains($0) }) {
        return "The array name can't contain \(bad). Avoid these characters: \(String(forbiddenNameCharacters))"
    }
    return nil
}

/// Characters the original Configurator refuses in a RAID set name.
let forbiddenNameCharacters: [Character] = Array("!@#$%^&*(){}\"',")

/// The 128-byte block built by -[AppDelegate ModeChange_thread].
func modeChangePayload(mode: TargetMode, name: String, disks: DiskStatus) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: 128)
    p[0x01] = disks.disks
    p[0x02] = 0x01
    p[0x08] = mode.rawValue
    p[0x09] = 0x80
    p[0x0A] = 0x80
    for i in 0x14..<0x1C { p[i] = 0xFF }
    p.replaceSubrange(0x1C...0x20, with: [0x00, 0x01, 0x02, 0x05, 0x05])
    for (i, b) in name.utf8.prefix(15).enumerated() { p[0x5C + i] = b }
    return p
}

/// Why a manual rebuild can't run, or nil. A rebuild copies the source bay (0 or 1) onto the
/// other bay of a degraded RAID 1. The source must be Online; the other bay must hold a disk the
/// controller isn't using (Blank, ID Mismatch, Rejected, Spare or Not Participating) that's big enough.
func rebuildProblem(caps: Capabilities, raid: RaidStatus, disks: DiskStatus, source: Int) -> String? {
    guard caps.currentMode == 2 else { return "A rebuild only applies to Protected (RAID 1). This G-RAID is \(modeText(caps.currentMode))." }
    let volume = raid.volume(0)
    guard volume.status == 1 else { return "The array is \(volumeStatusText(volume.status)), not Degraded, so there's nothing to rebuild." }
    guard source == 0 || source == 1 else { return "The source must be Bay 1 or Bay 2." }
    let present = disks.presentPorts
    guard let src = present.first(where: { $0.index == source }) else { return "Bay \(source + 1) is empty; the source must hold the good copy." }
    guard src.status == 0 else { return "Bay \(source + 1) is \(diskStatusText(src.status)). The source must be Online: it's the copy that's kept." }
    guard let dst = present.first(where: { $0.index == 1 - source }) else { return "Bay \(2 - source) is empty. Insert the drive to copy onto first." }
    guard [4, 5, 6, 9, 0xA].contains(dst.status) else {
        return "Bay \(2 - source) is \(diskStatusText(dst.status)). Only a Blank, Rejected, ID Mismatch, Spare or Not Participating drive can be copied onto."
    }
    let need = replacementMinBlocks(volumeBlocks: volume.totalBlocks)
    guard dst.totalBlocks >= need else {
        return "The drive in Bay \(2 - source) is too small: \(formatBytes(dst.capacityBytes)), and the copy needs \(formatBytes(Double(need) * Double(dst.bytesPerBlock)))."
    }
    return nil
}

/// The old app's Rebuild_thread: a normal ModeChange to RAID 1 with payload[0x0A] = 0x81 (the
/// rebuild flag, so the source member's data is kept) and the copy direction at 0x1C/0x1D
/// (FIRMWARE.md "Rebuild").
func rebuildPayload(source: Int, name: String, disks: DiskStatus) -> [UInt8] {
    var p = modeChangePayload(mode: .raid1, name: name, disks: disks)
    p[0x0A] = 0x81
    p[0x1C] = UInt8(source)
    p[0x1D] = UInt8(1 - source)
    return p
}

func unmountDisk(_ bsd: String) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    p.arguments = ["unmountDisk", bsd]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 { throw ToolError("Could not unmount \(bsd). Close any apps using it and try again.") }
}

enum ModeChangeOutcome { case accepted, noAck }

/// Unmounts every disk on the controller, then sends ModeChange.
/// Running copies of the 2017 Configurator. It talks to the same control sectors, so two
/// programs at once could interleave commands. Matched by executable path (no AppKit needed).
func oldConfiguratorRunning() -> Bool {
    let n = proc_listallpids(nil, 0)
    guard n > 0 else { return false }
    var pids = [pid_t](repeating: 0, count: Int(n) + 32)
    let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard got > 0 else { return false }
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    for pid in pids.prefix(Int(got)) where pid > 0 {
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
        if String(cString: buf).hasSuffix("/Contents/MacOS/G-RAID with Thunderbolt Configurator") { return true }
    }
    return false
}

let oldConfiguratorText = "The old G-RAID with Thunderbolt Configurator is open. Quit it first: two programs sending commands to the G-RAID at once could mix them up."

/// Wake every disk node before a mode change, like the original's -[AppDelegate WakeUpDisk]:
/// an ATA IDENTIFY to each node so sleeping drives spin up first. Returns the nodes that answered.
@discardableResult
func wakeDisks(primary: Device, otherPaths: [String]) -> [String] {
    func wake(_ dev: Device) -> Bool {
        // One retry: a drive that was asleep may miss the first reply while it spins up.
        for attempt in 0..<2 {
            if let (st, _) = try? dev.execute(.identify), st == 0x00 || st == 0x20 { return true }
            if attempt == 0 { Thread.sleep(forTimeInterval: 2) }
        }
        return false
    }
    var awake: [String] = []
    if wake(primary) { awake.append(primary.path) }
    for path in Set(otherPaths).subtracting([primary.path]).sorted() {
        if let dev = try? Device(path: path), wake(dev) { awake.append(path) }
    }
    return awake
}

func performModeChange(dev: Device, bsdNames: [String], payload: [UInt8]) throws -> ModeChangeOutcome {
    if oldConfiguratorRunning() { throw ToolError(oldConfiguratorText) }
    let awake = wakeDisks(primary: dev, otherPaths: bsdNames.map { "/dev/r\($0)" })
    guard awake.contains(dev.path) else { throw ToolError("The G-RAID didn't respond after waking its disks. Nothing was changed; try again in a minute.") }
    for d in Set(bsdNames).sorted() { try unmountDisk(d) }
    let (st, _) = try dev.execute(.modeChange(payload: payload))
    switch st {
    case 0x00, 0x20: return .accepted
    case 0xF2: return .noAck
    default: throw ToolError("Mode change failed: \(hex(st)) \(ackText(st))")
    }
}

// MARK: - Firmware dump (read-only)

func sha256Hex(_ bytes: [UInt8]) -> String { SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined() }

/// Size the original app reads for a full image: 0xF000 (single image) or 0x1F000 (dual).
let firmwareDumpDefaultSize: UInt32 = 0x1F000

/// Read `size` bytes of controller flash from address 0, 128 bytes per command, each block
/// retried up to 3 times. Only the read command is used.
func readFlash(dev: Device, size: UInt32, progress: ((UInt32) -> Void)? = nil) throws -> [UInt8] {
    precondition(size % 128 == 0)
    var out: [UInt8] = []
    out.reserveCapacity(Int(size))
    var addr: UInt32 = 0
    while addr < size {
        var block: [UInt8]?
        var lastStatus: UInt8 = 0
        for _ in 0..<3 {
            let (st, reply) = try dev.execute(.readFlash(address: addr))
            lastStatus = st
            if st == 0x20, reply.count == 128 { block = reply; break }
        }
        guard let b = block else {
            throw ToolError("Flash read failed at \(String(format: "0x%05X", addr)): \(hex(lastStatus)) \(ackText(lastStatus))")
        }
        out += b
        addr += 128
        if addr % 0x1000 == 0 { progress?(addr) }
    }
    return out
}

// MARK: - Access for a non-root GUI

/// External whole disks that could be a G-RAID (AHCI/SATA over Thunderbolt).
func candidateDisks(anyProtocol: Bool = false) -> [Candidate] {
    let skip: Set<String> = ["Disk Image", "Virtual Interface", "USB"]
    return wholeDisks().filter { c in
        !c.isInternal && (anyProtocol ? !skip.contains(c.proto) : c.proto == "SATA")
    }
}

/// Run as root: identify G-RAID disks and make only their raw nodes readable by `uid`
/// (owner read-only, so no other account can read them and nobody can write through them).
/// devfs resets this when the disk reconnects.
func grantAccess(uid: uid_t, anyProtocol: Bool) -> [Found] {
    let found = discover(anyProtocol: anyProtocol, verbose: false)
    for f in found {
        chown(f.candidate.rawPath, uid, gid_t(5)) // group operator, as devfs creates it
        chmod(f.candidate.rawPath, 0o400)
    }
    return found
}

// MARK: - Thunderbolt presence

/// G-RAID enclosures on the Thunderbolt bus, by model name. They show up here as soon as the
/// cable is in, about 30 seconds before their disk appears.
func graidsOnThunderbolt() -> [String] {
    let match = IOServiceMatching("IOService") as NSMutableDictionary
    match[kIOPropertyMatchKey] = ["Device Vendor Name": "G-Technology"]
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(it) }
    var names: [String] = []
    while case let s = IOIteratorNext(it), s != 0 {
        defer { IOObjectRelease(s) }
        guard let name = IORegistryEntryCreateCFProperty(s, "Device Model Name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String, name.localizedCaseInsensitiveContains("G-RAID") else { continue }
        if !names.contains(name) { names.append(name) }
    }
    return names
}

// MARK: - Spin state (read latency)

/// Times reads of random sectors on the raw disk. A spun-down drive takes seconds to answer
/// the first read (it has to spin up); a spinning one answers in milliseconds. Random,
/// far-apart sectors keep the controller's cache from answering instead of the drives.
/// Holds the controller lock so it can't land in the middle of a command packet.
func measureReadLatency(path: String, samples: Int = 3) throws -> [Double] {
    Device.ioLock.lock()
    defer { Device.ioLock.unlock() }
    let fd = open(path, O_RDONLY)
    if fd < 0 {
        let e = errno
        throw ToolError("cannot open \(path): \(String(cString: strerror(e)))\(e == EPERM ? " (needs Full Disk Access)" : "")")
    }
    defer { close(fd) }
    var blocks: UInt64 = 0
    let DKIOCGETBLOCKCOUNT: UInt = 0x4008_6419
    guard ioctl(fd, DKIOCGETBLOCKCOUNT, &blocks) == 0, blocks > 2_000_000 else { throw ToolError("couldn't read the disk size") }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 4096)
    defer { buf.deallocate() }
    var times: [Double] = []
    for _ in 0..<samples {
        let lba = UInt64.random(in: 1_000_000..<(blocks - 16)) & ~UInt64(7)   // 4 KB aligned
        let t0 = DispatchTime.now().uptimeNanoseconds
        let n = pread(fd, buf, 4096, off_t(lba * 512))
        let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        if n != 4096 { throw ToolError("read failed: \(n < 0 ? String(cString: strerror(errno)) : "short read")") }
        times.append(dt)
    }
    return times
}

/// Plain-language reading of `measureReadLatency`. In RAID 0 each random read lands on one
/// drive, and each drive spins up separately, so several slow reads are normal (seen on
/// hardware: 13.6 s and 14.6 s, then 27 ms).
func describeSpinState(_ t: [Double]) -> String {
    func ms(_ s: Double) -> String { s >= 1 ? String(format: "%.1f s", s) : String(format: "%.0f ms", s * 1000) }
    guard !t.isEmpty else { return "No measurement." }
    let slow = t.filter { $0 > 2.0 }, fast = t.filter { $0 <= 0.3 }
    if !slow.isEmpty {
        let woke = slow.count > 1 ? "the drives woke one at a time (\(slow.map(ms).joined(separator: " and ")))"
                                  : "the first read took \(ms(slow[0])) while they spun up"
        let after = fast.isEmpty ? "" : ", then reads were back to \(fast.map(ms).joined(separator: ", "))"
        return "The drives were spun down: \(woke)\(after). This check woke them."
    }
    if let first = t.first, first > 0.3 {
        return "The drives were idle: the first read took \(ms(first)) (then \(t.dropFirst().map(ms).joined(separator: ", "))), slower than normal but too quick for a spin-up."
    }
    return "The drives are spinning: reads took \(t.map(ms).joined(separator: ", "))."
}

// MARK: - Disk activity (IORegistry counters; never touches the disk)

/// Read and write operation counts for a whole disk, from its `IOBlockStorageDriver`'s
/// Statistics. Reading them doesn't wake the drives. nil if the disk isn't found.
struct IOCounters: Equatable {
    let reads: UInt64
    let writes: UInt64
}

func ioCounters(bsd: String) -> IOCounters? {
    guard let match = IOBSDNameMatching(kIOMainPortDefault, 0, bsd) else { return nil }
    let media = IOServiceGetMatchingService(kIOMainPortDefault, match)
    guard media != 0 else { return nil }
    defer { IOObjectRelease(media) }
    var parent: io_registry_entry_t = 0
    guard IORegistryEntryGetParentEntry(media, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(parent) }
    guard let stats = IORegistryEntryCreateCFProperty(parent, "Statistics" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? [String: Any] else { return nil }
    func n(_ k: String) -> UInt64 { (stats[k] as? NSNumber)?.uint64Value ?? 0 }
    return IOCounters(reads: n("Operations (Read)"), writes: n("Operations (Write)"))
}

/// Counters for several whole disks; nil if any can't be read (treat as "activity").
func ioCounters(bsdNames: [String]) -> [String: IOCounters]? {
    var out: [String: IOCounters] = [:]
    for b in bsdNames { guard let c = ioCounters(bsd: b) else { return nil }; out[b] = c }
    return out
}
