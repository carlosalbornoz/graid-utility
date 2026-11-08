// Renders the app's screens offscreen with sample data (no hardware needed):
// tests/render_previews.sh → build/previews/*.png
import AppKit
import SwiftUI

func sampleUnit(rebuilding: Bool) -> Unit {
    var caps = [UInt8](repeating: 0, count: 0x48)
    caps[0] = 0x21
    caps.replaceSubrange(8..<16, with: [0, 0, 0x16, 0x05, 0x24, 0x00, 0x01, 0x02])
    caps[36] = 2
    caps.replaceSubrange(49..<55, with: Array("G-RAID".utf8))
    caps.replaceSubrange(64..<72, with: [0x29, 0x51, 0x0c, 0x7a, 0x33, 0x19, 0x02, 0xa4])
    var raid = [UInt8](repeating: 0, count: 0xA4)
    raid[0] = 2; raid[1] = 2; raid[2] = 1
    raid[4] = rebuilding ? 2 : 0; raid[5] = 2
    raid.replaceSubrange(10..<12, with: [0x02, 0x00])
    raid.replaceSubrange(12..<20, with: [0, 0, 0, 0x01, 0xD1, 0xC0, 0xBE, 0xB0]) // 7814037168 blocks (4 TB)
    raid.replaceSubrange(36..<44, with: [0, 0, 0, 0, 0xC4, 0x00, 0x00, 0x00])    // rebuild position
    func port(_ model: String, _ serial: String, status: UInt8) -> [UInt8] {
        var p = [UInt8](repeating: 0x20, count: 76)
        p[0] = status; p[1] = 0; p[2] = 0; p[3] = 0
        func put(_ s: String, _ o: Int, _ n: Int) {
            var b = Array(s.utf8) + [UInt8](repeating: 0x20, count: n)
            b = Array(b.prefix(n))
            for i in stride(from: 0, to: n, by: 2) { p[o + i] = b[i + 1]; p[o + i + 1] = b[i] }
        }
        put(model, 4, 40); put(serial, 44, 20)
        p[64] = 0; p[65] = 0
        p.replaceSubrange(66..<68, with: [0x02, 0x00])
        p.replaceSubrange(68..<76, with: [0, 0, 0, 0x01, 0xD1, 0xC0, 0xBE, 0xB0])
        return p
    }
    var disks = [UInt8](repeating: 0, count: 0x180)
    disks[0] = 2; disks[1] = 5; disks[2] = 2
    disks.replaceSubrange(4..<80, with: port("HGST HUS726040ALA610", "K4K1ABCD", status: 0))
    disks.replaceSubrange(80..<156, with: port("HGST HUS726040ALA610", "K4K1WXYZ", status: rebuilding ? 1 : 0))
    for i in 2..<5 { disks[4 + i * 76] = 2 }
    return Unit(path: "/dev/rdisk4", bsdNames: ["disk4"], productName: "G-RAID",
                caps: Capabilities(raw: caps), raid: RaidStatus(raw: raid), disks: DiskStatus(raw: disks))
}

/// A unit with any mode and drives: (model, serial, status, size in 512-byte sectors).
func customUnit(mode: UInt8, volumeStatus: UInt8 = 0, volumeBlocks: UInt64, tag: UInt64 = 0,
                drives: [(String, String, UInt8, UInt64)?]) -> Unit {
    var caps = [UInt8](repeating: 0, count: 0x48)
    caps[0] = 0x21
    caps.replaceSubrange(8..<16, with: [0, 0, 0x14, 0x08, 0x27, 0x30, 0x02, 0x11])
    caps[36] = mode
    caps.replaceSubrange(49..<55, with: Array("G-RAID".utf8))
    caps.replaceSubrange(64..<72, with: [0x4a, 0x83, 0x27, 0x8d, 0xa7, 0x4e, 0xca, 0x68 &+ mode])
    func be(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (56 - 8 * UInt64($0))) & 0xFF) } }
    var raid = [UInt8](repeating: 0, count: 0xA4)
    raid[0] = mode; raid[1] = 2; raid[2] = 1
    raid[4] = volumeStatus; raid[5] = mode
    raid.replaceSubrange(10..<12, with: [0x02, 0x00])
    raid.replaceSubrange(12..<20, with: be(volumeBlocks))
    raid.replaceSubrange(36..<44, with: be(tag))
    func port(_ model: String, _ serial: String, status: UInt8, blocks: UInt64) -> [UInt8] {
        var p = [UInt8](repeating: 0x20, count: 76)
        p[0] = status; p[1] = 0; p[2] = 0; p[3] = 0
        func put(_ s: String, _ o: Int, _ n: Int) {
            var b = Array(s.utf8) + [UInt8](repeating: 0x20, count: n)
            b = Array(b.prefix(n))
            for i in stride(from: 0, to: n, by: 2) { p[o + i] = b[i + 1]; p[o + i + 1] = b[i] }
        }
        put(model, 4, 40); put(serial, 44, 20)
        p[64] = 0; p[65] = 0
        p.replaceSubrange(66..<68, with: [0x02, 0x00])
        p.replaceSubrange(68..<76, with: be(blocks))
        return p
    }
    var disks = [UInt8](repeating: 0, count: 0x180)
    disks[0] = mode; disks[1] = 5; disks[2] = UInt8(drives.compactMap { $0 }.count)
    for i in 0..<5 {
        if i < drives.count, let d = drives[i] {
            disks.replaceSubrange((4 + i * 76)..<(80 + i * 76), with: port(d.0, d.1, status: d.2, blocks: d.3))
        } else { disks[4 + i * 76] = 2 }
    }
    return Unit(path: "/dev/rdisk4", bsdNames: ["disk4"], productName: "G-RAID",
                caps: Capabilities(raw: caps), raid: RaidStatus(raw: raid), disks: DiskStatus(raw: disks))
}

@MainActor func render(_ name: String, _ model: AppModel, dark: Bool = false) {
    renderView(name, AnyView(ContentView().environmentObject(model)), dark: dark)
}

@MainActor func renderView(_ name: String, _ view: AnyView, dark: Bool = false) {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("\(name).png")
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path)")
}

@main
struct RenderPreviews {
    @MainActor static func main() {
        _ = NSApplication.shared
        let ready = AppModel(); ready.units = [sampleUnit(rebuilding: true)]; ready.phase = .ready
        render("ready-rebuilding", ready)
        let ok = AppModel(); ok.units = [sampleUnit(rebuilding: false)]; ok.phase = .ready
        render("ready-online", ok)
        // Array view: the real unit's drives, and the states a drive can be in.
        let tb4: UInt64 = 7_814_037_168
        let hgst = "HGST HUS724040ALE640"
        let r0 = AppModel(); r0.units = [customUnit(mode: 1, volumeBlocks: tb4 * 2, drives: [(hgst, "PK1334PEHT4U9S", 0, tb4), (hgst, "PK1334PEHNVSSS", 0, tb4)])]; r0.phase = .ready
        render("array-raid0", r0)
        render("array-raid0-dark", r0, dark: true)
        let mis = AppModel(); mis.units = [customUnit(mode: 1, volumeBlocks: 7_700_000_000 * 2, drives: [(hgst, "PK1334PEHT4U9S", 0, tb4), ("ST4000DM004-2CV104", "ZFN1A2B3", 0, 7_700_000_000)])]; mis.phase = .ready
        render("array-mismatch", mis)
        let full = customUnit(mode: 2, volumeBlocks: tb4, drives: [("WDC WD40EFRX-68N32N0", "WD-WCC7K1234567", 0, tb4), ("WDC WD40EFRX-68N32N0", "WD-WCC7K7654321", 0, tb4)])
        let gone = customUnit(mode: 2, volumeBlocks: tb4, drives: [("WDC WD40EFRX-68N32N0", "WD-WCC7K1234567", 0, tb4), ("", "", 3, 0)])
        let miss = AppModel(); miss.rememberDrives([full]); miss.units = [gone]; miss.phase = .ready
        render("array-raid1-missing", miss)
        let fail = AppModel(); fail.units = [customUnit(mode: 2, volumeBlocks: tb4, drives: [("Samsung SSD 870 QVO 4TB", "S5VYNJ0R123456A", 7, tb4), ("Samsung SSD 870 QVO 4TB", "S5VYNJ0R654321B", 8, tb4)])]; fail.phase = .ready
        render("array-raid1-failing", fail)
        let reb = AppModel(); reb.units = [customUnit(mode: 2, volumeStatus: 2, volumeBlocks: 7_813_922_816, drives: [("WDC WD40EFRX-68N32N0", "WD-WCC7K1234567", 0, tb4), ("WDC WD40EFRX-68N32N0", "WD-WCC7K7654321", 1, tb4)])]; reb.phase = .ready
        render("array-raid1-rebuilding", reb)
        // Replace a Drive: each step, read from the unit's status.
        let wd = "WDC WD40EFRX-68N32N0"
        func sheetFor(_ u: Unit, _ m: AppModel) -> AnyView {
            AnyView(ReplaceDriveSheet(unitID: u.id, previewUnit: u, previewSince: Date(timeIntervalSince1970: 1_762_600_000)) {}.environmentObject(m))
        }
        let rFailed = customUnit(mode: 2, volumeStatus: 1, volumeBlocks: 7_813_922_816, drives: [(wd, "WD-WCC7K1234567", 0, tb4), (wd, "WD-WCC7K7654321", 8, tb4)])
        let rEmpty = customUnit(mode: 2, volumeStatus: 1, volumeBlocks: 7_813_922_816, drives: [(wd, "WD-WCC7K1234567", 0, tb4), nil])
        let rForeign = customUnit(mode: 2, volumeStatus: 1, volumeBlocks: 7_813_922_816, drives: [(wd, "WD-WCC7K1234567", 0, tb4), ("ST4000DM004-2CV104", "ZFN1A2B3", 5, tb4)])
        let rCopy = customUnit(mode: 2, volumeStatus: 2, volumeBlocks: 7_813_922_816, drives: [(wd, "WD-WCC7K1234567", 0, tb4), ("ST4000DM004-2CV104", "ZFN1A2B3", 1, tb4)])
        let rFail = customUnit(mode: 2, volumeStatus: 3, volumeBlocks: 7_813_922_816, drives: [(wd, "WD-WCC7K1234567", 0, tb4), ("ST4000DM004-2CV104", "ZFN1A2B3", 0, tb4)])
        let rm = AppModel(); rm.units = [rEmpty]; rm.phase = .ready
        render("array-raid1-empty-bay", rm)
        renderView("replace-remove", sheetFor(rFailed, rm))
        renderView("replace-insert", sheetFor(rEmpty, rm))
        renderView("replace-waiting", sheetFor(rForeign, rm))
        renderView("replace-copying", sheetFor(rCopy, rm))
        renderView("replace-failed", sheetFor(rFail, rm))
        renderView("change-step1-mismatch", AnyView(ChangeModeSheet(unit: mis.units[0], preview: (1, .raid1, ""), commit: { _, _ in }, cancel: {})))
        let ind = AppModel(); ind.units = [customUnit(mode: 0, volumeBlocks: 0, drives: [(hgst, "PK1334PEHT4U9S", 0, tb4), nil])]; ind.phase = .ready
        render("array-individual-empty", ind)
        let locked = AppModel(); locked.lockedDisks = ["disk4"]; locked.phase = .needsAccess
        render("needs-access", locked)
        let none = AppModel(); none.phase = .noDevice
        render("no-device", none)
        var u = sampleUnit(rebuilding: false)
        u.partitions = [
            Partition(bsd: "disk4s1", physicalDisk: "disk4", parentDisk: "disk4", name: "EFI", size: 209.7e6, format: "MS-DOS (FAT32)",
                      kind: .system, mountable: true, mountURL: nil, used: 0, total: 0, readOnly: false),
            Partition(bsd: "disk4s2", physicalDisk: "disk4", parentDisk: "disk4", name: "G-RAID", size: 8.0e12, format: "ExFAT",
                      kind: .volume, mountable: true, mountURL: URL(fileURLWithPath: "/Volumes/G-RAID"), used: 718e9, total: 8.0e12, readOnly: false),
        ]
        let withVol = AppModel(); withVol.units = [u]; withVol.phase = .ready
        render("ready-with-volume", withVol)
        renderView("change-step1", AnyView(ChangeModeSheet(unit: u, preview: (1, nil, ""), commit: { _, _ in }, cancel: {})))
        renderView("change-step1-selected", AnyView(ChangeModeSheet(unit: u, preview: (1, .raid0, ""), commit: { _, _ in }, cancel: {})))
        let hist = AppModel()
        hist.recentEvents = [
            GRAIDEvent(date: Date(timeIntervalSinceNow: -86400 * 2), unitID: "u", unitName: "G-RAID with Thunderbolt", category: .connection, severity: .info, title: "Connected", detail: "Performance - RAID 0"),
            GRAIDEvent(date: Date(timeIntervalSinceNow: -7200), unitID: "u", unitName: "G-RAID with Thunderbolt", category: .disk, severity: .critical, title: "Disk 2 predicts failure", detail: "Online → Predictive Failure"),
            GRAIDEvent(date: Date(timeIntervalSinceNow: -600), unitID: "u", unitName: "G-RAID with Thunderbolt", category: .connection, severity: .warning, title: "Disconnected", detail: ""),
        ]
        let act = AppModel(); act.units = [u]; act.phase = .ready; act.tab = .activity
        act.recentEvents = [
            GRAIDEvent(date: Date(timeIntervalSinceNow: -86400 * 3), unitID: u.id, unitName: "G-RAID", category: .connection, severity: .info, title: "Connected", detail: "Protected - RAID 1"),
            GRAIDEvent(date: Date(timeIntervalSinceNow: -86400 * 2), unitID: u.id, unitName: "G-RAID", category: .disk, severity: .critical, title: "Disk 2 predicts failure", detail: "Online → Predictive Failure"),
            GRAIDEvent(date: Date(timeIntervalSinceNow: -7200), unitID: u.id, unitName: "G-RAID", category: .connection, severity: .warning, title: "Disconnected", detail: ""),
            GRAIDEvent(date: Date(timeIntervalSinceNow: -3600), unitID: u.id, unitName: "G-RAID", category: .connection, severity: .info, title: "Ejected", detail: ""),
            GRAIDEvent(date: Date(timeIntervalSinceNow: -600), unitID: u.id, unitName: "G-RAID", category: .connection, severity: .info, title: "Connected", detail: "Protected - RAID 1"),
        ]
        UserDefaults.standard.set(try! JSONEncoder().encode(SpeedResult(date: Date(), writeMBps: 283, readMBps: 335, sizeGB: 4, volume: "G-RAID")), forKey: "lastSpeedTest." + u.id)
        render("activity", act)
        render("activity-dark", act, dark: true)
        let starting = AppModel(); starting.phase = .startingUp; starting.thunderboltGRAIDs = ["G-RAID with Thunderbolt"]
        render("starting-up", starting)
        let ejected = AppModel(); ejected.phase = .ejected
        render("ejected", ejected)
        func trace(_ base: Double, upTo end: Double, wobble: Double) -> [SpeedSample] {
            stride(from: 0.02, through: end, by: 0.02).map { x in SpeedSample(at: x, mbps: base + wobble * sin(x * 37) + (x > 0.8 ? -40 * (x - 0.8) * 5 : 0)) }
        }
        let st = SpeedTest(volume: u.volumes[0])
        st.writeSamples = trace(290, upTo: 1, wobble: 18); st.readSamples = trace(340, upTo: 1, wobble: 10)
        st.writeMBps = 283; st.readMBps = 335; st.writeProgress = 1; st.readProgress = 1; st.stage = .done
        let running = SpeedTest(volume: u.volumes[0])
        running.writeSamples = trace(290, upTo: 1, wobble: 18); running.writeMBps = 283; running.writeProgress = 1
        running.readSamples = trace(340, upTo: 0.46, wobble: 10); running.readProgress = 0.46; running.liveMBps = 338; running.stage = .reading
        renderView("speed-test-running", AnyView(SpeedTestSheet(test: running, close: {})))
        renderView("speed-test-ready", AnyView(SpeedTestSheet(test: SpeedTest(volume: u.volumes[0]), close: {})))
        renderView("speed-test", AnyView(SpeedTestSheet(test: st, close: {})))
        let reportText = HealthReport.text(unit: u, events: hist.recentEvents)
        try! reportText.write(toFile: CommandLine.arguments[1] + "/health-report.txt", atomically: true, encoding: .utf8)
        print("pdf:", HealthReport.writePDF(reportText, to: URL(fileURLWithPath: CommandLine.arguments[1] + "/health-report.pdf")))
        renderView("history", AnyView(HistoryView().environmentObject(hist).frame(width: 860, height: 260)))
        renderView("settings", AnyView(SettingsView().environmentObject(hist)))
        renderView("change-step2", AnyView(ChangeModeSheet(unit: u, preview: (2, .raid0, "ERA"), commit: { _, _ in }, cancel: {})))
    }
}
