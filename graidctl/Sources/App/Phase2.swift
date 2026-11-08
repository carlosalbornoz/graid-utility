import AppKit
import DiskArbitration
import Foundation
import SwiftUI

// MARK: - Disk operations (DiskArbitration, asynchronous)

enum DiskOps {
    private final class Op {
        let session = DASessionCreate(kCFAllocatorDefault)!
        var done: ((DADissenter?) -> Void)?
        init() { DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) }
        deinit { DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) }
    }

    /// DiskArbitration refuses some partitions (EFI) to anyone but an administrator.
    static let notPermittedText = "macOS only lets an administrator do this"

    private static func describe(_ d: DADissenter) -> String {
        if let s = DADissenterGetStatusString(d) as String?, !s.isEmpty { return s }
        let code = UInt32(bitPattern: DADissenterGetStatus(d))
        switch code {
        case 0xF8DA0002: return "it's in use"
        case 0xF8DA0004: return "another app has exclusive access to it"
        case 0xF8DA0006: return "it's no longer connected"
        case 0xF8DA0007: return "it isn't mounted"
        case 0xF8DA0008, 0xF8DA0009: return notPermittedText
        case 0xF8DA000A: return "it isn't ready"
        case 0xF8DA000C: return "its format isn't supported"
        default: return String(format: "error 0x%08X", code)
        }
    }

    /// Mount or unmount one partition with `diskutil` as root (one password prompt), for
    /// partitions macOS reserves for administrators. Blocks: call off the main thread.
    nonisolated static func asAdmin(_ verb: String, _ bsd: String, name: String, readOnly: Bool = false) -> String? {
        guard ["mount", "unmount"].contains(verb),
              bsd.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil else { return "invalid partition" }
        let option = verb == "mount" && readOnly ? "readOnly " : ""
        return Admin.run("/usr/sbin/diskutil \(verb) \(option)\(bsd)",
                         prompt: "G-RAID Utility needs an administrator password to \(verb) the \(name) partition.")
    }

    private static func run(_ bsd: String, _ start: (DADisk, UnsafeMutableRawPointer) -> Void) async -> String? {
        let op = Op()
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, op.session, bsd) else { return "\(bsd) is no longer connected." }
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            op.done = { d in c.resume(returning: d.map(describe)) }
            start(disk, Unmanaged.passRetained(op).toOpaque())
        }
    }

    private static let callback: DADiskUnmountCallback = { _, dissenter, ctx in
        let op = Unmanaged<Op>.fromOpaque(ctx!).takeRetainedValue()
        op.done?(dissenter)
    }

    /// Unmount every volume on the whole disk. Returns nil on success, or why it failed.
    static func unmountWhole(_ bsd: String) async -> String? {
        await run(bsd) { disk, ctx in DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), callback, ctx) }
    }

    static func eject(_ bsd: String) async -> String? {
        await run(bsd) { disk, ctx in DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), callback, ctx) }
    }

    /// Mount one volume (partition).
    static func mount(_ bsd: String, readOnly: Bool = false) async -> String? {
        await run(bsd) { disk, ctx in
            guard readOnly else {
                DADiskMountWithArguments(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), callback, ctx, nil)
                return
            }
            // Mount options, as for mount(8), in a NULL-terminated array.
            var argv: [Unmanaged<CFString>?] = [Unmanaged.passUnretained("rdonly" as CFString), nil]
            argv.withUnsafeMutableBufferPointer { args in
                DADiskMountWithArguments(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), callback, ctx, args.baseAddress)
            }
        }
    }

    /// Unmount one volume (partition), leaving the others mounted.
    static func unmount(_ bsd: String) async -> String? {
        await run(bsd) { disk, ctx in DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), callback, ctx) }
    }

    static func mountWhole(_ bsd: String) async -> String? {
        await run(bsd) { disk, ctx in DADiskMountWithArguments(disk, nil, DADiskMountOptions(kDADiskMountOptionWhole), callback, ctx, nil) }
    }

    /// Apps with files open on a volume, for "can't eject, in use by …". Runs lsof in the background.
    static func appsUsing(_ url: URL) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            guard let data = Shell.output("/usr/sbin/lsof", ["-Fc", url.path]) else { return [String]() }
            var names: [String] = []
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("c") {
                let n = String(line.dropFirst())
                if !names.contains(n) { names.append(n) }
            }
            return names
        }.value
    }
}

// MARK: - Health report

enum HealthReport {
    static func text(unit: Unit, events: [GRAIDEvent]) -> String {
        let df = DateFormatter(); df.dateStyle = .long; df.timeStyle = .short
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var s = "G-RAID HEALTH REPORT\n"
        s += "Generated \(df.string(from: Date())) by G-RAID Utility \(version)\n\n"
        s += "DEVICE\n"
        s += "  Name:         \(unit.baseName)\n"
        s += "  Model:        \(unit.model.name)\(unit.model.verified ? "" : " (not yet tested with this utility)")\n"
        s += "  Firmware:     \(unit.caps.firmware)\n"
        s += "  Unique ID:    \(unit.caps.uniqueID)\n"
        s += "  Disk:         \(unit.bsdNames.joined(separator: ", "))\n\n"
        s += "ARRAY\n"
        s += "  Health:       \(unit.health == .good ? "Good" : unit.health == .attention ? "Needs attention" : "Problem")\n"
        s += "  Mode:         \(modeText(unit.caps.currentMode))\n"
        s += "  Status:       \(unit.statusText)\n"
        s += "  Capacity:     \(unit.capacityText)\n"
        if !unit.caps.raidSetName.isEmpty { s += "  Array name:   \(unit.caps.raidSetName)\n" }
        s += "\nPARTITIONS\n"
        if unit.partitions.isEmpty { s += "  None found.\n" }
        for p in unit.partitions {
            let kind = p.kind == .volume ? "volume" : p.kind == .system ? "system" : "macOS can't read it"
            let state = p.isMounted ? "mounted, \(formatBytes(p.used)) used of \(formatBytes(p.total))" : "not mounted"
            s += "  \(p.bsd): \(p.name) · \(p.format) · \(kind) · \(state)\n"
        }
        s += "\nDISKS\n"
        for p in unit.disks.presentPorts {
            s += "  Disk \(p.index + 1): \(p.model)\n"
            s += "          Serial \(p.serial) · \(formatBytes(p.capacityBytes)) · \(diskStatusText(p.status))\n"
        }
        if unit.disks.presentPorts.isEmpty { s += "  No disks reported.\n" }
        let recent = events.filter { $0.unitID == unit.id }.suffix(50)
        s += "\nRECENT EVENTS (\(recent.count))\n"
        if recent.isEmpty { s += "  None recorded.\n" }
        for e in recent.reversed() {
            s += "  \(df.string(from: e.date))  [\(e.severity.rawValue)]  \(e.title)\(e.detail.isEmpty ? "" : " — \(e.detail)")\n"
        }
        func hex(_ b: [UInt8]) -> String {
            stride(from: 0, to: b.count, by: 32).map { i in
                "    " + b[i..<min(i + 32, b.count)].map { String(format: "%02x", $0) }.joined()
            }.joined(separator: "\n")
        }
        s += "\nRAW CONTROLLER REPLIES (for troubleshooting)\n"
        s += "  Capabilities:\n\(hex(unit.caps.raw))\n  RAID status:\n\(hex(unit.raid.raw))\n  Disk status:\n\(hex(unit.disks.raw))\n"
        return s
    }

    /// Paginated PDF via the print system (monospaced body, bold title).
    static func writePDF(_ text: String, to url: URL) -> Bool {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)   // A4
        info.topMargin = 40; info.bottomMargin = 40; info.leftMargin = 40; info.rightMargin = 40
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        let body = NSMutableAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 8.5, weight: .regular)])
        let firstLine = (text as NSString).range(of: "\n").location
        if firstLine != NSNotFound {
            body.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: NSRange(location: 0, length: firstLine))
        }
        view.textStorage?.setAttributedString(body)
        view.sizeToFit()
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        return op.run()
    }

    @MainActor static func export(unit: Unit, events: [GRAIDEvent]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf, .plainText]
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        panel.nameFieldStringValue = "G-RAID Health Report \(day).pdf"
        panel.message = "Save as PDF, or change the extension to .txt for plain text."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = Self.text(unit: unit, events: events)
        if url.pathExtension.lowercased() == "txt" {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        } else {
            _ = writePDF(text, to: url)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Speed test

/// One throughput measurement: the speed over the last interval, and how far through the file
/// (0–1) the phase was when it was taken.
struct SpeedSample: Equatable {
    let at: Double
    let mbps: Double
}

/// Writes then reads a temporary file with the cache bypassed (F_NOCACHE), then deletes it.
/// Each phase reports its own progress, a speed sample about four times a second, and its
/// average when it finishes.
final class SpeedTest: ObservableObject {
    enum Stage: Equatable { case ready, writing, reading, done, failed(String), cancelled }
    enum Phase { case write, read }

    @Published var stage: Stage = .ready
    @Published var writeProgress: Double = 0
    @Published var readProgress: Double = 0
    @Published var writeSamples: [SpeedSample] = []
    @Published var readSamples: [SpeedSample] = []
    /// Smoothed speed of the running phase, for the live readout.
    @Published var liveMBps: Double?
    @Published var writeMBps: Double?
    @Published var readMBps: Double?
    @Published var sizeGB = 4
    let volume: MountedVolume
    /// Called with write MB/s, read MB/s and the test size in GB when a test completes.
    var onFinish: ((Double, Double, Int) -> Void)?
    private var cancelled = false
    private static let interval = 0.25

    init(volume: MountedVolume) { self.volume = volume }

    var freeBytes: Double {
        Double((try? volume.url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity) ?? 0)
    }
    var enoughSpace: Bool { freeBytes > Double(sizeGB) * 1.1e9 + 1e9 }
    var running: Bool { stage == .writing || stage == .reading }

    func cancel() { cancelled = true }

    func start() {
        cancelled = false
        writeMBps = nil; readMBps = nil; liveMBps = nil
        writeProgress = 0; readProgress = 0
        writeSamples = []; readSamples = []
        stage = .writing
        let total = sizeGB * 1_000_000_000
        let url = volume.url.appendingPathComponent(".G-RAID Utility speed test.tmp")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let chunk = 8 * 1024 * 1024
            let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096)
            defer { buf.deallocate(); unlink(url.path) }
            arc4random_buf(buf, chunk)
            func finish(_ s: Stage) { DispatchQueue.main.async { self.liveMBps = nil; self.stage = s } }

            /// Runs one phase, sampling the speed every `interval` seconds. Returns bytes moved,
            /// or nil if cancelled or failed (after calling `finish`).
            func run(_ phase: Phase, fd: Int32) -> Int? {
                var done = 0, lastDone = 0
                var last = Date()
                var smooth: Double?
                while done < total {
                    if cancelled { finish(.cancelled); return nil }
                    let n = phase == .write ? write(fd, buf, min(chunk, total - done)) : read(fd, buf, min(chunk, total - done))
                    if n < 0 || (n == 0 && phase == .write) {
                        finish(.failed("\(phase == .write ? "Writing" : "Reading") failed: \(String(cString: strerror(errno))).")); return nil
                    }
                    if n == 0 { break }
                    done += n
                    let now = Date(), dt = now.timeIntervalSince(last)
                    if dt >= Self.interval || done >= total {
                        let mbps = Double(done - lastDone) / 1e6 / dt
                        smooth = smooth.map { $0 * 0.6 + mbps * 0.4 } ?? mbps
                        let sample = SpeedSample(at: Double(done) / Double(total), mbps: mbps)
                        let live = smooth
                        DispatchQueue.main.async {
                            self.liveMBps = live
                            if phase == .write { self.writeSamples.append(sample); self.writeProgress = sample.at }
                            else { self.readSamples.append(sample); self.readProgress = sample.at }
                        }
                        last = now; lastDone = done
                    }
                }
                return done
            }

            // Write
            var fd = open(url.path, O_CREAT | O_TRUNC | O_WRONLY, 0o600)
            guard fd >= 0 else { return finish(.failed("Couldn't create a test file: \(String(cString: strerror(errno))).")) }
            _ = fcntl(fd, F_NOCACHE, 1)
            var t0 = Date()
            guard let written = run(.write, fd: fd) else { close(fd); return }
            _ = fcntl(fd, F_FULLFSYNC)   // include the drive's own cache flush
            let w = Double(written) / 1e6 / Date().timeIntervalSince(t0)
            close(fd)
            DispatchQueue.main.async { self.writeMBps = w; self.writeProgress = 1; self.liveMBps = nil; self.stage = .reading }

            // Read
            fd = open(url.path, O_RDONLY)
            guard fd >= 0 else { return finish(.failed("Couldn't reopen the test file.")) }
            _ = fcntl(fd, F_NOCACHE, 1)
            t0 = Date()
            guard let readBytes = run(.read, fd: fd) else { close(fd); return }
            let r = Double(readBytes) / 1e6 / Date().timeIntervalSince(t0)
            close(fd)
            DispatchQueue.main.async {
                self.readMBps = r; self.readProgress = 1; self.liveMBps = nil; self.stage = .done
                if let w = self.writeMBps { self.onFinish?(w, r, self.sizeGB) }
            }
        }
    }
}

struct SpeedTestSheet: View {
    @ObservedObject var test: SpeedTest
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Speed Test").font(.title2.weight(.semibold))
                Text("Writes a temporary file to “\(test.volume.name)”, reads it back with caching turned off, then deletes it. Your files aren't touched.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 14) {
                SpeedLane(title: "Write", phase: .write, test: test, scale: scale)
                SpeedLane(title: "Read", phase: .read, test: test, scale: scale)
            }
            Group {
                switch test.stage {
                case .ready:
                    HStack {
                        Text("Test file size")
                        Picker("Test file size", selection: $test.sizeGB) {
                            ForEach([1, 4, 8], id: \.self) { Text("\($0) GB").tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 180)
                        Spacer()
                        Text("\(formatBytes(test.freeBytes)) free").foregroundStyle(.secondary)
                    }
                    if !test.enoughSpace {
                        Label("Not enough free space for this test size.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                case .writing, .reading:
                    Text("Keep other apps off the G-RAID until the test finishes, for a fair result.")
                        .foregroundStyle(.secondary)
                case .done:
                    Text("The G-RAID connects through a 6 Gb/s SATA link, so roughly 550 MB/s is its ceiling over any Thunderbolt version.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                case .failed(let why): Label(why, systemImage: "xmark.octagon").foregroundStyle(.red)
                case .cancelled: Text("Stopped. The test file was deleted.").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            HStack {
                Spacer()
                if test.running {
                    Button("Stop") { test.cancel() }
                } else {
                    Button("Done", action: close).keyboardShortcut(.cancelAction)
                    Button(test.stage == .ready ? "Start" : "Run Again") { test.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!test.enoughSpace)
                }
            }
        }
        .padding(22)
        .frame(width: 520)
        .interactiveDismissDisabled(test.running)
    }

    /// Shared by both lanes so their heights compare: 100 MB/s steps, at least 400.
    private var scale: Double {
        let peak = (test.writeSamples + test.readSamples).map(\.mbps).max() ?? 0
        return max(400, (peak / 100).rounded(.up) * 100)
    }
}

/// One phase of the test: its live or final speed, and a track that fills left to right with the
/// file's progress, the fill's height at each point being the speed measured there.
struct SpeedLane: View {
    let title: String
    let phase: SpeedTest.Phase
    @ObservedObject var test: SpeedTest
    let scale: Double
    private let trackHeight: CGFloat = 46

    private var samples: [SpeedSample] { phase == .write ? test.writeSamples : test.readSamples }
    private var progress: Double { phase == .write ? test.writeProgress : test.readProgress }
    private var average: Double? { phase == .write ? test.writeMBps : test.readMBps }
    private var active: Bool { test.stage == (phase == .write ? .writing : .reading) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Text(stateText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Text(valueText).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(average == nil && !active ? .tertiary : .primary)
                Text("MB/s").font(.caption).foregroundStyle(.secondary)
            }
            track
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(valueText) megabytes per second, \(stateText)")
    }

    private var valueText: String {
        if let a = average { return String(format: "%.0f", a) }
        if active, let l = test.liveMBps { return String(format: "%.0f", l) }
        return "—"
    }

    private var stateText: String {
        if average != nil { return "average" }
        if active {
            let gb = progress * Double(test.sizeGB)
            return String(format: "now · %.1f of %d GB", gb, test.sizeGB)
        }
        switch test.stage {
        case .ready: return ""
        case .writing: return phase == .read ? "next" : ""
        default: return ""
        }
    }

    private var track: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .bottomLeading) {
                shape.fill(.quaternary.opacity(0.6))
                SpeedTrace(samples: samples, scale: scale)
                    .fill(brandBlue.opacity(active || average != nil ? 1 : 0.5))
                    .clipShape(shape)
                if let a = average {
                    // The average as a hairline across the trace.
                    let y = h * (1 - min(1, a / scale))
                    Rectangle().fill(Color.primary.opacity(0.55))
                        .frame(width: w, height: 1)
                        .offset(y: -(h - y))
                }
                if active {
                    // Leading edge: where the file is up to.
                    Rectangle().fill(brandBlue).frame(width: 2, height: h).offset(x: max(0, w * progress - 1))
                }
            }
        }
        .frame(height: trackHeight)
        .animation(.easeOut(duration: 0.25), value: samples.count)
    }
}

/// The speed samples as a stepped area: each sample spans from the previous position in the
/// file to its own, at a height proportional to its speed.
struct SpeedTrace: Shape {
    let samples: [SpeedSample]
    let scale: Double
    func path(in r: CGRect) -> Path {
        var p = Path()
        var x0 = 0.0
        for s in samples {
            let x1 = min(1, s.at)
            let height = r.height * min(1, s.mbps / scale)
            p.addRect(CGRect(x: r.minX + r.width * x0, y: r.maxY - height,
                             width: max(0.5, r.width * (x1 - x0)), height: height))
            x0 = x1
        }
        return p
    }
}

// MARK: - Starting up and ejected states

struct StartingUpView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            asset("Img_Device_GRAID").resizable().scaledToFit().frame(height: 120)
            if model.startingUpTooLong {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("The G-RAID is connected, but its disk hasn't appeared").font(.title3.weight(.semibold))
                Text("Check that it's switched on and both drives are seated, then switch it off and on again.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
            } else {
                ProgressView().controlSize(.small)
                Text("Starting up…").font(.title3.weight(.semibold))
                Text("\(model.thunderboltGRAIDs.first ?? "The G-RAID") is connected. Its disk usually appears within about 30 seconds.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EjectedView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            asset("Img_Device_GRAID").resizable().scaledToFit().frame(height: 120).opacity(0.6)
            Image(systemName: "eject.circle.fill").font(.title).foregroundStyle(.secondary)
            Text("Ejected · safe to unplug").font(.title3.weight(.semibold))
            Text("The utility stops checking the G-RAID while it's ejected.")
                .foregroundStyle(.secondary)
            Button { model.mountAgain() } label: {
                if model.mounting {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Mounting…") }
                } else {
                    Text("Mount Again")
                }
            }
            .controlSize(.large)
            .disabled(model.isWorking)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
