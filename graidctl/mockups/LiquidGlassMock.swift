// Liquid Glass redesign mockup. Standalone: sample data from the real unit, no hardware access.
// Build and screenshot with mockups/render_mock.sh. Not part of the app.
//
// Direction: glass for controls, solid for content. Liquid Glass is the navigation layer (the
// toolbar, the section control, and the overview panel floating like a macOS 26 sidebar).
// Content sits on the system background in quiet hairline groups. No gradients, no glows.
// One accent (G-Technology blue) for data and selection; system green/orange/red for status.

import AppKit
import SwiftUI

// MARK: - Sample data (values read from the user's G-RAID on 2026-11-07)

enum Sample {
    static let model = "G-RAID with Thunderbolt"
    static let firmware = "140827300211"
    static let usedGB = 717.8
    static let totalGB = 8001.3
    struct Disk { let bay: Int; let model: String; let serial: String; let size: String }
    static let disks = [
        Disk(bay: 1, model: "HGST HUS724040ALE640", serial: "PK1334PEHT4U9S", size: "4.00 TB"),
        Disk(bay: 2, model: "HGST HUS724040ALE640", serial: "PK1334PEHNVSSS", size: "4.00 TB"),
    ]
    struct Event { let time: String; let title: String; let detail: String; let symbol: String; let tint: Color }
    static let events = [
        Event(time: "8:10 PM", title: "Disconnected", detail: "", symbol: "xmark.circle", tint: .orange),
        Event(time: "8:07 PM", title: "Ejected", detail: "From another app, such as Finder", symbol: "eject.circle", tint: .secondary),
        Event(time: "7:59 PM", title: "Ejected", detail: "G-RAID", symbol: "eject.circle", tint: .secondary),
        Event(time: "7:38 PM", title: "Connected", detail: "Performance · RAID 0", symbol: "checkmark.circle", tint: .green),
        Event(time: "7:37 PM", title: "Disconnected", detail: "", symbol: "xmark.circle", tint: .orange),
    ]
}

/// G-Technology blue, the single accent.
let accent = Color(red: 0.0, green: 0.56, blue: 0.80)

func resourceImage(_ name: String) -> Image {
    if let url = Bundle.main.url(forResource: name, withExtension: "png"), let img = NSImage(contentsOf: url) {
        return Image(nsImage: img)
    }
    return Image(systemName: "externaldrive")
}

func gb(_ v: Double) -> String { v >= 1000 ? String(format: "%.2f TB", v / 1000) : String(format: "%.1f GB", v) }

// MARK: - App

enum Tab: String, CaseIterable, Identifiable {
    case disks = "Disks", raid = "RAID", volumes = "Volumes", activity = "Activity"
    var id: Self { self }
}

final class MockState: ObservableObject {
    @Published var tab: Tab
    @Published var showSystem: Bool
    let scheme: ColorScheme?
    init() {
        let args = CommandLine.arguments
        func value(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        tab = Tab.allCases.first { $0.rawValue.lowercased() == value("--tab") } ?? .disks
        showSystem = args.contains("--show-system")
        scheme = value("--appearance") == "light" ? .light : value("--appearance") == "dark" ? .dark : nil
    }
}

@main
struct MockApp: App {
    @StateObject private var state = MockState()
    var body: some Scene {
        Window("G-RAID Utility", id: "main") {
            MockRoot().environmentObject(state).preferredColorScheme(state.scheme)
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified)
    }
}

// MARK: - Building blocks

/// A content group: system background, hairline edge. Not glass: content isn't the control layer.
struct Group_<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }
}

struct Heading: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct StatusDot: View {
    let text: String
    var color: Color = .green
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.callout)
        }
    }
}

struct Meter: View {
    let fraction: Double
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(accent).frame(width: max(height, g.size.width * fraction))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Root

struct MockRoot: View {
    @EnvironmentObject var state: MockState
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            OverviewPanel().frame(width: 272)
            Group {
                switch state.tab {
                case .disks: DisksTab()
                case .raid: RaidTab()
                case .volumes: VolumesTab()
                case .activity: ActivityTab()
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 20)
        .frame(width: 940, height: 500)
        .tint(accent)
        .navigationTitle(Sample.model)
        .navigationSubtitle("Thunderbolt · disk4")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $state.tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 340)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { } label: { Image(systemName: "eject") }.help("Eject")
                Button { } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
            }
        }
    }
}

// MARK: - Left: overview (the one glass surface in the content area)

struct OverviewPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            resourceImage("Img_Device_GRAID").resizable().interpolation(.high).scaledToFit()
                .frame(maxWidth: .infinity).frame(height: 118)
                .padding(.top, 6)

            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Healthy").font(.title3.weight(.semibold))
                    Text("Both disks working normally").font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                spec("Capacity", "8.00 TB")
                spec("Mode", "RAID 0 · Performance")
                spec("Disks", "2 of 2 online")
                spec("Firmware", Sample.firmware)
            }
            .font(.callout)

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("G-RAID", systemImage: "externaldrive").font(.callout.weight(.medium))
                    Spacer()
                    Button { } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("Show in Finder")
                }
                Meter(fraction: Sample.usedGB / Sample.totalGB)
                Text("\(gb(Sample.usedGB)) used of 8.00 TB").font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button { } label: { Label("Speed Test", systemImage: "speedometer").frame(maxWidth: .infinity) }
                Button { } label: { Label("Report", systemImage: "doc.text").frame(maxWidth: .infinity) }
            }
            .controlSize(.large)
        }
        .padding(18)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func spec(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).monospacedDigit().textSelection(.enabled)
        }
    }
}

// MARK: - Disks tab

struct DisksTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Heading(title: "Both bays online", detail: "Two 4 TB disks, striped together as one RAID 0 volume.")
            HStack(alignment: .top, spacing: 14) {
                ForEach(Sample.disks, id: \.bay) { d in BayGroup(disk: d) }
            }
            Text("Temperature and fan speed aren't reported by this model's controller.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct BayGroup: View {
    let disk: Sample.Disk
    var body: some View {
        Group_ {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Bay \(disk.bay)").font(.headline)
                    Spacer()
                    StatusDot(text: "Online")
                }
                DriveSled(status: .green).frame(height: 128).frame(maxWidth: .infinity)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow { Text("Model").foregroundStyle(.secondary); Text(disk.model) }
                    GridRow { Text("Serial").foregroundStyle(.secondary); Text(disk.serial).monospacedDigit().textSelection(.enabled) }
                    GridRow { Text("Size").foregroundStyle(.secondary); Text(disk.size).monospacedDigit() }
                }
                .font(.callout)
            }
        }
    }
}

/// A drive sled in line art, drawn in the weight of SF Symbols: outline, grille, pull handle,
/// and a solid status light. Flat fills only.
struct DriveSled: View {
    let status: Color
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background)
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.secondary.opacity(0.6), lineWidth: 1.5)
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    ForEach(0..<6, id: \.self) { _ in Capsule().fill(.quaternary).frame(height: 3) }
                }
                .padding(.horizontal, 22).padding(.top, 20)
                Spacer()
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.6), lineWidth: 1.5).frame(width: 54, height: 12)
                    Spacer()
                    Circle().fill(status).frame(width: 8, height: 8)
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
            }
        }
        .frame(width: 196)
    }
}

// MARK: - RAID tab

enum MockMode { case individual, raid0, raid1 }

struct RaidTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Heading(title: "RAID 0 · Performance", detail: "Files are split into blocks that alternate between the disks, so both work at once.")
            Group_(padding: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    BlockDiagram(mode: .raid0).frame(maxWidth: .infinity)
                    Label {
                        Text("No redundancy. If either disk fails, everything on the G-RAID is lost, so keep a backup.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.callout)
                }
            }
            HStack(spacing: 12) {
                ModeOption(mode: .individual, title: "Individual", result: "4 TB + 4 TB", current: false)
                ModeOption(mode: .raid0, title: "RAID 0", result: "8 TB, fastest", current: true)
                ModeOption(mode: .raid1, title: "RAID 1", result: "4 TB, mirrored", current: false)
            }
            HStack {
                Text("Changing the mode erases both disks.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Change RAID Mode…") { }.controlSize(.large)
            }
        }
    }
}

/// How a file's blocks land on the two disks. Flat blocks in the accent; mirrored copies outlined.
struct BlockDiagram: View {
    let mode: MockMode
    var compact = false

    var body: some View {
        HStack(alignment: .center, spacing: compact ? 6 : 16) {
            if !compact {
                VStack(spacing: 6) {
                    HStack(spacing: 3) {
                        ForEach(1...4, id: \.self) { i in block("A\(i)", .filled(accent)).frame(width: 30) }
                    }
                    Text("One file").font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.right").font(.title3).foregroundStyle(.tertiary)
            }
            disk("Disk 1", items: items(0))
            disk("Disk 2", items: items(1))
        }
    }

    enum Fill { case filled(Color), outline(Color), empty }

    private func items(_ d: Int) -> [(String, Fill)] {
        switch mode {
        case .raid0: return [("A1", "A3"), ("A2", "A4")][d] |> { [($0.0, .filled(accent)), ($0.1, .filled(accent)), ("", .empty), ("", .empty)] }
        case .raid1: return ["A1", "A2", "A3", "A4"].map { ($0, d == 0 ? .filled(accent) : .outline(accent)) }
        case .individual: return d == 0
            ? ["A1", "A2", "A3", "A4"].map { ($0, .filled(accent)) }
            : [("B1", .filled(.secondary)), ("B2", .filled(.secondary)), ("", .empty), ("", .empty)]
        }
    }

    private func block(_ label: String, _ fill: Fill) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 2 : 5, style: .continuous)
        return ZStack {
            switch fill {
            case .filled(let c): shape.fill(c)
            case .outline(let c): shape.strokeBorder(c, lineWidth: compact ? 1 : 1.5)
            case .empty: Color.clear
            }
            if !compact && !label.isEmpty {
                Text(label).font(.caption2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle({ if case .filled = fill { return Color.white } else { return accent } }())
            }
        }
        .frame(height: compact ? 8 : 24)
    }

    private func disk(_ title: String, items: [(String, Fill)]) -> some View {
        VStack(spacing: compact ? 3 : 8) {
            VStack(spacing: compact ? 3 : 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in block(it.0, it.1) }
            }
            .padding(compact ? 5 : 10)
            .frame(width: compact ? 32 : 104)
            .overlay(RoundedRectangle(cornerRadius: compact ? 5 : 10, style: .continuous).strokeBorder(.separator, lineWidth: 1))
            if !compact { Text(title).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

infix operator |>: AdditionPrecedence
func |> <A, B>(a: A, f: (A) -> B) -> B { f(a) }

struct ModeOption: View {
    let mode: MockMode
    let title: String
    let result: String
    let current: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            BlockDiagram(mode: mode, compact: true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title).font(.callout.weight(.semibold))
                    if current { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(accent) }
                }
                Text(result).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(current ? AnyShapeStyle(accent) : AnyShapeStyle(.separator), lineWidth: current ? 1.5 : 0.5))
    }
}

// MARK: - Volumes tab

struct VolumesTab: View {
    @EnvironmentObject var state: MockState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Heading(title: "One volume", detail: "G-RAID uses the whole array. ExFAT, so it also works on Windows.")
            Group_(padding: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Label("G-RAID", systemImage: "externaldrive").font(.headline)
                        StatusDot(text: "Mounted").padding(.leading, 6)
                        Spacer()
                        Button("Show in Finder") { }
                        Button("Unmount") { }
                    }
                    PartitionMap(showSystem: state.showSystem).frame(height: 28)
                    HStack(spacing: 18) {
                        key(accent, "Used", gb(Sample.usedGB))
                        key(accent.opacity(0.22), "Free", "7.28 TB")
                        if state.showSystem { key(Color.secondary.opacity(0.5), "EFI", "209.7 MB") }
                        Spacer()
                        Text("ExFAT · /Volumes/G-RAID").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
            Group_(padding: 14) {
                DisclosureGroup(isExpanded: $state.showSystem) {
                    HStack {
                        Image(systemName: "gearshape").foregroundStyle(.secondary)
                        Text("EFI")
                        Text("209.7 MB · MS-DOS (FAT32) · Not mounted").foregroundStyle(.secondary)
                        Spacer()
                        Button("Mount…") { }.buttonStyle(.link)
                    }
                    .font(.callout)
                    .padding(.top, 8)
                } label: {
                    HStack {
                        Text("System partitions").font(.callout)
                        Text("1").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Disk Utility") { }.buttonStyle(.link).font(.callout)
                    }
                }
            }
        }
    }

    private func key(_ c: Color, _ name: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10)
            Text(name).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

/// The disk as one bar, Disk Utility style. EFI only appears once system partitions are shown.
struct PartitionMap: View {
    let showSystem: Bool
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 2) {
                if showSystem {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.secondary.opacity(0.5)).frame(width: 8)
                }
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(accent.opacity(0.22))
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(accent)
                        .frame(width: max(12, (g.size.width - (showSystem ? 10 : 0)) * Sample.usedGB / Sample.totalGB))
                }
            }
        }
    }
}

// MARK: - Activity tab

struct ActivityTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Heading(title: "Last speed test", detail: "Today at 8:31 PM · 4 GB written and read back on G-RAID")
            Group_(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    SpeedChart(rows: [("Write", 224), ("Read", 310)], scaleMax: 400)
                    HStack {
                        Text("Typical for two 7200 rpm disks in RAID 0 over Thunderbolt 2.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Run Again") { }
                    }
                }
            }
            Group_(padding: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Today").font(.headline)
                        Spacer()
                        Button("Event History") { }.buttonStyle(.link)
                    }
                    .padding(.bottom, 10)
                    ForEach(Array(Sample.events.enumerated()), id: \.offset) { i, e in
                        EventRow(event: e, last: i == Sample.events.count - 1)
                    }
                }
            }
        }
    }
}

/// Measured bars on a labelled scale: the numbers, not a dial.
struct SpeedChart: View {
    let rows: [(String, Double)]
    let scaleMax: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows, id: \.0) { r in
                HStack(spacing: 12) {
                    Text(r.0).font(.callout).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            ticks(g.size.width)
                            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(accent)
                                .frame(width: g.size.width * r.1 / scaleMax, height: 18)
                        }
                    }
                    .frame(height: 18)
                    Text("\(Int(r.1)) MB/s").font(.callout.weight(.semibold)).monospacedDigit().frame(width: 78, alignment: .trailing)
                }
            }
            HStack(spacing: 12) {
                Color.clear.frame(width: 44, height: 1)
                GeometryReader { g in
                    ForEach([0, 100, 200, 300, 400], id: \.self) { v in
                        Text("\(v)").font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                            .position(x: g.size.width * Double(v) / scaleMax, y: 6)
                    }
                }
                .frame(height: 12)
                Color.clear.frame(width: 78, height: 1)
            }
        }
    }

    private func ticks(_ width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            ForEach([0, 100, 200, 300, 400], id: \.self) { v in
                Rectangle().fill(.quaternary).frame(width: 1, height: 22).offset(x: width * Double(v) / scaleMax)
            }
        }
    }
}

struct EventRow: View {
    let event: Sample.Event
    let last: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 3) {
                Image(systemName: event.symbol).font(.system(size: 14, weight: .regular)).foregroundStyle(event.tint)
                    .frame(width: 22, height: 18)
                if !last { Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 1).frame(maxHeight: .infinity) }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.callout)
                if !event.detail.isEmpty { Text(event.detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(event.time).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .frame(height: 36, alignment: .top)
    }
}
