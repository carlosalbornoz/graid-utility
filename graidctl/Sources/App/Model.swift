import AppKit
import DiskArbitration
import Foundation

/// One enclosure. In Individual mode its two bays show up as two disks with the same unique ID.
struct Unit: Identifiable {
    var id: String { caps.uniqueID }
    let path: String
    let bsdNames: [String]
    let productName: String
    let caps: Capabilities
    let raid: RaidStatus
    let disks: DiskStatus
    /// Every partition on the unit's disks: volumes, system partitions, unreadable ones.
    var partitions: [Partition] = []
    /// How far a running RAID 1 rebuild has got, read from controller RAM (nil when none runs
    /// or the firmware's layout isn't known).
    var rebuild: RebuildPosition? = nil

    /// Mounted volumes (never system partitions such as EFI, even when mounted).
    var volumes: [MountedVolume] {
        partitions.compactMap { p in
            guard p.kind == .volume, let url = p.mountURL else { return nil }
            return MountedVolume(bsd: p.bsd, name: p.name, url: url, used: p.used, total: p.total, readOnly: p.readOnly)
        }
    }
    /// Volumes that could be mounted but aren't.
    var unmountedVolumes: [Partition] { partitions.filter { $0.kind == .volume && !$0.isMounted } }
    /// Mounted volumes a speed test can write to.
    var writableVolumes: [MountedVolume] { volumes.filter { !$0.readOnly } }
    var hasMountedPartitions: Bool { partitions.contains(where: \.isMounted) }

    var model: DeviceModel { DeviceModel.identify(caps) }
    func snapshot(named name: String) -> UnitSnapshot { UnitSnapshot(id: id, name: name, caps: caps, raid: raid, disks: disks) }

    /// The array name, or the product name in Individual mode (see `unitNames`).
    var baseName: String {
        let n = caps.currentMode == 0 ? "" : caps.raidSetName
        return n.trimmingCharacters(in: .whitespaces).isEmpty ? model.name : n
    }

    enum Health { case good, attention, bad
        var rank: Int { self == .good ? 0 : self == .attention ? 1 : 2 } }

    var health: Health {
        let ports = disks.presentPorts.map(\.status)
        if caps.currentMode == 0xF || caps.currentMode == 0x10 { return .bad }
        if ports.contains(where: { [3, 5, 6, 8].contains($0) }) { return .bad } // missing, ID mismatch, rejected, failed
        if ports.contains(7) { return .attention }                                // predictive failure
        if caps.currentMode == 0 { return ports.isEmpty ? .attention : .good }
        switch volumeStatus {
        case 0: return .good
        case 3, 4, 7, 0x11: return .bad
        default: return .attention
        }
    }

    var statusText: String {
        if caps.currentMode == 0xF || caps.currentMode == 0x10 { return vhddReasonText(raid.vhddReason) }
        if caps.currentMode == 0 { return disks.presentPorts.allSatisfy { $0.status == 0 } ? "Online" : "Check disks" }
        return volumeStatusText(volumeStatus)
    }

    /// The volume status, corrected for a RAID 1 member the controller reports Missing.
    var volumeStatus: UInt8 {
        effectiveVolumeStatus(mode: caps.currentMode, volumeStatus: raid.volume(0).status,
                              portStatuses: disks.presentPorts.map(\.status))
    }

    var capacityText: String {
        let v = raid.volume(0)
        if caps.currentMode != 0, v.totalBlocks > 0 { return formatBytes(Double(v.bytesPerBlock) * Double(v.totalBlocks)) }
        let total = disks.presentPorts.reduce(0) { $0 + $1.capacityBytes }
        return total > 0 ? formatBytes(total) : "—"
    }

    /// What each mode would give with the installed disks.
    func resultText(for mode: TargetMode) -> String {
        let ports = disks.presentPorts
        let sizes = ports.map(\.capacityBytes)
        guard !sizes.isEmpty else { return "—" }
        // The controller's own formula; with mismatched disks, say how much of the larger one goes unused.
        let (usable, unused) = modeCapacity(mode, members: ports.map(\.totalBlocks), bytesPerBlock: UInt64(ports[0].bytesPerBlock))
        let note = disksMismatched(sizes) && unused > 0 ? " (about \(formatBytes(unused)) of the larger disk unused)" : ""
        switch mode {
        case .raid0: return "\(formatBytes(usable)) in one volume" + note
        case .raid1: return "\(formatBytes(usable)) in one volume, mirrored" + note
        case .individual: return sizes.map { formatBytes($0) }.joined(separator: " + ") + " as separate volumes"
        }
    }

    var currentTarget: TargetMode? { TargetMode(rawValue: caps.currentMode) }

    /// Each of the two bays' disk status, nil when the bay is empty.
    var bayStatuses: [UInt8?] {
        let present = disks.presentPorts
        return (0..<2).map { i in present.first { $0.index == i }?.status }
    }

    /// Where replacing a RAID 1 drive stands, or nil when nothing needs replacing.
    var replaceStep: ReplaceStep? {
        computeReplaceStep(mode: caps.currentMode, volumeStatus: volumeStatus, bays: bayStatuses)
    }

    /// The mirrored volume's size, and the smallest drive that can replace a member.
    var volumeBytes: Double { Double(raid.volume(0).bytesPerBlock) * Double(raid.volume(0).totalBlocks) }
    var replacementMinBytes: Double {
        Double(raid.volume(0).bytesPerBlock) * Double(replacementMinBlocks(volumeBlocks: raid.volume(0).totalBlocks))
    }

    var usedBytes: Double { volumes.reduce(0) { $0 + $1.used } }

    // The controller never reports rebuild progress (FIRMWARE.md "Rebuild"), only the status.
    var isBusy: Bool { [2, 5, 6, 8, 9].contains(raid.volume(0).status) }
    /// The controller is working right now: rebuilding, migrating or verifying, not paused.
    var isActive: Bool { [2, 5, 6].contains(raid.volume(0).status) }
}

/// A drive seen in a bay, kept so a missing drive can still be named.
struct KnownDrive: Codable, Equatable {
    let model: String
    let serial: String
    let bytes: Double
}

struct MountedVolume {
    let bsd: String          // partition, e.g. disk4s2 (or disk5s1 inside an APFS container)
    let name: String
    let url: URL
    let used: Double
    let total: Double
    let readOnly: Bool
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable { case scanning, noDevice, needsAccess, ready, startingUp, ejected }

    static let shared = AppModel()

    @Published var phase: Phase = .scanning
    @Published var units: [Unit] = []
    @Published var selectedID: String?
    @Published var lockedDisks: [String] = []   // external SATA disks we can't read yet
    @Published var message: Notice?
    @Published var isWorking = false
    @Published var lastUpdated: Date?
    /// Feedback for a refresh the user asked for (the toolbar button or ⌘R).
    enum UserRefresh { case idle, running, done }
    @Published private(set) var userRefresh: UserRefresh = .idle
    private var userRefreshStarted = Date.distantPast
    @Published var suggestDiskUtility = false
    /// G-RAIDs connected over USB: the controller can only be managed over Thunderbolt.
    @Published var usbGRAIDs: [Candidate] = []
    @Published var recentEvents: [GRAIDEvent] = []
    /// G-RAID enclosures on the Thunderbolt bus (present before their disk appears).
    @Published var thunderboltGRAIDs: [String] = []
    @Published var startingSince: Date?
    var startingUpTooLong: Bool { startingSince.map { Date().timeIntervalSince($0) > 90 } ?? false }
    /// Whole disks the user ejected: not read until unplugged or mounted again.
    @Published var ejectedDisks: Set<String> = []
    /// Volumes (partitions) that were mounted before the eject, so Mount Again restores exactly those.
    private var ejectedVolumes: [String] = []
    /// True while Mount Again is running (shown on its button).
    @Published var mounting = false
    /// The section shown on the right of the main window.
    @Published var tab: MainTab = .array
    /// Whether the Volumes tab lists system partitions (EFI and so on).
    @Published var showSystemPartitions = false
    /// The speed test currently shown, if any.
    @Published var speedTest: SpeedTest?

    func startSpeedTest(_ unit: Unit, volume: MountedVolume? = nil) {
        guard let v = volume ?? unit.writableVolumes.first else { return }
        let test = SpeedTest(volume: v)
        let key = "lastSpeedTest." + unit.id
        test.onFinish = { w, r, size in
            let result = SpeedResult(date: Date(), writeMBps: w, readMBps: r, sizeGB: size, volume: v.name)
            if let data = try? JSONEncoder().encode(result) { UserDefaults.standard.set(data, forKey: key) }
        }
        speedTest = test
    }

    /// The most recent completed speed test on this unit, if any.
    func lastSpeedTest(_ unit: Unit) -> SpeedResult? {
        UserDefaults.standard.data(forKey: "lastSpeedTest." + unit.id).flatMap { try? JSONDecoder().decode(SpeedResult.self, from: $0) }
    }
    /// When a G-RAID was first seen locked (for the unlock service's grace period).
    @Published var lockedSince: Date?
    /// True while the unlock service is expected to unlock a just-connected G-RAID.
    var waitingForUnlockService: Bool {
        guard phase == .needsAccess, UnlockService.isInstalled, let since = lockedSince else { return false }
        return Date().timeIntervalSince(since) < 15
    }
    /// Worst health across connected units, for the menu bar icon (nil when none).
    @Published var menuHealth: Unit.Health?
    /// Faster polling while the window is open; slower in the background.
    var windowVisible = true {
        didSet {
            rescheduleTimer()
            // Window reopened after a quiet spell in the background: show fresh status.
            if windowVisible && !oldValue, phase == .ready, Date().timeIntervalSince(lastUpdated ?? .distantPast) > 15 {
                refresh(quiet: true)
            }
        }
    }
    /// Disk I/O counters right after our last status check (our own reads included), so a
    /// background check can tell whether anything else has used the disk since.
    private var countersAfterCheck: [String: IOCounters]?
    /// Set while background checks are being skipped because the G-RAID is idle.
    @Published var idleSince: Date?

    let eventLog = EventLog()
    private var lastSnapshots: [String: UnitSnapshot]?
    private var missCount: [String: Int] = [:]

    private var watcher: DiskWatcher?
    private var pendingRefresh: DispatchWorkItem?
    private var timer: Timer?

    var selected: Unit? { units.first { $0.id == selectedID } ?? units.first }

    /// Each unit's name, told apart when two share one (`unitNames`).
    static func names(_ units: [Unit]) -> [String: String] {
        unitNames(units.map { (id: $0.id, arrayName: $0.caps.currentMode == 0 ? "" : $0.caps.raidSetName, product: $0.model.name) })
    }
    func name(of unit: Unit) -> String { Self.names(units)[unit.id] ?? unit.baseName }

    /// For the device picker: "G-RAID · RAID 0 · 8.00 TB".
    func pickerLabel(_ unit: Unit) -> String {
        [name(of: unit), unit.currentTarget?.chip ?? modeText(unit.caps.currentMode), unit.capacityText].joined(separator: " · ")
    }

    func start() {
        guard watcher == nil else { return }
        recentEvents = eventLog.load()
        watcher = DiskWatcher(onChange: { [weak self] in Task { @MainActor in self?.scheduleRefresh() } },
                              onEject: { [weak self] bsd in Task { @MainActor in self?.noteExternalEject(bsd) } })
        refresh()
        rescheduleTimer()
    }

    private func rescheduleTimer() {
        timer?.invalidate()
        let interval: TimeInterval = windowVisible ? 15 : 60
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isWorking else { return }
                // In the background keep polling even with nothing connected, to catch reconnects.
                guard self.phase == .ready || !self.windowVisible else { return }
                if self.shouldSkipIdleCheck() { return }
                self.refresh(quiet: true)
            }
        }
    }

    /// A status check wakes the drives. In the background, skip it while nothing has touched the
    /// disk since the last check, so macOS can spin the drives down; check again as soon as
    /// anything reads or writes (the drives are awake then anyway). Connects and disconnects
    /// still come in through the disk watcher.
    private func shouldSkipIdleCheck() -> Bool {
        guard !windowVisible, phase == .ready, Pref.drivesMaySleep, let last = countersAfterCheck else { return false }
        guard let now = ioCounters(bsdNames: units.flatMap(\.bsdNames)), now == last else { return false }
        if idleSince == nil { idleSince = lastUpdated ?? Date() }
        return true
    }

    /// Turn the difference between two scans into events, log them and notify.
    private func record(scan: (units: [Unit], locked: [String], usb: [Candidate], present: Set<String>, thunderbolt: [String])) {
        let names = Self.names(scan.units)
        let now = Dictionary(uniqueKeysWithValues: scan.units.map { ($0.id, $0.snapshot(named: names[$0.id] ?? $0.baseName)) })
        guard let old = lastSnapshots else { lastSnapshots = now; return }   // first scan is the baseline
        var gone = Set<String>()
        var carried = now
        for (id, snap) in old where now[id] == nil {
            // Ejected on purpose and still attached: keep its last state, no "Disconnected".
            if let unit = units.first(where: { $0.id == id }),
               unit.bsdNames.allSatisfy({ ejectedDisks.contains($0) && scan.present.contains($0) }) {
                carried[id] = snap
                continue
            }
            // Confirm a disappearance: its disk is gone, or it failed to answer twice in a row.
            let unit = units.first { $0.id == id }
            let diskGone = unit.map { !$0.bsdNames.contains(where: scan.present.contains) } ?? true
            missCount[id, default: 0] += 1
            if diskGone || missCount[id]! >= 2 { gone.insert(id) } else { carried[id] = snap }
        }
        for id in now.keys { missCount[id] = nil }
        for id in gone { missCount[id] = nil }
        let events = diffSnapshots(old: old, new: now, confirmedGone: gone)
        lastSnapshots = carried
        log(events)
    }

    func log(_ events: [GRAIDEvent]) {
        guard !events.isEmpty else { return }
        eventLog.append(events)
        recentEvents.append(contentsOf: events)
        if recentEvents.count > 2000 { recentEvents.removeFirst(recentEvents.count - 2000) }
        Notifier.post(events)
    }

    func clearHistory() {
        eventLog.clear()
        recentEvents = []
    }

    /// Disks appear and disappear in bursts (whole disk, then partitions); wait for it to settle.
    func scheduleRefresh(after delay: TimeInterval = 2) {
        pendingRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh(quiet: true) }
        pendingRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private var scanning = false
    private var rescanPending = false

    // MARK: Drives last seen in each bay

    private var knownDrives: [String: [String: KnownDrive]] = [:]

    private static func knownDrivesKey(_ unit: String) -> String { "knownDrives." + unit }

    /// When this app first saw each unit's current rebuild, kept across launches.
    func rebuildSeenSince(unit: String) -> Date? {
        UserDefaults.standard.object(forKey: "rebuildSeen." + unit) as? Date
    }

    /// Which drive a degraded RAID 1 runs on, remembered across launches, so a switch to the
    /// other drive's (possibly older) copy is caught even if it happened while the app was closed.
    private func trackActiveMember(_ units: [Unit]) {
        for u in units {
            let key = "activeMember." + u.id, swapKey = "memberSwap." + u.id
            if u.caps.currentMode == 2, u.raid.volume(0).status == 0,
               u.disks.presentPorts.filter({ $0.status == 0 }).count >= 2 {
                UserDefaults.standard.removeObject(forKey: swapKey)   // back in sync: nothing to warn about
            }
            guard let now = soleActiveMember(mode: u.caps.currentMode, volumeStatus: u.raid.volume(0).status, disks: u.disks) else { continue }
            let previous = UserDefaults.standard.string(forKey: key)
            if isMemberSwap(previousSerial: previous, now: now, disks: u.disks) {
                let old = u.disks.presentPorts.first { $0.serial == previous }
                let oldBay = old.map { "Bay \($0.index + 1)" } ?? "the other bay"
                log([GRAIDEvent(unitID: u.id, unitName: name(of: u), category: .array, severity: .critical,
                                title: "The G-RAID switched to the other drive's copy",
                                detail: "It's now using Bay \(now.bay + 1) (serial \(now.serial)) instead of \(oldBay). Changes made while Bay \(now.bay + 1) was out may be missing.")])
                UserDefaults.standard.set(Date(), forKey: swapKey)
            }
            UserDefaults.standard.set(now.serial, forKey: key)
        }
    }

    /// When the controller last switched a degraded RAID 1 to the other drive, if it hasn't
    /// been back in sync since.
    func memberSwapSince(unit: String) -> Date? {
        UserDefaults.standard.object(forKey: "memberSwap." + unit) as? Date
    }

    /// Manual rebuild: copy `source` onto the other bay (FIRMWARE.md "Rebuild"). Unmounts first;
    /// the G-RAID resets and reconnects, then copies by itself.
    func rebuild(unit: Unit, source: Int) {
        isWorking = true
        message = nil
        let unitName = self.name(of: unit)
        Task.detached {
            var notice: Notice
            do {
                let dev = try Device(path: unit.path)
                let (caps, raid, disks) = try fetchAll(dev)
                if let problem = rebuildProblem(caps: caps, raid: raid, disks: disks, source: source) { throw ToolError(problem) }
                _ = try performModeChange(dev: dev, bsdNames: unit.bsdNames,
                                          payload: rebuildPayload(source: source, name: caps.raidSetName, disks: disks))
                notice = Notice(.done, "Rebuild started", "The G-RAID copies Bay \(source + 1) onto Bay \(2 - source). It reconnects in a few seconds, then copies by itself.")
                let event = GRAIDEvent(unitID: unit.id, unitName: unitName, category: .array, severity: .warning,
                                       title: "Rebuild requested", detail: "Bay \(source + 1) onto Bay \(2 - source)")
                await MainActor.run { self.log([event]) }
            } catch {
                // The controller resets as soon as it accepts the command, so the follow-up read
                // can fail even though the rebuild started.
                let text = "\(error)"
                notice = text.contains("Device not configured")
                    ? Notice(.done, "Rebuild started", "The G-RAID is resetting. It reconnects in a few seconds, then copies by itself.")
                    : Notice(.problem, "The rebuild wasn't started", text)
            }
            let reported = notice
            await MainActor.run {
                self.message = reported
                self.isWorking = false
                self.scheduleRefresh()
            }
        }
    }

    /// The first rebuild position seen this session, per unit, for the time-left estimate.
    private var rebuildFirst: [String: (date: Date, position: UInt64)] = [:]
    @Published private(set) var rebuildLeft: [String: TimeInterval] = [:]
    /// Smoothed copy speed per unit, in bytes per second, from consecutive readings.
    @Published private(set) var rebuildRate: [String: Double] = [:]
    private var rebuildLast: [String: (date: Date, position: UInt64)] = [:]
    /// For tests/render_previews.sh: show a rebuild's time left and speed without hardware.
    func previewRebuild(unit: String, left: TimeInterval, rate: Double) { rebuildLeft[unit] = left; rebuildRate[unit] = rate }

    private func trackRebuilds(_ units: [Unit]) {
        for u in units {
            if let r = u.rebuild {
                let now = (date: Date(), position: r.position)
                if let last = rebuildLast[u.id], last.position <= r.position {
                    rebuildRate[u.id] = rebuildSpeed(last: last, now: now, previous: rebuildRate[u.id])
                    if now.date.timeIntervalSince(last.date) >= 5 { rebuildLast[u.id] = now }
                } else {
                    rebuildLast[u.id] = now
                    rebuildRate[u.id] = nil
                }
                if let first = rebuildFirst[u.id], first.position <= r.position {
                    rebuildLeft[u.id] = rebuildTimeLeft(first: first, now: (Date(), r.position), end: r.end)
                } else {
                    rebuildFirst[u.id] = (Date(), r.position)
                    rebuildLeft[u.id] = nil
                }
            } else {
                rebuildFirst[u.id] = nil
                rebuildLeft[u.id] = nil
                rebuildLast[u.id] = nil
                rebuildRate[u.id] = nil
            }
            let key = "rebuildSeen." + u.id
            switch u.replaceStep {
            case .copying?, .paused?:
                if UserDefaults.standard.object(forKey: key) == nil { UserDefaults.standard.set(Date(), forKey: key) }
            default:
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// The drive last seen answering in a bay of this unit.
    func lastSeenDrive(unit: String, bay: Int) -> KnownDrive? {
        if knownDrives[unit] == nil {
            knownDrives[unit] = UserDefaults.standard.data(forKey: Self.knownDrivesKey(unit))
                .flatMap { try? JSONDecoder().decode([String: KnownDrive].self, from: $0) } ?? [:]
        }
        return knownDrives[unit]?[String(bay)]
    }

    func rememberDrives(_ units: [Unit]) {
        for u in units {
            var drives = knownDrives[u.id] ?? [:]
            if knownDrives[u.id] == nil { _ = lastSeenDrive(unit: u.id, bay: 0); drives = knownDrives[u.id] ?? [:] }
            let before = drives
            for p in u.disks.presentPorts where p.status != 3 && !p.model.isEmpty && !p.serial.isEmpty {
                drives[String(p.index)] = KnownDrive(model: p.model, serial: p.serial, bytes: p.capacityBytes)
            }
            guard drives != before else { continue }
            knownDrives[u.id] = drives
            if let data = try? JSONEncoder().encode(drives) { UserDefaults.standard.set(data, forKey: Self.knownDrivesKey(u.id)) }
        }
    }

    /// A refresh the user asked for: the button spins while it runs (at least half a second, so
    /// it registers), then shows a checkmark briefly.
    func refreshNow() {
        guard !isWorking, userRefresh != .running else { return }
        userRefresh = .running
        userRefreshStarted = Date()
        refresh()
    }

    private func finishUserRefresh() {
        guard userRefresh == .running else { return }
        let wait = max(0, 0.6 - Date().timeIntervalSince(userRefreshStarted))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            self.userRefresh = .done
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if self.userRefresh == .done { self.userRefresh = .idle }
            }
        }
    }

    func refresh(quiet: Bool = false) {
        if isWorking { return }
        // Coalesce: launch, the disk watcher and the timer can all ask at once.
        if scanning { rescanPending = true; return }
        scanning = true
        if !quiet && units.isEmpty { phase = .scanning }
        let skip = ejectedDisks
        Task.detached(priority: .userInitiated) {
            let result = Self.scan(skipping: skip)
            let counters = ioCounters(bsdNames: result.units.flatMap(\.bsdNames))
            await MainActor.run {
                self.scanning = false
                self.countersAfterCheck = result.units.isEmpty ? nil : counters
                self.idleSince = nil
                defer { if self.rescanPending { self.rescanPending = false; self.refresh(quiet: true) } }
                self.record(scan: result)
                self.units = result.units
                self.rememberDrives(result.units)
                self.trackRebuilds(result.units)
                self.trackActiveMember(result.units)
                self.lockedDisks = result.locked
                self.usbGRAIDs = result.usb
                if self.selectedID == nil || !result.units.contains(where: { $0.id == self.selectedID }) {
                    self.selectedID = result.units.first?.id
                }
                self.thunderboltGRAIDs = result.thunderbolt
                // Forget ejected disks once they're unplugged, or once something (Finder, Disk
                // Utility) mounts them again.
                let stillEjected = self.ejectedDisks.filter { result.present.contains($0) && !partitions(onWholeDisk: $0).contains(where: \.isMounted) }
                let remounted = self.ejectedDisks.subtracting(stillEjected).filter(result.present.contains)
                if !remounted.isEmpty { self.scheduleRefresh(after: 0.5) }   // mounted again elsewhere: read it next pass
                self.ejectedDisks = stillEjected
                if !result.units.isEmpty { self.phase = .ready }
                else if !result.locked.isEmpty { self.phase = .needsAccess }
                else if !self.ejectedDisks.isEmpty { self.phase = .ejected }
                else if !result.usb.isEmpty { self.phase = .noDevice }
                else if !result.thunderbolt.isEmpty { self.phase = .startingUp }
                else { self.phase = .noDevice }
                if self.phase == .startingUp {
                    if self.startingSince == nil { self.startingSince = Date() }
                    self.scheduleRefresh(after: 2)
                } else {
                    self.startingSince = nil
                }
                if self.phase == .needsAccess {
                    if self.lockedSince == nil { self.lockedSince = Date() }
                    // A locked disk becomes readable when the unlock service (or the password
                    // prompt) changes its owner: re-check every second, which is just a permission check.
                    self.scheduleRefresh(after: 1)
                } else {
                    self.lockedSince = nil
                }
                self.menuHealth = result.units.map(\.health).max { $0.rank < $1.rank }
                self.lastUpdated = Date()
                self.finishUserRefresh()
            }
        }
    }

    nonisolated static func scan(skipping ejected: Set<String> = []) -> (units: [Unit], locked: [String], usb: [Candidate], present: Set<String>, thunderbolt: [String]) {
        var units: [String: Unit] = [:]
        var order: [String] = []
        var locked: [String] = []
        let all = wholeDisks()
        let usb = all.filter { !$0.isInternal && $0.proto == "USB" && ($0.model + " " + $0.mediaName).localizedCaseInsensitiveContains("G-RAID") }
        for c in candidateDisks() where !ejected.contains(c.bsdName) {
            guard access(c.rawPath, R_OK) == 0 else { locked.append(c.bsdName); continue }
            guard let dev = try? Device(path: c.rawPath),
                  let (st, _) = try? dev.execute(.identify), st == 0x00 || st == 0x20,
                  let (caps, raid, disks) = try? fetchAll(dev) else { continue }
            saveDiagnostics(bsd: c.bsdName, caps: caps, raid: raid, disks: disks, acks: dev.lastAcks)
            if let existing = units[caps.uniqueID] {
                var merged = Unit(path: existing.path, bsdNames: existing.bsdNames + [c.bsdName],
                                  productName: existing.productName, caps: existing.caps,
                                  raid: existing.raid, disks: existing.disks)
                merged.partitions = existing.partitions + partitions(onWholeDisk: c.bsdName)
                units[caps.uniqueID] = merged
            } else {
                order.append(caps.uniqueID)
                let name = (c.model.isEmpty ? c.mediaName : c.model)
                    .split(separator: " ").joined(separator: " ")   // "G-RAID  with Thunderbolt" → single spaces
                var unit = Unit(path: c.rawPath, bsdNames: [c.bsdName], productName: name,
                                caps: caps, raid: raid, disks: disks)
                unit.partitions = partitions(onWholeDisk: c.bsdName)
                // Only while a RAID 1 copy runs or is paused: 16 one-byte reads of controller RAM.
                if caps.currentMode == 2, [2, 8].contains(raid.volume(0).status) {
                    unit.rebuild = readRebuildPosition(dev: dev, caps: caps)
                }
                units[caps.uniqueID] = unit
            }
        }
        return (order.compactMap { units[$0] }, locked, usb, Set(all.map(\.bsdName)), graidsOnThunderbolt())
    }

    /// Raw reply bytes from the last refresh, for troubleshooting without disk access.
    nonisolated static func saveDiagnostics(bsd: String, caps: Capabilities, raid: RaidStatus, disks: DiskStatus, acks: [UInt8: [UInt8]]) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/G-RAID Utility")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func hexString(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
        let obj: [String: Any] = [
            "disk": bsd,
            "time": ISO8601DateFormatter().string(from: Date()),
            "capabilities": hexString(caps.raw),
            "raid_status": hexString(raid.raw),
            "disk_status": hexString(disks.raw),
            "ack_sectors": Dictionary(uniqueKeysWithValues: acks.map { (String(format: "%02x", $0.key), hexString($0.value)) }),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("last-status.json"))
        }
    }

    /// One administrator prompt: the bundled helper identifies G-RAID disks as root and makes
    /// only those readable by this user until they disconnect.
    func requestAccess() {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "graidctl")?.path else {
            message = Notice(.problem, "The graidctl helper is missing from the app", "Reinstall G-RAID Utility to fix it.")
            return
        }
        isWorking = true
        let esc = helper.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script (quoted form of \"\(esc)\") & \" grant-access --uid \(getuid())\" with prompt \"G-RAID Utility needs to read the G-RAID's control sectors.\" with administrator privileges"
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            var failure: String?
            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    failure = text.contains("-128") ? nil : text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                failure = "\(error)"
            }
            let reported = failure
            await MainActor.run {
                self.isWorking = false
                if let f = reported { self.message = Notice(.problem, "Access wasn't granted", f) }
                self.refresh()
            }
        }
    }

    /// Another app (usually Finder) is ejecting one of our disks: stop reading from it, as if
    /// the Eject button had been used, so status checks don't keep the controller busy.
    func noteExternalEject(_ bsd: String) {
        guard let unit = units.first(where: { $0.bsdNames.contains(bsd) }), !ejectedDisks.contains(bsd) else { return }
        ejectedVolumes = unit.volumes.map(\.bsd)   // volumes only: system partitions are never remounted
        ejectedDisks.insert(bsd)
        log([GRAIDEvent(unitID: unit.id, unitName: name(of: unit), category: .connection, severity: .info,
                        title: "Ejected", detail: "From another app, such as Finder")])
        if unit.bsdNames.allSatisfy(ejectedDisks.contains) {
            units.removeAll { $0.id == unit.id }
            if units.isEmpty { phase = .ejected }
        }
    }

    /// Unmount every volume, then eject. If something is using a volume, say which app.
    func eject(_ unit: Unit) {
        isWorking = true
        message = nil
        ejectedVolumes = unit.volumes.map(\.bsd)   // volumes only: system partitions are never remounted
        Task { @MainActor in
            for bsd in unit.bsdNames {
                ejectedDisks.insert(bsd)   // before the eject request, so the watcher doesn't log it twice
                // APFS volumes live on a separate container disk: unmount those first.
                let containers = Set(unit.partitions.filter { $0.physicalDisk == bsd && $0.isAPFS }.map(\.parentDisk)).sorted()
                var why: String?
                // A system partition mounted as root (EFI, via the password prompt) can only be
                // unmounted as root, which would make the whole-disk unmount fail.
                for p in unit.partitions where p.physicalDisk == bsd && p.isMounted && p.kind != .volume && why == nil {
                    if await DiskOps.unmount(p.bsd) == DiskOps.notPermittedText {
                        let r = await Task.detached { DiskOps.asAdmin("unmount", p.bsd, name: p.name) }.value
                        if let r { why = r.isEmpty ? "the password prompt was cancelled" : r }
                    }
                }
                for c in containers { if why == nil { why = await DiskOps.unmountWhole(c) } }
                if why == nil { why = await DiskOps.unmountWhole(bsd) }
                if let why {
                    ejectedDisks.remove(bsd)
                    var apps: [String] = []
                    for v in unit.volumes { for a in await DiskOps.appsUsing(v.url) where !apps.contains(a) { apps.append(a) } }
                    message = Notice(.problem, "The G-RAID couldn't be ejected", apps.isEmpty
                        ? "\(why)."
                        : "It's in use by \(ListFormatter.localizedString(byJoining: apps)). Quit or close files there and try again.")
                    isWorking = false
                    return
                }
                if let why = await DiskOps.eject(bsd) {
                    message = Notice(.info, "The volumes were unmounted, but the eject didn't finish", "\(why). It's still safe to unplug.")
                }
            }
            log([GRAIDEvent(unitID: unit.id, unitName: name(of: unit), category: .connection, severity: .info,
                            title: "Ejected", detail: unit.volumes.map(\.name).joined(separator: ", "))])
            isWorking = false
            units.removeAll { $0.id == unit.id }
            phase = units.isEmpty ? .ejected : .ready
        }
    }

    /// Times random reads to tell whether the drives are spinning (works while ejected too).
    func checkSpinState() {
        let path: String?
        if phase == .ejected, let bsd = ejectedDisks.sorted().first { path = "/dev/r" + bsd }
        else { path = selected?.path }
        guard let path else { return }
        isWorking = true
        message = Notice(.info, "Checking whether the drives are spinning…")
        Task.detached {
            let notice: Notice
            do { notice = Notice(.info, describeSpinState(try measureReadLatency(path: path))) }
            catch { notice = Notice(.problem, "Couldn't check whether the drives are spinning", "\(error)") }
            await MainActor.run { self.message = notice; self.isWorking = false }
        }
    }

    /// Mount exactly the volumes that were mounted before the eject. If none were recorded, or
    /// they no longer exist (APFS containers can be torn down by the eject), mount the whole disk
    /// and unmount any system partition (EFI and so on) that came up with it.
    func mountAgain() {
        isWorking = true
        mounting = true
        message = nil
        let disks = ejectedDisks
        let remembered = ejectedVolumes
        Task { @MainActor in
            var failure: String?
            var mountWhole = remembered.isEmpty
            for v in remembered {
                guard diskExists(v) else { mountWhole = true; continue }
                if let why = await DiskOps.mount(v) { failure = why }
            }
            if mountWhole {
                for bsd in disks.sorted() {
                    let before = partitions(onWholeDisk: bsd)
                    let wasMounted = Set(before.filter(\.isMounted).map(\.bsd))
                    let containers = Set(before.filter(\.isAPFS).map(\.parentDisk)).sorted()
                    var why: String?
                    for d in [bsd] + containers { if let w = await DiskOps.mountWhole(d) { why = why ?? w } }
                    let after = partitions(onWholeDisk: bsd)
                    for p in after where p.isMounted && p.kind != .volume && !wasMounted.contains(p.bsd) {
                        _ = await DiskOps.unmount(p.bsd)
                    }
                    // Whole-disk mounts report partitions that can't be mounted; only a problem if nothing came up.
                    if let why, !after.contains(where: { $0.kind == .volume && $0.isMounted }) { failure = why }
                }
            }
            ejectedVolumes = []
            ejectedDisks = []
            isWorking = false
            mounting = false
            if let f = failure { message = Notice(.problem, "The G-RAID couldn't be mounted", f) }
            scheduleRefresh(after: 1)
        }
    }

    /// Mount one partition (a volume, or a system partition such as EFI when asked for).
    func mount(_ p: Partition) {
        isWorking = true
        message = nil
        Task { @MainActor in
            // System partitions (EFI and similar) mount read-only unless turned off in Settings,
            // so macOS doesn't write its index folders onto them.
            let readOnly = p.kind == .system && Pref.mountSystemReadOnly
            var why = await DiskOps.mount(p.bsd, readOnly: readOnly)
            if why == DiskOps.notPermittedText {
                // EFI and similar: ask for the administrator password and mount as root.
                why = await Task.detached { DiskOps.asAdmin("mount", p.bsd, name: p.name, readOnly: readOnly) }.value
                if why == "" { why = nil }   // cancelled the password prompt: say nothing
            }
            if let why { message = Notice(.problem, "\(p.name) couldn't be mounted", why) }
            isWorking = false
            scheduleRefresh(after: 0.5)
        }
    }

    /// Unmount one partition, leaving the rest of the G-RAID mounted.
    func unmount(_ p: Partition) {
        isWorking = true
        message = nil
        Task { @MainActor in
            var result = await DiskOps.unmount(p.bsd)
            if result == DiskOps.notPermittedText {
                // Mounted as root (EFI): unmount as root too.
                result = await Task.detached { DiskOps.asAdmin("unmount", p.bsd, name: p.name) }.value
                if result == "" { result = nil }
            }
            if let why = result {
                var apps: [String] = []
                if let url = p.mountURL { apps = await DiskOps.appsUsing(url) }
                message = Notice(.problem, "\(p.name) couldn't be unmounted", apps.isEmpty
                    ? why
                    : "It's in use by \(ListFormatter.localizedString(byJoining: apps)). Quit or close files there and try again.")
            }
            isWorking = false
            scheduleRefresh(after: 0.5)
        }
    }

    func changeMode(unit: Unit, mode: TargetMode, name: String) {
        isWorking = true
        message = nil
        let unitName = self.name(of: unit)
        Task.detached {
            var notice: Notice
            var succeeded = false
            do {
                let dev = try Device(path: unit.path)
                let (st, _) = try dev.execute(.identify)
                guard st == 0x00 || st == 0x20 else { throw ToolError("The G-RAID did not respond (\(ackText(st))).") }
                let (_, _, disks) = try fetchAll(dev)
                if let problem = modeChangeProblem(mode: mode, name: name, disks: disks) { throw ToolError(problem) }
                let payload = modeChangePayload(mode: mode, name: name, disks: disks)
                switch try performModeChange(dev: dev, bsdNames: unit.bsdNames, payload: payload) {
                case .accepted:
                    notice = Notice(.done, "Switched to \(mode.label)", "The G-RAID reconnects in a few seconds. Then create a volume on it in Disk Utility.")
                case .noAck:
                    notice = Notice(.info, "The G-RAID is switching to \(mode.label)", "Wait about 30 seconds for it to reconnect, then create a volume on it in Disk Utility.")
                }
                succeeded = true
                let event = GRAIDEvent(unitID: unit.id, unitName: unitName, category: .config, severity: .info,
                                       title: "RAID mode change sent", detail: "\(unit.currentTarget?.label ?? modeText(unit.caps.currentMode)) → \(mode.label), named “\(name)”")
                await MainActor.run { self.log([event]) }
            } catch {
                notice = Notice(.problem, "The mode wasn't changed", "\(error)")
            }
            let reported = notice
            let ok = succeeded
            await MainActor.run {
                self.message = reported
                self.suggestDiskUtility = ok
                self.isWorking = false
                self.scheduleRefresh()
            }
        }
    }
}

/// Calls back on the main run loop whenever any disk appears or disappears.
final class DiskWatcher {
    private let session: DASession
    private let onChange: () -> Void
    private let onEject: (String) -> Void

    /// `onEject` gets the BSD name of any disk another app (Finder, Disk Utility, diskutil)
    /// is about to eject. The watcher always approves; it only listens.
    init(onChange: @escaping () -> Void, onEject: @escaping (String) -> Void = { _ in }) {
        self.onChange = onChange
        self.onEject = onEject
        session = DASessionCreate(kCFAllocatorDefault)!
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { _, ctx in
            Unmanaged<DiskWatcher>.fromOpaque(ctx!).takeUnretainedValue().onChange()
        }, ctx)
        DARegisterDiskDisappearedCallback(session, nil, { _, ctx in
            Unmanaged<DiskWatcher>.fromOpaque(ctx!).takeUnretainedValue().onChange()
        }, ctx)
        DARegisterDiskEjectApprovalCallback(session, nil, { disk, ctx in
            if let name = DADiskGetBSDName(disk) {
                Unmanaged<DiskWatcher>.fromOpaque(ctx!).takeUnretainedValue().onEject(String(cString: name))
            }
            return nil   // approve
        }, ctx)
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }
}
