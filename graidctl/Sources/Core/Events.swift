// Event history: what changed between two status reads, and an append-only log on disk.

import Foundation

enum EventCategory: String, Codable, CaseIterable {
    case disk, array, connection, config
}

enum EventSeverity: String, Codable, Comparable {
    case info, warning, critical
    private var rank: Int { self == .info ? 0 : self == .warning ? 1 : 2 }
    static func < (a: EventSeverity, b: EventSeverity) -> Bool { a.rank < b.rank }
}

struct GRAIDEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    let unitID: String
    let unitName: String
    let category: EventCategory
    let severity: EventSeverity
    let title: String
    let detail: String
}

/// The parts of a status read that matter for change detection.
struct UnitSnapshot: Equatable {
    let id: String
    let name: String
    let mode: UInt8
    let volumeStatus: UInt8
    let ports: [Int: UInt8]          // bay index → disk status, present disks only
    let portModels: [Int: String]

    init(id: String, name: String, caps: Capabilities, raid: RaidStatus, disks: DiskStatus) {
        self.id = id
        self.name = name
        mode = caps.currentMode
        volumeStatus = raid.volume(0).status
        var p: [Int: UInt8] = [:], m: [Int: String] = [:]
        for port in disks.presentPorts { p[port.index] = port.status; m[port.index] = port.model }
        ports = p
        portModels = m
    }
}

private let badDisk: Set<UInt8> = [3, 5, 6, 7, 8]          // missing, ID mismatch, rejected, predictive, failed
private let badArray: Set<UInt8> = [1, 3, 4, 7, 0x11]      // degraded, rebuild failed, data lost, verify failed, broken

/// Events between two scans. `confirmedGone` lists units that disappeared for real (their disk
/// is gone or they were missing twice in a row); others missing once are ignored as a glitch.
func diffSnapshots(old: [String: UnitSnapshot], new: [String: UnitSnapshot], confirmedGone: Set<String>) -> [GRAIDEvent] {
    var out: [GRAIDEvent] = []
    func ev(_ u: UnitSnapshot, _ c: EventCategory, _ s: EventSeverity, _ t: String, _ d: String = "") {
        out.append(GRAIDEvent(unitID: u.id, unitName: u.name, category: c, severity: s, title: t, detail: d))
    }

    for (id, u) in new.sorted(by: { $0.key < $1.key }) {
        guard let o = old[id] else {
            ev(u, .connection, .info, "Connected", modeText(u.mode))
            continue
        }
        if o.mode != u.mode {
            ev(u, .config, .info, "RAID mode changed", "\(modeText(o.mode)) → \(modeText(u.mode))")
        }
        if o.volumeStatus != u.volumeStatus && u.mode != 0 {
            let from = volumeStatusText(o.volumeStatus), to = volumeStatusText(u.volumeStatus)
            if o.volumeStatus == 2 && u.volumeStatus == 0 {
                ev(u, .array, .info, "Rebuild finished", "The array is online again.")
            } else if u.volumeStatus == 2 {
                ev(u, .array, .warning, "Rebuild started", "\(from) → \(to)")
            } else if badArray.contains(u.volumeStatus) {
                ev(u, .array, .critical, "Array \(to.lowercased())", "\(from) → \(to)")
            } else if u.volumeStatus == 0 {
                ev(u, .array, .info, "Array online", "\(from) → \(to)")
            } else {
                ev(u, .array, .warning, "Array \(to.lowercased())", "\(from) → \(to)")
            }
        }
        for bay in Set(o.ports.keys).union(u.ports.keys).sorted() {
            let label = "Disk \(bay + 1)"
            switch (o.ports[bay], u.ports[bay]) {
            case (nil, let n?):
                ev(u, .disk, .info, "\(label) inserted", "\(u.portModels[bay] ?? "") · \(diskStatusDisplay(n))")
            case (_?, nil):
                ev(u, .disk, .warning, "\(label) removed", o.portModels[bay] ?? "")
            case (let a?, let b?) where a != b:
                let sev: EventSeverity = badDisk.contains(b) ? .critical : (b == 0 || b == 9 ? .info : .warning)
                let title = b == 7 ? "\(label) predicts failure" : b == 6 ? "\(label) being checked" : "\(label) \(diskStatusDisplay(b).lowercased())"
                ev(u, .disk, sev, title, "\(diskStatusText(a)) → \(diskStatusText(b))")
            default: break
            }
        }
    }
    for id in confirmedGone.sorted() {
        if let o = old[id] { ev(o, .connection, .warning, "Disconnected") }
    }
    return out
}

/// What became of the units that were in the last scan and aren't in this one.
/// - `ejected`: the user ejected it and its disks are still attached. It keeps its last state.
/// - `glitch`: its disk is still there but it didn't answer, once. It keeps its last state too.
/// - `gone`: its disk is gone, or it didn't answer twice in a row.
/// `diskNames` holds the disks each unit was last seen on; `missCount` is updated in place.
func resolveMissingUnits(_ missing: [String], diskNames: [String: [String]], ejected: Set<String>, present: Set<String>,
                         missCount: inout [String: Int]) -> (gone: Set<String>, ejected: Set<String>, glitch: Set<String>) {
    var gone = Set<String>(), kept = Set<String>(), glitch = Set<String>()
    for id in missing {
        let bsds = diskNames[id] ?? []
        if !bsds.isEmpty, bsds.allSatisfy({ ejected.contains($0) && present.contains($0) }) {
            kept.insert(id)
            continue
        }
        let diskGone = !bsds.contains(where: present.contains)
        missCount[id, default: 0] += 1
        if diskGone || missCount[id, default: 0] >= 2 {
            gone.insert(id)
            missCount[id] = nil
        } else {
            glitch.insert(id)
        }
    }
    return (gone, kept, glitch)
}

/// Append-only JSON-lines log in Application Support.
final class EventLog {
    let url: URL

    init(url: URL? = nil) {
        if let url { self.url = url; return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("G-RAID Utility")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("events.jsonl")
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    private static func lines(_ events: [GRAIDEvent]) -> Data {
        var data = Data()
        for e in events { if let line = try? encoder.encode(e) { data.append(line); data.append(0x0A) } }
        return data
    }

    /// Returns false when the events couldn't be written (a full disk, a folder that can't be
    /// written to). Uses the throwing file calls: the older ones raise an exception instead.
    @discardableResult
    func append(_ events: [GRAIDEvent]) -> Bool {
        guard !events.isEmpty else { return true }
        let data = Self.lines(events)
        do {
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: data)
            } else {
                try data.write(to: url)
            }
            return true
        } catch {
            return false
        }
    }

    /// The newest `limit` events. When the file has grown to more than twice that, it is cut
    /// back to those events, so it can't grow without end.
    func load(limit: Int = 2000) -> [GRAIDEvent] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let events = text.split(separator: "\n").compactMap { try? Self.decoder.decode(GRAIDEvent.self, from: Data($0.utf8)) }
        let newest = Array(events.suffix(limit))
        if events.count > 2 * limit { try? Self.lines(newest).write(to: url, options: .atomic) }
        return newest
    }

    func clear() { try? FileManager.default.removeItem(at: url) }

    static func csv(_ events: [GRAIDEvent]) -> String {
        let f = ISO8601DateFormatter()
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return (["date,device,category,severity,event,detail"] + events.map {
            [f.string(from: $0.date), q($0.unitName), $0.category.rawValue, $0.severity.rawValue, q($0.title), q($0.detail)].joined(separator: ",")
        }).joined(separator: "\n") + "\n"
    }
}
