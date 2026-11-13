// graidctl command-line front end. Protocol code lives in Sources/Core.

import DiskArbitration
import Foundation

// MARK: - Commands

func requireRoot() throws {
    if simulate { return }
    // GRAIDCTL_TEST=1 lets tests/fake_device.sh drive the tool against an image file.
    if geteuid() != 0 && ProcessInfo.processInfo.environment["GRAIDCTL_TEST"] != "1" {
        throw ToolError("raw disk access needs root: run with sudo")
    }
}

/// `--simulate` runs against the built-in controller simulator instead of a disk.
var simulate = false
let sharedSimulator = ControllerSimulator()

func pickDevice(_ explicit: String?, anyProtocol: Bool, verbose: Bool) throws -> (Device, Candidate?) {
    if simulate {
        let dev = Device(simulator: sharedSimulator)
        dev.verbose = verbose
        return (dev, nil)
    }
    if let e = explicit {
        let path = e.hasPrefix("/") ? e : "/dev/r" + e.replacingOccurrences(of: "/dev/", with: "").replacingOccurrences(of: "rdisk", with: "disk")
        let dev = try Device(path: path)
        dev.verbose = verbose
        let (st, _) = try dev.execute(.identify)
        if st != 0x00 && st != 0x20 {
            throw ToolError("\(path) did not answer as a G-RAID controller (\(hex(st)) \(ackText(st)))")
        }
        return (dev, nil)
    }
    let found = discover(anyProtocol: anyProtocol, verbose: verbose)
    if found.isEmpty { throw ToolError("no G-RAID with Thunderbolt found (try --any-protocol, or name the disk: graidctl status disk4)") }
    // In Individual mode both bays appear as separate disks on the same controller.
    let ids = Set(found.map { $0.caps?.uniqueID ?? $0.candidate.bsdName })
    if ids.count > 1 { throw ToolError("more than one G-RAID found (\(found.map { $0.candidate.bsdName }.joined(separator: ", "))); name one explicitly") }
    let dev = try Device(path: found[0].candidate.rawPath)
    dev.verbose = verbose
    return (dev, found[0].candidate)
}

func cmdList(anyProtocol: Bool, verbose: Bool) throws {
    try requireRoot()
    let found = discover(anyProtocol: anyProtocol, verbose: verbose)
    if found.isEmpty { print("No G-RAID with Thunderbolt found."); return }
    for f in found {
        let c = f.candidate
        var line = "\(c.bsdName)  \(c.model.isEmpty ? c.mediaName : c.model)  \(formatBytes(Double(c.size)))"
        if let caps = f.caps { line += "  mode: \(modeText(caps.currentMode))  id: \(caps.uniqueID)" }
        print(line)
    }
}

func cmdStatus(device: String?, anyProtocol: Bool, verbose: Bool, json: Bool) throws {
    try requireRoot()
    let (dev, cand) = try pickDevice(device, anyProtocol: anyProtocol, verbose: verbose)
    let (caps, raid, disks) = try fetchAll(dev)
    let vol = raid.volume(0)

    if json {
        let obj: [String: Any] = [
            "device": dev.path,
            "capabilities": caps.raw.map { String(format: "%02x", $0) }.joined(),
            "raid_status": raid.raw.map { String(format: "%02x", $0) }.joined(),
            "disk_status": disks.raw.map { String(format: "%02x", $0) }.joined(),
        ]
        let d = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: d, as: UTF8.self))
        return
    }

    print("Device:        \(dev.path)\(cand.map { "  (\($0.model.isEmpty ? $0.mediaName : $0.model))" } ?? "")")
    print("FW Version:    \(caps.firmware)")
    print("Unique ID:     \(caps.uniqueID)")
    print("Controller:    chip \(hex(caps.chipID))  vendor \(String(format: "0x%04X", caps.vendorID))  device \(String(format: "0x%04X", caps.deviceID))  image \(caps.currentImage)\(caps.dualImage != 0 ? " (dual)" : "")")
    print("RAID Mode:     \(modeText(caps.currentMode))")
    if !caps.raidSetName.isEmpty { print("RAID Set Name: \(caps.raidSetName)") }

    var statusLine: String
    if caps.currentMode == 0xF || caps.currentMode == 0x10 {
        statusLine = vhddReasonText(raid.vhddReason)
    } else if caps.currentMode == 0 {
        statusLine = "n/a (individual disks)"
    } else {
        // No percentage: this firmware never fills TagLBA (FIRMWARE.md "Rebuild").
        statusLine = volumeStatusText(vol.status)
    }
    print("RAID Status:   \(statusLine)")
    if caps.currentMode != 0, vol.totalBlocks > 0 {
        print("RAID Capacity: \(formatBytes(Double(vol.bytesPerBlock) * Double(vol.totalBlocks)))")
    }
    print("Disks:         \(disks.disks) of \(disks.ports) ports")
    for p in disks.presentPorts {
        print("  Disk \(p.index + 1): \(diskStatusText(p.status))  \(p.model)  S/N \(p.serial)  \(formatBytes(p.capacityBytes))")
    }
}

func cmdSetMode(device: String?, mode: TargetMode, name: String, confirmed: Bool, anyProtocol: Bool, verbose: Bool) throws {
    try requireRoot()
    let (dev, cand) = try pickDevice(device, anyProtocol: anyProtocol, verbose: verbose)
    let (caps, _, disks) = try fetchAll(dev)
    if let problem = controllerProblem(caps: caps) { throw ToolError(problem) }
    if let problem = modeChangeProblem(mode: mode, name: name, disks: disks) { throw ToolError(problem) }

    print("Current mode: \(modeText(caps.currentMode))")
    print("New mode:     \(mode.label)  name \"\(name)\"")
    for p in disks.presentPorts { print("  Disk \(p.index + 1): \(p.model)  S/N \(p.serial)") }
    print("\nTHIS ERASES ALL DATA ON EVERY DISK IN THE ENCLOSURE.")
    if !confirmed {
        print("Re-run with --yes-erase-all-data to proceed.")
        return
    }
    print("Type ERASE to continue: ", terminator: "")
    guard readLine() == "ERASE" else { print("Cancelled."); return }

    // Individual mode exposes one disk per bay, all on the same controller.
    var bsd = [cand?.bsdName ?? dev.path.replacingOccurrences(of: "/dev/r", with: "")]
    bsd += discover(anyProtocol: anyProtocol, verbose: false).filter { $0.caps?.uniqueID == caps.uniqueID }.map { $0.candidate.bsdName }

    switch try performModeChange(dev: dev, bsdNames: bsd, payload: modeChangePayload(mode: mode, name: name, disks: disks)) {
    case .accepted:
        print("Mode change accepted. The enclosure will reconnect; then format it in Disk Utility.")
    case .noAck:
        print("No acknowledgement (the controller may already be resetting). Wait about 30 seconds and run `sudo graidctl status`.")
    }
}

/// Manual rebuild (the old app's Rebuild button): copies the source bay onto the other bay of a
/// degraded RAID 1. For when the automatic copy doesn't start, e.g. a returning drive the
/// controller has marked Blank.
func cmdRebuild(device: String?, sourceBay: Int?, confirmed: Bool, anyProtocol: Bool, verbose: Bool) throws {
    try requireRoot()
    guard let bay = sourceBay, bay == 1 || bay == 2 else { throw ToolError("rebuild needs --from 1 or --from 2: the bay holding the good copy") }
    let source = bay - 1
    let (dev, cand) = try pickDevice(device, anyProtocol: anyProtocol, verbose: verbose)
    let (caps, raid, disks) = try fetchAll(dev)
    if let problem = controllerProblem(caps: caps) { throw ToolError(problem) }
    if let problem = rebuildProblem(caps: caps, raid: raid, disks: disks, source: source) { throw ToolError(problem) }
    let present = disks.presentPorts
    let src = present.first { $0.index == source }!, dst = present.first { $0.index == 1 - source }!

    print("Array:   \(caps.raidSetName.isEmpty ? "(no name)" : caps.raidSetName), Protected (RAID 1), \(volumeStatusText(raid.volume(0).status))")
    print("Keep:    Bay \(bay)  \(src.model)  S/N \(src.serial)  \(diskStatusText(src.status))")
    print("Erase:   Bay \(2 - source)  \(dst.model)  S/N \(dst.serial)  \(diskStatusText(dst.status))")
    print("\nEverything on the drive in Bay \(2 - source) is overwritten with a copy of Bay \(bay).")
    print("The volume is unmounted first; the G-RAID may reconnect. The copy then runs by itself.")
    if !confirmed {
        print("Re-run with --yes-overwrite-other-bay to proceed.")
        return
    }
    print("Type REBUILD to continue: ", terminator: "")
    guard readLine() == "REBUILD" else { print("Cancelled."); return }

    let bsd = [cand?.bsdName ?? dev.path.replacingOccurrences(of: "/dev/r", with: "")]
    switch try performModeChange(dev: dev, bsdNames: bsd, payload: rebuildPayload(source: source, name: caps.raidSetName, disks: disks)) {
    case .accepted:
        print("Rebuild accepted. Check progress with `sudo graidctl status` or in G-RAID Utility.")
    case .noAck:
        print("No acknowledgement (the controller may be resetting). Wait about 30 seconds and run `sudo graidctl status`.")
    }
}

/// Read-only logger for the RAID 1 membership bytes in controller RAM, alongside the reported
/// volume and port statuses. One line per sample; a CHANGED line whenever anything moves.
func cmdWatchRAM(device: String?, interval: Double, count: Int?, dumpPorts: Bool, anyProtocol: Bool, verbose: Bool) throws {
    try requireRoot()
    if oldConfiguratorRunning() { throw ToolError(oldConfiguratorText) }
    let (dev, _) = try pickDevice(device, anyProtocol: anyProtocol, verbose: verbose)
    let addresses = raid1WatchFields.flatMap(\.addresses)
    let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss"
    print("watch-ram: read-only (GetRegister 0x50, RAM below 0xE000), every \(interval) s. Ctrl-C to stop.")
    print("Quit G-RAID Utility while this runs, so the two don't interleave commands.")
    if dumpPorts {
        // One-off: both port records (0xC2 bytes each from 0x0000), to find the membership field.
        let ram = try readRAM(dev: dev, addresses: Array(0x0000..<0x0184))
        for port in 0..<2 {
            let base = port * 0xC2
            print("port \(port) record (0x\(String(format: "%04X", base))):")
            for row in stride(from: 0, to: 0xC2, by: 16) {
                let bytes = (row..<min(row + 16, 0xC2)).map { String(format: "%02x", ram[UInt16(base + $0)]!) }
                print(String(format: "  +%02X  ", row) + bytes.joined(separator: " "))
            }
        }
        fflush(stdout)
    }
    var last: [String: String] = [:]
    var n = 0
    while count.map({ n < $0 }) ?? true {
        n += 1
        let now = clock.string(from: Date())
        do {
            let (_, raid, disks) = try fetchAll(dev)
            let ram = try readRAM(dev: dev, addresses: addresses)
            var fields: [(String, String)] = [("volume", volumeStatusText(raid.volume(0).status))]
            for p in disks.validPorts.prefix(2) {
                fields.append(("bay\(p.index + 1)", "\(diskStatusText(p.status))/order \(String(format: "%02x", p.order))"))
            }
            for f in raid1WatchFields { fields.append((f.name, ramFieldText(f, ram))) }
            print("\(now) " + fields.map { "\($0.0)=\($0.1)" }.joined(separator: "  "))
            let changed = fields.filter { last[$0.0] != nil && last[$0.0] != $0.1 }
            if !changed.isEmpty {
                print("\(now) CHANGED " + changed.map { "\($0.0): \(last[$0.0]!) -> \($0.1)" }.joined(separator: "; "))
            }
            for (k, v) in fields { last[k] = v }
        } catch {
            print("\(now) ERROR \(error)")
        }
        fflush(stdout)
        if count.map({ n < $0 }) ?? true { Thread.sleep(forTimeInterval: interval) }
    }
}

/// Read-only dump of the controller's flash. Reads twice and writes the file only if both
/// passes match, so a glitchy read can't produce a corrupt backup.
func cmdFirmwareDump(file: String?, device: String?, size: UInt32, anyProtocol: Bool, verbose: Bool) throws {
    try requireRoot()
    guard size > 0, size % 128 == 0, size <= 0x80_0000 else { throw ToolError("--size must be a multiple of 0x80, at most 0x800000") }
    let (dev, _) = try pickDevice(device, anyProtocol: anyProtocol, verbose: verbose)
    let (caps, _, _) = try fetchAll(dev)
    let path = file ?? "G-RAID-firmware-\(caps.firmware)-\(caps.uniqueID).bin"
    guard !FileManager.default.fileExists(atPath: path) else { throw ToolError("\(path) already exists; pick another name") }
    print("Controller: chip \(hex(caps.raw[0])), firmware \(caps.firmware), current image \(caps.raw[28]), dual image \(caps.raw[29])")
    print("Reading \(size) bytes (0x\(String(size, radix: 16))) of flash, twice. Only the read command is sent.")
    var passes: [[UInt8]] = []
    for pass in 1...2 {
        let start = Date()
        let data = try readFlash(dev: dev, size: size) { done in
            print(String(format: "\r  pass %d: %3d %%", pass, Int(done) * 100 / Int(size)), terminator: "")
            fflush(stdout)
        }
        print(String(format: "\r  pass %d: done in %.0f s", pass, Date().timeIntervalSince(start)))
        passes.append(data)
    }
    guard passes[0] == passes[1] else {
        let first = passes[0].indices.first { passes[0][$0] != passes[1][$0] } ?? 0
        throw ToolError("The two passes differ (first at 0x\(String(first, radix: 16))). Nothing was saved; try again.")
    }
    try Data(passes[0]).write(to: URL(fileURLWithPath: path))
    // Hand the file to the user who ran sudo.
    if let u = ProcessInfo.processInfo.environment["SUDO_UID"].flatMap({ uid_t($0) }),
       let g = ProcessInfo.processInfo.environment["SUDO_GID"].flatMap({ gid_t($0) }) { chown(path, u, g) }
    let sha = sha256Hex(passes[0])
    print("Saved \(path)\nSHA-256 \(sha)")
    // Hint at the real size: SPI flash wraps around past its end.
    let half = passes[0].count / 2
    if half >= 0x1000, Array(passes[0][0..<half]) == Array(passes[0][half...]) {
        print("Note: the second half repeats the first, so the flash is probably \(half) bytes and the read wrapped.")
    }
    if passes[0].allSatisfy({ $0 == 0xFF }) { print("Note: everything read as 0xFF (erased or not readable this way).") }
}

/// Used by the GUI app (through an administrator prompt): make G-RAID raw disks readable by one user.
func cmdGrantAccess(uidString: String?, anyProtocol: Bool) throws {
    try requireRoot()
    guard let s = uidString, let uid = uid_t(s), uid != 0 else { throw ToolError("grant-access needs --uid <user id>") }
    let found = grantAccess(uid: uid, anyProtocol: anyProtocol)
    print(found.map { $0.candidate.bsdName }.joined(separator: " "))
}

// MARK: - Unlock service (installed by the app as a launchd daemon, opt-in)

let unlockStatusURL = URL(fileURLWithPath: "/Library/Application Support/G-RAID Utility/unlockd-status.json")

/// Runs as root under launchd. Whenever disks appear (and every 30 s as a fallback), make
/// G-RAID raw disks readable by `uid`, exactly like `grant-access`. Writes a small status
/// file the app reads to show whether the service works (it needs Full Disk Access).
func cmdUnlockDaemon(uidString: String?) throws {
    try requireRoot()
    guard let s = uidString, let uid = uid_t(s), uid != 0 else { throw ToolError("unlock-daemon needs --uid <user id>") }

    func writeStatus(_ obj: [String: Any]) {
        let dir = unlockStatusURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: unlockStatusURL)
            chmod(unlockStatusURL.path, 0o644)
        }
    }

    var lastNeedsFDA = false
    /// How many passes in a row each disk failed to answer as a G-RAID. After `probeLimit` the
    /// disk is left alone until it reconnects: another external SATA disk would otherwise be
    /// probed every 30 s for ever, and every probe also sends commands to the G-RAID beside it
    /// (keeping its drives awake, and cutting across the app's own commands).
    var misses: [String: Int] = [:]
    let probeLimit = 4

    func pass(_ reason: String) {
        // Any candidate we can't open with EPERM means this daemon lacks Full Disk Access.
        let candidates = candidateDisks()
        var blocked: [String] = []
        for c in candidates {
            let fd = open(c.rawPath, O_RDONLY)
            if fd >= 0 { close(fd) } else if errno == EPERM { blocked.append(c.bsdName) }
        }
        lastNeedsFDA = !blocked.isEmpty
        let unlocked = blocked.isEmpty ? grantAccess(uid: uid, anyProtocol: false).map { $0.candidate.bsdName } : []
        if blocked.isEmpty {
            for c in candidates {
                if unlocked.contains(c.bsdName) { misses[c.bsdName] = nil } else { misses[c.bsdName, default: 0] += 1 }
            }
        }
        writeStatus([
            "time": ISO8601DateFormatter().string(from: Date()),
            "reason": reason,
            "uid": Int(uid),
            "pid": Int(getpid()),
            "candidates": candidates.map(\.bsdName),
            "unlocked": unlocked,
            "needs_full_disk_access": !blocked.isEmpty,
        ])
    }

    /// Only does work when some candidate disk is still root-owned (new connection), or while
    /// the service is waiting for Full Disk Access so it notices as soon as it's granted.
    func passIfNeeded(_ reason: String) {
        if lastNeedsFDA { pass(reason); return }
        let candidates = candidateDisks()
        misses = misses.filter { m in candidates.contains { $0.bsdName == m.key } }   // forget unplugged disks
        let pending = candidates.contains { c in
            var st = stat()
            return stat(c.rawPath, &st) == 0 && st.st_uid != uid && misses[c.bsdName, default: 0] < probeLimit
        }
        if pending { pass(reason) }
    }

    pass("start")
    guard let session = DASessionCreate(kCFAllocatorDefault) else { throw ToolError("couldn't start a DiskArbitration session") }
    var debounce: DispatchWorkItem?
    let onAppear: (String?) -> Void = { bsd in
        if let bsd { misses[bsd] = nil }   // a disk that just appeared gets a fresh set of tries
        debounce?.cancel()
        let item = DispatchWorkItem { passIfNeeded("disk appeared") }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }
    let box = Unmanaged.passRetained(onAppear as AnyObject)
    DARegisterDiskAppearedCallback(session, nil, { disk, ctx in
        let bsd = DADiskGetBSDName(disk).map { String(cString: $0) }
        (Unmanaged<AnyObject>.fromOpaque(ctx!).takeUnretainedValue() as! (String?) -> Void)(bsd)
    }, box.toOpaque())
    DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in passIfNeeded("periodic") }
    RunLoop.main.run()
}

func cmdTrace() {
    let cmds: [(String, Command)] = [("Identify", .identify), ("GetCapabilities", .capabilities),
                                     ("GetRAIDStatus", .raidStatus), ("GetDiskStatus", .diskStatus)]
    for (n, c) in cmds {
        print("\(n): " + c.wireSequence.map { String(format: "%X", $0) }.joined(separator: " ") + "  -> ack \(String(format: "%X", ackLBA))")
    }
}

// MARK: - CLI

let usage = """
graidctl: native tool for G-RAID with Thunderbolt (replaces Configurator 1.1)

USAGE
  sudo graidctl list                         Find G-RAID controllers
  sudo graidctl status [diskN]               Firmware, RAID mode/state, disks
  sudo graidctl set-mode <individual|raid0|raid1> [diskN] [--name NAME] --yes-erase-all-data
  sudo graidctl rebuild --from <1|2> [diskN] --yes-overwrite-other-bay
                                             Degraded RAID 1: copy the good bay onto the other one
  sudo graidctl watch-ram [diskN] [--interval 5] [--count N] [--ports]
                                             Log RAID 1 membership bytes in controller RAM (read-only)
  sudo graidctl spin-check diskN             Are the drives spinning? (times random reads)
  sudo graidctl firmware-dump [file] [diskN] [--size 0x1F000]
                                             Back up the controller firmware (read-only, read twice)
  graidctl io-counters diskN                 Read/write operation counts (doesn't touch the disk)
  graidctl partitions diskN                  List partitions: volumes, system, unreadable (no disk I/O)
  graidctl trace                             Print the sector sequences sent (no I/O)
  graidctl status --simulate                 Run against the built-in controller simulator
  graidctl selftest                          Check encoding/parsing (no hardware)

OPTIONS
  -v, --verbose      Show every sector read and ack status
  --json             status: raw reply bytes as JSON (for bug reports)
  --any-protocol     Also probe external non-SATA disks
"""

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ names: String...) -> Bool {
    if let i = args.firstIndex(where: { names.contains($0) }) { args.remove(at: i); return true }
    return false
}
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}

let verbose = flag("-v", "--verbose")
let json = flag("--json")
let anyProto = flag("--any-protocol")
simulate = flag("--simulate")
let confirmed = flag("--yes-erase-all-data")
let overwriteConfirmed = flag("--yes-overwrite-other-bay")
let fromBay = option("--from").flatMap { Int($0) }
let watchInterval = option("--interval").flatMap { Double($0) } ?? 5
let watchCount = option("--count").flatMap { Int($0) }
let watchPorts = flag("--ports")
let setName = option("--name") ?? "G-RAID"

do {
    guard let sub = args.first else { print(usage); exit(0) }
    let rest = Array(args.dropFirst())
    switch sub {
    case "list": try cmdList(anyProtocol: anyProto, verbose: verbose)
    case "status": try cmdStatus(device: rest.first, anyProtocol: anyProto, verbose: verbose, json: json)
    case "set-mode":
        let modes: [String: TargetMode] = ["individual": .individual, "raid0": .raid0, "raid1": .raid1]
        guard let m = rest.first.flatMap({ modes[$0.lowercased()] }) else { throw ToolError("set-mode needs one of: individual, raid0, raid1") }
        try cmdSetMode(device: rest.dropFirst().first, mode: m, name: setName, confirmed: confirmed, anyProtocol: anyProto, verbose: verbose)
    case "watch-ram":
        try cmdWatchRAM(device: rest.first, interval: max(1, watchInterval), count: watchCount, dumpPorts: watchPorts, anyProtocol: anyProto, verbose: verbose)
    case "rebuild":
        try cmdRebuild(device: rest.first, sourceBay: fromBay, confirmed: overwriteConfirmed, anyProtocol: anyProto, verbose: verbose)
    case "grant-access": try cmdGrantAccess(uidString: option("--uid"), anyProtocol: anyProto)
    case "unlock-daemon": try cmdUnlockDaemon(uidString: option("--uid"))
    case "partitions":
        guard let d = rest.first else { throw ToolError("partitions needs a whole disk, e.g. graidctl partitions disk4") }
        let parts = partitions(onWholeDisk: d.replacingOccurrences(of: "/dev/", with: ""))
        if parts.isEmpty { print("No partitions found on \(d).") }
        for p in parts {
            let where_ = p.mountURL.map { "mounted at \($0.path)" } ?? (p.mountable ? "not mounted" : "can't be mounted")
            print("\(p.bsd.padding(toLength: 10, withPad: " ", startingAt: 0)) \(p.kind.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(formatBytes(p.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(p.format) · \(p.name) · \(where_)\(p.isAPFS ? " · in APFS container \(p.parentDisk)" : "")")
        }
    case "io-counters":
        guard let d = rest.first, let c = ioCounters(bsd: d.replacingOccurrences(of: "/dev/", with: "")) else {
            throw ToolError("io-counters needs a whole disk that exists, e.g. graidctl io-counters disk4")
        }
        print("reads \(c.reads)  writes \(c.writes)")
    case "spin-check":
        // Measure before anything else touches the disk (even Identify could wake the drives).
        try requireRoot()
        guard let d = rest.first else { throw ToolError("spin-check needs a disk, e.g. graidctl spin-check disk4") }
        let name = d.replacingOccurrences(of: "/dev/", with: "").replacingOccurrences(of: "rdisk", with: "disk")
        print(describeSpinState(try measureReadLatency(path: "/dev/r" + name)))
    case "firmware-dump":
        let sizeArg = option("--size")
        let size = sizeArg.map { UInt32($0.hasPrefix("0x") ? String($0.dropFirst(2)) : $0, radix: $0.hasPrefix("0x") ? 16 : 10) } ?? firmwareDumpDefaultSize
        guard let sz = size else { throw ToolError("--size must be a number, e.g. 0x1F000") }
        let rest2 = Array(args.dropFirst())
        let file = rest2.first(where: { !$0.hasPrefix("disk") && !$0.hasPrefix("/dev/") })
        let disk = rest2.first(where: { $0.hasPrefix("disk") || $0.hasPrefix("/dev/") })
        try cmdFirmwareDump(file: file, device: disk, size: sz, anyProtocol: anyProto, verbose: verbose)
    case "trace": cmdTrace()
    case "selftest": exit(selfTest() ? 0 : 1)
    case "-h", "--help", "help": print(usage)
    default: throw ToolError("unknown command '\(sub)'\n\n\(usage)")
    }
} catch {
    FileHandle.standardError.write(Data("graidctl: \(error)\n".utf8))
    exit(1)
}
