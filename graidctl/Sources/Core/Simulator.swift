// Simulated G-RAID controller and model registry. The simulator lets the protocol code,
// monitoring and mode-change flows be tested without touching real hardware.

import Foundation

// MARK: - Models

/// Devices that answer the ASMedia protocol. The 2017 Configurator tells them apart by the
/// first two hex digits of the firmware version (-[AppDelegate AddDevlist_thread:]).
struct DeviceModel: Equatable {
    let name: String
    let firmwarePrefix: String?
    let image: String
    /// Confirmed on real hardware.
    let verified: Bool
    let canChangeMode: Bool

    static let graidTB2 = DeviceModel(name: "G-RAID with Thunderbolt", firmwarePrefix: "14",
                                      image: "Img_Device_GRAID", verified: true, canChangeMode: true)
    static let graidTB3 = DeviceModel(name: "G-RAID with Thunderbolt 3", firmwarePrefix: "16",
                                      image: "Img_Device_GRAID", verified: false, canChangeMode: true)
    /// Answers the protocol but with a firmware family we haven't seen: status only.
    static let unknown = DeviceModel(name: "G-RAID", firmwarePrefix: nil,
                                     image: "Img_Device_GRAID", verified: false, canChangeMode: false)

    static let known: [DeviceModel] = [.graidTB2, .graidTB3]

    static func identify(_ caps: Capabilities) -> DeviceModel {
        known.first { caps.firmware.hasPrefix($0.firmwarePrefix ?? "-") } ?? .unknown
    }
}

// MARK: - Simulator

/// Answers sector reads the way the real controller does: it decodes the read-sequence
/// packets, checks the CRC, and writes replies into the shared result sector (LBA 0x11)
/// with the request echoed at 0x40. Each reply only overwrites its own length, and
/// `staleReads` makes the first reads after a command return the previous buffer, which is
/// the race seen on real hardware.
final class ControllerSimulator {
    // Replies captured from a real G-RAID with Thunderbolt (RAID 0, 2 × HGST 4 TB), 2026-11-07.
    static let capturedCaps = hexBytes(
        "0102211b9210000014082730021100007278f58a240eedbe00000000010000ff0000000001000f0001000000ffffff00" +
        "00472d5241494400000000000000000068ca4ea78d27834a")
    static let capturedRaid = hexBytes(
        "010200c7000103001408020000000003a37f0000240eedbe00000000010000ff000000000000000000000000ffffff00" +
        "00472d5241494400000000000000000068ca4ea78d27834a000000000000000000000000000000000000000000000000" +
        "000000000000000000000000000000000000000000000000000000000000000020204b503331343345504e4853565353" +
        "0000020000000001d1c0beaf02ff000026297b45")
    static let capturedDisks = hexBytes(
        "010202000000000047485453482053553237303430344c41364530342020202020202020202020202020202020202020" +
        "2020202020204b503331343345505448553453390000020000000001d1c0beaf00010000474854534820535532373034" +
        "30344c413645303420202020202020202020202020202020202020202020202020204b503331343345504e4853565353" +
        "0000020000000001d1c0beaf02ff000026297b45c5bc2e516ca3c87a54e105db76febf3afee0386ffda839b7d9538faa" +
        "cf2ffe87779a686153cfa8bb74d5f850926fcecfb1552f33c8d039730200020000000000000000000000000000000000" +
        "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" +
        "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" +
        "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")

    var caps = ControllerSimulator.capturedCaps
    var raid = ControllerSimulator.capturedRaid
    var disks = ControllerSimulator.capturedDisks
    var staleReads = 0
    /// Commands executed, by opcode, for tests.
    private(set) var executed: [UInt8] = []
    var executedOpcodes: [UInt8] { executed }
    /// A made-up 128 KB flash image: a recognisable pattern, not real firmware.
    static let flash: [UInt8] = (0..<0x20000).map { UInt8(truncatingIfNeeded: ($0 &* 31) ^ ($0 >> 8)) }

    private var ack: [UInt8]
    private var pendingAck: [UInt8]?
    private var staleLeft = 0
    private var packet: [UInt32] = []

    init() {
        ack = [UInt8](repeating: 0, count: 512)
        ack.replaceSubrange(0..<16, with: Array("__ASMEDIA2109A__".utf8))
        ack.replaceSubrange(0x1F0..<0x200, with: Array("_PORTMULTIPLIER_".utf8))
    }

    func read(_ lba: UInt32) -> [UInt8] {
        if lba == ackLBA {
            if staleLeft > 0 { staleLeft -= 1; return ack }
            if let p = pendingAck { ack = p; pendingAck = nil }
            return ack
        }
        if lba != separatorLBA { feed(lba) }
        return [UInt8](repeating: 0, count: 512)
    }

    private func feed(_ lba: UInt32) {
        if lba == 0x43 { packet = [lba]; return }
        guard !packet.isEmpty else { return }
        packet.append(lba)
        let header: [UInt32] = [0x43, 0x71, 0xA7, 0xDF]
        if packet.count <= 4 {
            if packet != Array(header.prefix(packet.count)) { packet = [] }
            return
        }
        let body = packet.dropFirst(4).map { $0 }
        let long = (body.first.map { $0 & 0xFF } ?? 0) == 1
        let expected = 4 + 4 + (long ? 128 : 0) + 4
        // Each byte must carry the right tag for its position.
        let tags: [UInt32] = Array(repeating: 0x100, count: 4) + Array(repeating: 0x200, count: 4)
            + Array(repeating: 0x300, count: long ? 128 : 0) + Array(repeating: 0x400, count: 4)
        guard body.count <= expected, body.last! & 0xF00 == tags[body.count - 1] else { packet = []; return }
        if body.count == expected { complete(body.map { UInt8($0 & 0xFF) }, long: long); packet = [] }
    }

    private func complete(_ bytes: [UInt8], long: Bool) {
        let control = Array(bytes[0..<4]), command = Array(bytes[4..<8])
        let data = long ? Array(bytes[8..<136]) : []
        let crc = Array(bytes.suffix(4))
        let echo = [0x43, 0x00, 0x71, 0x00, 0xA7, 0x00, 0xDF, 0x00] + control + command
        var status: UInt8 = 0x20
        var reply: [UInt8] = []
        let c = crc32(echo + data)
        if crc != [UInt8(c >> 24), UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF)] {
            status = 0xE0
        } else {
            executed.append(command[0])
            switch command[0] {
            case 0x10: status = 0x00
            case 0x11: reply = caps
            case 0x15: reply = raid
            case 0x17: reply = disks
            case 0xB0: applyModeChange(data)
            case 0x20:
                let addr = (Int(command[2]) << 8 | Int(command[3])) << 7
                if addr + 128 <= ControllerSimulator.flash.count { reply = Array(ControllerSimulator.flash[addr..<(addr + 128)]) } else { status = 0xFF }
            default: status = 0xF0
            }
        }
        var next = ack
        next[0x30] = status
        next.replaceSubrange(0x40..<0x50, with: echo)
        if !reply.isEmpty { next.replaceSubrange(0x50..<(0x50 + reply.count), with: reply) }
        pendingAck = next
        staleLeft = staleReads
    }

    private func applyModeChange(_ p: [UInt8]) {
        let mode = p[8]
        caps[36] = mode
        raid[0] = mode
        raid[4] = 0      // volume online
        raid[5] = mode
        let name = Array(p[0x5C..<0x6B])
        caps.replaceSubrange(49..<64, with: name)
        // Recompute the volume size the way the firmware does.
        let sizes = DiskStatus(raw: disks).presentPorts.map(\.totalBlocks)
        let blocks = TargetMode(rawValue: mode).map { arrayBlocks($0, members: sizes) } ?? 0
        for i in 0..<8 { raid[12 + i] = UInt8((blocks >> (56 - 8 * UInt64(i))) & 0xFF) }
    }
}

func hexBytes(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var it = s.makeIterator()
    while let a = it.next(), let b = it.next() { out.append(UInt8(String([a, b]), radix: 16)!) }
    return out
}
