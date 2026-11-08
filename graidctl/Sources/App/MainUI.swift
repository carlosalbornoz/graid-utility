// The main window: a toolbar with the section control, a glass overview panel on the left, and
// three sections on the right (Array, Volumes, Activity).
//
// Direction: glass for controls, solid for content. Liquid Glass (macOS 26+) is the navigation
// layer: the toolbar, the section control and the overview panel. Content sits on the system
// background in quiet hairline groups. No gradients or glows. One accent (G-Technology blue)
// for data and selection; system green, orange and red for status only. Older macOS versions get
// the same layout with standard materials.

import AppKit
import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case array = "Array", volumes = "Volumes", activity = "Activity"
    var id: Self { self }
}

/// G-Technology blue: data and selection only.
let brandBlue = Color(red: 0.0, green: 0.56, blue: 0.80)

struct SpeedResult: Codable {
    let date: Date
    let writeMBps: Double
    let readMBps: Double
    let sizeGB: Int
    let volume: String
}

func openDiskUtility() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
}

func diskStatusColor(_ s: UInt8) -> Color {
    switch s {
    case 0, 9: return .green
    case 1, 4, 7, 0xA, 0xB, 0xC, 0x11, 0x1B: return .orange
    default: return .red
    }
}

// MARK: - Surfaces

extension View {
    /// The navigation layer: Liquid Glass on macOS 26, a standard material before that.
    @ViewBuilder func glassPanel(cornerRadius r: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: r, style: .continuous))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: r, style: .continuous))
        }
    }

    /// A content group: solid system surface with a hairline edge.
    func contentGroup(padding: CGFloat = 16, highlighted: Bool = false) -> some View {
        modifier(ContentGroup(padding: padding, highlighted: highlighted))
    }
}

struct ContentGroup: ViewModifier {
    let padding: CGFloat
    let highlighted: Bool
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { fill(shape) }
            .overlay(shape.strokeBorder(highlighted ? brandBlue : Color(nsColor: .separatorColor), lineWidth: highlighted ? 1.5 : 0.5))
    }
    @ViewBuilder private func fill(_ shape: RoundedRectangle) -> some View {
        if #available(macOS 14.0, *) { shape.fill(.background.secondary) } else { shape.fill(Color(nsColor: .controlBackgroundColor)) }
    }
}

/// The technical name of a RAID mode (RAID 0, RAID 1, JBOD), shown beside its plain name.
struct ModeChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold)).monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
            .fixedSize()
            .accessibilityLabel(text)
    }
}

/// A mode's plain name with its chip, or the controller's own name for modes this app can't set.
struct ModeName: View {
    let mode: TargetMode?
    let raw: UInt8
    var font: Font = .body
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // The name keeps its full width; the chip beside it is fixed-size too.
            Text(mode?.name ?? modeText(raw)).font(font).lineLimit(1).fixedSize()
            if let mode { ModeChip(text: mode.chip) }
        }
    }
}

struct SectionHeading: View {
    let title: String
    let detail: String
    var chip: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.title3.weight(.semibold))
                if let chip { ModeChip(text: chip) }
            }
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StatusDot: View {
    let text: String
    var color: Color = .green
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
        .accessibilityElement(children: .combine)
    }
}

struct Meter: View {
    let fraction: Double
    var color: Color = brandBlue
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: max(height, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

// MARK: - Window

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.phase {
                case .scanning:
                    ProgressView("Looking for a G-RAID…").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .noDevice:
                    if model.usbGRAIDs.isEmpty { NoDeviceView() } else { USBOnlyView() }
                case .needsAccess:
                    if model.waitingForUnlockService { UnlockingView() } else { AccessView() }
                case .ready:
                    if let unit = model.selected { UnitView(unit: unit) }
                case .startingUp:
                    StartingUpView()
                case .ejected:
                    EjectedView()
                }
            }
            .frame(height: model.phase == .ready ? 500 : 440)
            if let m = model.message {
                Divider()
                HStack(alignment: .top) {
                    Image(systemName: "info.circle")
                    Text(m).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if model.suggestDiskUtility { Button("Open Disk Utility") { openDiskUtility() } }
                    Button("Dismiss") { model.message = nil; model.suggestDiskUtility = false }.buttonStyle(.link)
                }
                .padding(12)
                .background(.thinMaterial)
            }
        }
        .frame(width: 940)   // fixed: the window always fits the content
        // No window-wide tint: standard buttons keep macOS's own high-contrast styling. Blue is
        // applied only where the app draws data or selection.
        .navigationTitle(model.phase == .ready ? (model.selected?.model.name ?? "G-RAID") : "G-RAID Utility")
        .navigationSubtitle(subtitle)
        .toolbar { MainToolbar(model: model) }
        .onAppear {
            model.windowVisible = true
            NSApp.setActivationPolicy(.regular)
        }
        .onDisappear {
            model.windowVisible = false
            // With background monitoring on, live in the menu bar without a Dock icon.
            if Pref.monitor { NSApp.setActivationPolicy(.accessory) }
        }
        .sheet(isPresented: Binding(get: { model.speedTest != nil }, set: { if !$0 { model.speedTest = nil } })) {
            if let test = model.speedTest { SpeedTestSheet(test: test) { model.speedTest = nil } }
        }
    }

    /// The connection while a G-RAID is shown; otherwise what the app is doing.
    private var subtitle: String {
        switch model.phase {
        case .ready:
            guard let u = model.selected else { return "" }
            return (u.model.name.hasSuffix("3") ? "Thunderbolt 3" : "Thunderbolt") + " · " + u.bsdNames.joined(separator: ", ")
        case .scanning: return "Looking for a G-RAID…"
        case .needsAccess: return model.waitingForUnlockService ? "G-RAID found · Unlocking…" : "G-RAID found · Waiting for access"
        case .noDevice: return model.usbGRAIDs.isEmpty ? "No G-RAID detected · Waiting for connection…" : "G-RAID connected over USB"
        case .startingUp: return model.startingUpTooLong ? "G-RAID found · Disk hasn't appeared" : "G-RAID found · Starting up…"
        case .ejected: return "Ejected · Safe to unplug"
        }
    }
}

struct MainToolbar: ToolbarContent {
    @ObservedObject var model: AppModel

    var body: some ToolbarContent {
        principal
        ToolbarItemGroup(placement: .primaryAction) {
            if model.units.count > 1 {
                Picker("Device", selection: $model.selectedID) {
                    ForEach(model.units) { u in Text("\(u.productName) (\(u.bsdNames.first ?? ""))").tag(Optional(u.id)) }
                }
                .frame(width: 200)
            }
            if model.phase == .ready && !model.lockedDisks.isEmpty {
                Button("Allow Access…") { model.requestAccess() }.disabled(model.isWorking)
            }
            if model.phase == .ready, let u = model.selected, u.hasMountedPartitions {
                Button { model.eject(u) } label: { Label("Eject", systemImage: "eject") }
                    .help("Eject (⌘E)").disabled(model.isWorking)
            }
            // While busy, the spinner takes Refresh's place so the glass pill keeps its size.
            Button { model.refresh() } label: {
                if model.isWorking {
                    ProgressView().controlSize(.small).frame(width: 16, height: 16)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .help(model.isWorking ? "Working…" : "Refresh (⌘R)").disabled(model.isWorking)
        }
        trailingMargin
    }

    /// Lines the toolbar's right edge up with the content's 20 pt margin (macOS 26 toolbars sit closer).
    @ToolbarContentBuilder private var trailingMargin: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
    }

    /// The section control sits in the toolbar's glass capsule (macOS 26). It sizes to its tabs, so
    /// the capsule hugs them instead of adding padding on the sides.
    @ToolbarContentBuilder private var principal: some ToolbarContent {
        ToolbarItem(placement: .principal) { sectionPicker }
    }

    @ViewBuilder private var sectionPicker: some View {
        if model.phase == .ready {
            Picker("Section", selection: $model.tab) {
                ForEach(MainTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }
}

struct UnitView: View {
    @EnvironmentObject var model: AppModel
    let unit: Unit

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            OverviewPanel(unit: unit).frame(width: 272)
            ScrollView {
                Group {
                    switch model.tab {
                    case .array: ArrayTab(unit: unit)
                    case .volumes: VolumesTab(unit: unit)
                    case .activity: ActivityTab(unit: unit)
                    }
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 20)
    }
}

// MARK: - Overview (always visible)

struct OverviewPanel: View {
    @EnvironmentObject var model: AppModel
    let unit: Unit

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            asset(unit.model.image).resizable().interpolation(.high).scaledToFit()
                .frame(maxWidth: .infinity).frame(height: 112)
                .padding(.top, 4)
                .accessibilityLabel(unit.model.name)

            HStack(spacing: 10) {
                Image(systemName: healthSymbol).font(.system(size: 26)).foregroundStyle(unit.health.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(unit.health == .good ? "Healthy" : unit.statusText).font(.title3.weight(.semibold))
                    Text(healthLine).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            if !unit.model.verified {
                Label(unit.model == .unknown ? "Unrecognised model: status only" : "Not yet tested with this model", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                spec("Capacity", unit.capacityText)
                GridRow {
                    Text("Mode").foregroundStyle(.secondary)
                    ModeName(mode: unit.currentTarget, raw: unit.caps.currentMode)
                }
                spec("Disks", disksText)
                spec("Firmware", unit.caps.firmware)
                if !unit.caps.raidSetName.isEmpty { spec("Name", unit.caps.raidSetName).help("Unique ID \(unit.caps.uniqueID)") }
            }
            .font(.callout)

            Divider()

            volumes

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                speedTestButton
                Button { HealthReport.export(unit: unit, events: model.recentEvents) } label: {
                    Label("Report", systemImage: "doc.text").frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
        }
        .padding(18)
        .frame(maxHeight: .infinity)
        .glassPanel(cornerRadius: 22)
    }

    @ViewBuilder private var volumes: some View {
        let mounted = unit.volumes
        if !mounted.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(mounted.prefix(2), id: \.url) { v in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Label(v.name, systemImage: "externaldrive").font(.callout.weight(.medium)).lineLimit(1)
                            Spacer()
                            Button { NSWorkspace.shared.activateFileViewerSelecting([v.url]) } label: { Image(systemName: "folder") }
                                .buttonStyle(.borderless).help("Show in Finder")
                        }
                        Meter(fraction: v.total > 0 ? v.used / v.total : 0)
                        Text("\(formatBytes(v.used)) used of \(formatBytes(v.total))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if mounted.count > 2 {
                    Button("\(mounted.count - 2) more in Volumes") { model.tab = .volumes }.buttonStyle(.link).font(.caption)
                }
            }
        } else if let p = unit.unmountedVolumes.first {
            HStack {
                Label(p.name, systemImage: "externaldrive").font(.callout.weight(.medium))
                Text("Not mounted").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if p.mountable { Button("Mount") { model.mount(p) }.disabled(model.isWorking) }
            }
        } else {
            HStack {
                Text("No volume").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Open Disk Utility") { openDiskUtility() }.buttonStyle(.link).font(.callout)
            }
        }
    }

    @ViewBuilder private var speedTestButton: some View {
        let writable = unit.writableVolumes
        if writable.count > 1 {
            Menu {
                ForEach(writable, id: \.url) { v in Button(v.name) { model.startSpeedTest(unit, volume: v) } }
            } label: { Label("Speed Test", systemImage: "speedometer").frame(maxWidth: .infinity) }
        } else {
            Button { model.startSpeedTest(unit) } label: { Label("Speed Test", systemImage: "speedometer").frame(maxWidth: .infinity) }
                .disabled(writable.isEmpty)
                .help(writable.isEmpty ? "Mount a volume that can be written to first" : "Write and read a temporary file to measure speed")
        }
    }

    private var healthSymbol: String {
        switch unit.health {
        case .good: return "checkmark.circle.fill"
        case .attention: return unit.isBusy ? "arrow.triangle.2.circlepath.circle.fill" : "exclamationmark.triangle.fill"
        case .bad: return "xmark.octagon.fill"
        }
    }

    private var healthLine: String {
        switch unit.health {
        case .good: return unit.disks.presentPorts.count > 1 ? "Both disks working normally" : "Working normally"
        case .attention: return unit.isBusy ? "Working on the array" : "Check the disks in Array"
        case .bad: return "The array needs attention"
        }
    }

    private var disksText: String {
        let present = unit.disks.presentPorts
        // Working drives: Online, Spare, and ones still answering while failing, verifying or migrating.
        let ok = present.filter { [0, 7, 9, 0xB, 0xC, 0x1B].contains($0.status) }.count
        return "\(ok) of \(max(2, present.count)) online"
    }

    private func spec(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).monospacedDigit().lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }
}

// MARK: - Array: bays and how data is laid out on them, in one picture

struct ArrayTab: View {
    @EnvironmentObject var model: AppModel
    let unit: Unit
    final class SheetState: ObservableObject {
        @Published var open = false
        @Published var choice: TargetMode?
        @Published var replaceOpen = false
    }
    @StateObject private var sheet = SheetState()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                SectionHeading(title: title, detail: detail, chip: unit.currentTarget?.chip)
                Spacer(minLength: 16)
                Button("Change RAID Mode…") { openSheet(nil) }
                    .controlSize(.large)
                    .disabled(blocker != nil || model.isWorking)
                    .help(blocker ?? "Choose Individual, RAID 0 or RAID 1. Erases both disks.")
            }

            if unit.health != .good || unit.isBusy {
                HStack(spacing: 10) {
                    Image(systemName: unit.isBusy ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill").foregroundStyle(unit.health.tint)
                    Text(unit.statusText).font(.callout.weight(.medium))
                    if unit.replaceStep != nil {
                        Spacer(minLength: 12)
                        Button("Replace a Drive…") { sheet.replaceOpen = true }
                            .help("Step-by-step help for putting in a new drive and watching the copy.")
                            // Its own anchor: two sheets on one view don't both present on older macOS.
                            .sheet(isPresented: $sheet.replaceOpen) {
                                ReplaceDriveSheet(unitID: unit.id) { sheet.replaceOpen = false }.environmentObject(model)
                            }
                    }
                }
            }

            DriveBays(unit: unit)
                .contentGroup(padding: 20)

            if let blocker { Text(blocker).font(.caption).foregroundStyle(.secondary) }
        }
        .sheet(isPresented: $sheet.open) {
            ChangeModeSheet(unit: unit, preview: sheet.choice.map { (1, $0, "") }) { mode, name in
                sheet.open = false
                model.changeMode(unit: unit, mode: mode, name: name)
            } cancel: { sheet.open = false }
        }
    }

    private func openSheet(_ m: TargetMode?) {
        guard m != unit.currentTarget || m == nil else { return }
        sheet.choice = m
        sheet.open = true
    }

    private var title: String { unit.currentTarget?.name ?? modeText(unit.caps.currentMode) }

    private var detail: String { unit.currentTarget?.summary ?? "This mode can't be changed with this utility." }

    private var blocker: String? {
        if !unit.model.canChangeMode { return "Mode changes are turned off for this unrecognised model." }
        if unit.isBusy { return "Available after the current rebuild or verify finishes." }
        if unit.disks.presentPorts.isEmpty { return "Insert disks to set up the array." }
        return nil
    }
}

enum BlockFill { case filled(Color), outline(Color), none }

/// Data blocks for a mode: what one file looks like, and what lands on each disk.
func layoutBlocks(_ mode: TargetMode?, disk: Int) -> [(String, BlockFill)] {
    switch mode {
    case .raid0?: return (0..<4).map { i in ("A\(i * 2 + disk + 1)", .filled(brandBlue)) }
    case .raid1?: return (1...4).map { ("A\($0)", disk == 0 ? .filled(brandBlue) : .outline(brandBlue)) }
    case .individual?: return disk == 0
        ? (1...4).map { ("A\($0)", .filled(brandBlue)) }
        : (1...2).map { ("B\($0)", .filled(Color.secondary)) } + [("", .none), ("", .none)]
    case nil: return Array(repeating: ("", .none), count: 4)
    }
}

struct DataBlock: View {
    let label: String
    let fill: BlockFill
    var compact = false
    var small = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 2 : small ? 3 : 5, style: .continuous)
        ZStack {
            switch fill {
            case .filled(let c): shape.fill(c)
            case .outline(let c): shape.strokeBorder(c, lineWidth: compact ? 1 : 1.5)
            case .none: Color.clear
            }
            if !compact && !label.isEmpty {
                Text(label).font(small ? .system(size: 9, weight: .semibold) : .caption2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle({ if case .filled = fill { return Color.white } else { return brandBlue } }())
            }
        }
        .frame(height: compact ? 8 : small ? 15 : 22)
    }
}

/// Both bays as drives, joined by a brace naming the volume they form.
struct DriveBays: View {
    @EnvironmentObject var model: AppModel
    let unit: Unit
    static let spacing: CGFloat = 40

    var body: some View {
        VStack(spacing: 10) {
            if let caption = volumeCaption {
                VolumeBrace(text: caption)
                    .frame(width: CGFloat(slots.count - 1) * (DriveBay.width + Self.spacing))
                    .padding(.horizontal, DriveBay.width / 2)
            }
            HStack(alignment: .top, spacing: Self.spacing) {
                ForEach(slots, id: \.0) { slot in
                    DriveBay(unit: unit, bay: slot.0, port: slot.1,
                             lastSeen: model.lastSeenDrive(unit: unit.id, bay: slot.0))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var volumeCaption: String? {
        guard slots.count > 1 else { return nil }
        switch unit.currentTarget {
        case .raid0?: return "One \(unit.capacityText) volume"
        case .raid1?: return "One \(unit.capacityText) volume, mirrored"
        default: return nil
        }
    }

    /// Always both bays of this 2-bay unit, plus any extra disk the controller reports.
    private var slots: [(Int, Port?)] {
        let present = unit.disks.presentPorts
        var s: [(Int, Port?)] = (0..<2).map { i in (i, present.first { $0.index == i }) }
        s += present.filter { $0.index >= 2 }.map { ($0.index, Optional($0)) }
        return s
    }
}

/// A line over the bays with the caption in the middle and a tick down to each bay.
struct VolumeBrace: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            BraceArm(leading: true)
            Text(text).font(.callout.weight(.medium)).foregroundStyle(.secondary).fixedSize()
            BraceArm(leading: false)
        }
        .frame(height: 22)
        .accessibilityElement(children: .combine)
    }
}

struct BraceArm: View {
    let leading: Bool
    var body: some View {
        BraceArmShape(leading: leading)
            .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
    }
}

struct BraceArmShape: Shape {
    let leading: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        let edge = leading ? r.minX : r.maxX, inner = leading ? r.maxX : r.minX
        p.move(to: CGPoint(x: edge, y: r.maxY))
        p.addLine(to: CGPoint(x: edge, y: r.midY + 4))
        p.addQuadCurve(to: CGPoint(x: edge + (leading ? 4 : -4), y: r.midY), control: CGPoint(x: edge, y: r.midY))
        p.addLine(to: CGPoint(x: inner, y: r.midY))
        return p
    }
}

/// One bay: its name, the drive drawn as a 3.5-inch disk with a label, and a note when the drive
/// needs attention. Everything on the label comes from what the drive itself reports.
struct DriveBay: View {
    let unit: Unit
    let bay: Int
    let port: Port?
    let lastSeen: KnownDrive?
    final class Popup: ObservableObject { @Published var open = false }
    @StateObject private var popup = Popup()
    static let width: CGFloat = 176

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bay \(bay + 1)").font(.headline).frame(maxWidth: .infinity)
            Button { popup.open = true } label: { drawing }
                .buttonStyle(.plain)
                .disabled(identity == nil)
                .help(identity == nil ? "" : "Show drive details")
                .popover(isPresented: $popup.open, arrowEdge: .trailing) { details }
            if let note {
                Label { Text(note.text).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: note.symbol).foregroundStyle(note.color)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(identity == nil ? [] : .isButton)
    }

    // MARK: Facts

    /// The drive to name: the one in the bay, else the one last seen there.
    private var identity: (model: String, serial: String, bytes: Double)? {
        if let p = port, !p.model.isEmpty { return (p.model, p.serial, p.capacityBytes) }
        if let d = lastSeen { return (d.model, d.serial, d.bytes) }
        return nil
    }

    /// No drive is answering in this bay: empty, or a member the controller lost.
    private var isAbsent: Bool { port == nil || port?.status == 3 }
    private var isFailed: Bool { port.map { [5, 6, 8].contains($0.status) } ?? false }

    private var statusText: String { port.map { diskStatusText($0.status) } ?? (lastSeen == nil ? "Empty" : "Missing") }
    private var statusColor: Color { port.map { diskStatusColor($0.status) } ?? (lastSeen == nil ? .secondary : .red) }

    private var sizes: [Double] { unit.disks.presentPorts.filter { $0.status != 3 }.map(\.capacityBytes) }

    private var sizeText: String {
        guard let id = identity else { return "" }
        return driveSizeText(id.bytes, tenths: disksMismatched(sizes))
    }

    private var role: String? {
        if port?.status == 9 { return "Spare" }
        if port?.status == 0xA { return "Not in the array" }
        guard identity != nil else { return nil }
        let n = max(2, unit.disks.presentPorts.filter { $0.status != 9 }.count)
        let was = isAbsent ? "Was " : ""
        switch unit.currentTarget {
        case .raid0?: return "\(was)\(was.isEmpty ? "Disk" : "disk") \(bay + 1) of \(n) · RAID 0"
        case .raid1?: return "\(was)\(was.isEmpty ? "Copy" : "copy") \(bay + 1) of \(n) · RAID 1"
        case .individual?: return isAbsent ? nil : "Its own volume"
        case nil: return nil
        }
    }

    /// The size a replacement needs to rebuild a RAID 1: the volume plus the controller's reserve.
    private var neededSize: Double { unit.volumeBytes > 0 ? unit.replacementMinBytes : (sizes.max() ?? 0) }

    private var note: (text: String, symbol: String, color: Color)? {
        let mode = unit.currentTarget
        if isAbsent || isFailed {
            let verb = isAbsent ? "Insert" : "Replace it with"
            switch mode {
            case .raid1? where unit.replaceStep?.bay == bay:
                // The controller starts copying onto whatever drive goes in, without asking.
                return isAbsent
                    ? ("Any drive put here is erased for the copy. Use \(driveSizeText(neededSize)) or more.", "exclamationmark.triangle.fill", .orange)
                    : ("Remove it. The drive you insert next is erased and used for the copy.", "exclamationmark.triangle.fill", .orange)
            case .raid1?:
                return ("\(verb) a drive of \(driveSizeText(neededSize)) or larger to restore the copy.", "arrow.triangle.2.circlepath", .orange)
            case .raid0?:
                return ("The volume can't be read without this drive.", "exclamationmark.triangle.fill", .red)
            default:
                return isAbsent
                    ? (lastSeen == nil ? nil : ("Insert a drive to use this bay.", "info.circle", .secondary))
                    : ("Replace this drive. Its files can't be read.", "exclamationmark.triangle.fill", .red)
            }
        }
        if port?.status == 7 { return ("Expected to fail soon. Back up, then replace it.", "exclamationmark.triangle.fill", .orange) }
        if port?.status == 1 { return ("Receiving the copy. Leave it connected.", "arrow.triangle.2.circlepath", .orange) }
        if let p = port, mode == .raid0 || mode == .raid1, disksMismatched(sizes), let lo = sizes.min() {
            if p.capacityBytes <= lo { return ("The smaller drive sets the volume size.", "info.circle", .secondary) }
            return ("About \(formatBytes(p.capacityBytes - lo)) of this drive goes unused.", "info.circle", .secondary)
        }
        return nil
    }

    private var accessibilityText: String {
        var parts = ["Bay \(bay + 1)"]
        if let id = identity { parts += [id.model, sizeText] }
        parts.append(statusText)
        if let role { parts.append(role) }
        if let note { parts.append(note.text) }
        return parts.joined(separator: ", ")
    }

    // MARK: Drawing

    private var drawing: some View {
        let ghost = isAbsent
        let body = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let edge = Color.secondary.opacity(ghost ? 0.45 : 0.55)
        return ZStack {
            if !ghost { body.fill(Color(nsColor: .textBackgroundColor)) }
            body.strokeBorder(edge, style: StrokeStyle(lineWidth: 1.25, dash: ghost ? [5, 4] : []))
            if !ghost { screws(edge) }
            VStack(spacing: 0) {
                label.padding(.horizontal, 14).padding(.top, 20)
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(edge, style: StrokeStyle(lineWidth: 1.25, dash: ghost ? [3, 3] : []))
                    .frame(width: 84, height: 10)
                    .padding(.bottom, 10)
            }
        }
        .frame(width: Self.width, height: 262)
        .contentShape(body)
    }

    private func screws(_ color: Color) -> some View {
        GeometryReader { g in
            ForEach(0..<4, id: \.self) { i in
                Circle().strokeBorder(color, lineWidth: 1)
                    .frame(width: 7, height: 7)
                    .position(x: i % 2 == 0 ? 11 : g.size.width - 11, y: i < 2 ? 11 : g.size.height - 11)
            }
        }
    }

    private var label: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        let ghost = isAbsent
        let split = identity.map { splitDriveModel($0.model) }
        let primary: HierarchicalShapeStyle = ghost ? .tertiary : .primary
        return VStack(alignment: .leading, spacing: 3) {
            if let split {
                Text(split.vendor ?? " ").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(split.model).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.bottom, 22)
                Text(sizeText).font(.system(size: 30, weight: .semibold)).monospacedDigit().foregroundStyle(primary)
                StatusDot(text: statusText, color: statusColor).font(.caption)
                if let role { Text(role).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 8)
                Text(identity?.serial ?? "").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            } else {
                Spacer()
                Text("No drive").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Text("This bay is empty.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .frame(height: 188, alignment: .top)
        .background { if !ghost { shape.fill(Color(nsColor: .controlBackgroundColor)) } }
        .overlay(shape.strokeBorder(isFailed ? Color.red : Color(nsColor: .separatorColor),
                                    style: StrokeStyle(lineWidth: isFailed ? 1.5 : 1, dash: ghost ? [3, 3] : [])))
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Bay \(bay + 1)").font(.headline)
                if isAbsent { Text("Not answering. Last seen in this bay:").font(.caption).foregroundStyle(.secondary) }
            }
            if let id = identity {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow { Text("Model").foregroundStyle(.secondary); Text(id.model).textSelection(.enabled) }
                    GridRow {
                        Text("Serial").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text(id.serial).monospaced().textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(id.serial, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless)
                                .help("Copy serial number")
                        }
                    }
                    GridRow { Text("Size").foregroundStyle(.secondary); Text(exactSize(id.bytes)).monospacedDigit() }
                    GridRow { Text("Status").foregroundStyle(.secondary); StatusDot(text: statusText, color: statusColor) }
                    if let role { GridRow { Text("Role").foregroundStyle(.secondary); Text(role) } }
                }
                .font(.callout)
            }
            if let note { Text(note.text).font(.callout).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(16)
        .frame(width: 330, alignment: .leading)
    }

    private func exactSize(_ bytes: Double) -> String {
        let n = NumberFormatter(); n.numberStyle = .decimal
        let total = n.string(from: NSNumber(value: bytes)) ?? "\(Int64(bytes))"
        if let p = port, p.bytesPerBlock > 0, p.totalBlocks > 0 {
            let blocks = n.string(from: NSNumber(value: p.totalBlocks)) ?? "\(p.totalBlocks)"
            return "\(driveSizeText(bytes, tenths: true)) · \(total) bytes\n\(blocks) sectors of \(p.bytesPerBlock) bytes"
        }
        return "\(driveSizeText(bytes, tenths: true)) · \(total) bytes"
    }
}

/// How a mode places one file's blocks on the two disks. When `animate` turns on, the blocks
/// land on the disks in write order, so the difference between the modes is visible.
struct ModeDiagram: View {
    let mode: TargetMode?
    var animate = false
    final class Player: ObservableObject {
        @Published var shown = Int.max
        var run = 0
    }
    @StateObject private var player = Player()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { d in
                let blocks = layoutBlocks(mode, disk: d)
                VStack(spacing: 3) {
                    ForEach(blocks.indices, id: \.self) { r in
                        let visible = order(disk: d, row: r) < player.shown
                        DataBlock(label: blocks[r].0, fill: blocks[r].1, small: true)
                            .opacity(visible ? 1 : 0)
                            .offset(y: visible ? 0 : -6)
                    }
                }
                .padding(5)
                .frame(width: 46)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            }
        }
        .onAppear { if animate { play() } }
        .onChange(of: animate) { on in if on { play() } }
        .accessibilityHidden(true)
    }

    /// The step at which a block is written: RAID 0 alternates disks, RAID 1 writes both at
    /// once, Individual fills one disk's files, then the other's.
    private func order(disk d: Int, row r: Int) -> Int {
        switch mode {
        case .raid0?: return r * 2 + d
        case .raid1?: return r
        case .individual?: return d == 0 ? r : 4 + r
        case nil: return 0
        }
    }

    private func play() {
        let player = player
        guard !reduceMotion else { player.shown = Int.max; return }
        player.run += 1
        let current = player.run
        player.shown = 0
        Task { @MainActor in
            for i in 1...8 {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard current == player.run else { return }
                withAnimation(.easeOut(duration: 0.2)) { player.shown = i }
            }
            player.shown = Int.max
        }
    }
}

// MARK: - Volumes

struct VolumesTab: View {
    @EnvironmentObject var model: AppModel
    let unit: Unit

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                SectionHeading(title: title, detail: detail)
                Spacer(minLength: 16)
                Button("Open Disk Utility") { openDiskUtility() }.controlSize(.large)
                    .help("Partition, format or repair disks")
            }
            ForEach(unit.bsdNames, id: \.self) { disk in
                diskGroup(disk)
            }
            systemGroup
        }
    }

    private var volumeParts: [Partition] { unit.partitions.filter { $0.kind == .volume } }
    private var otherParts: [Partition] { unit.partitions.filter { $0.kind != .volume } }

    private var title: String {
        switch volumeParts.count {
        case 0: return "No volumes"
        case 1: return "One volume"
        default: return "\(volumeParts.count) volumes"
        }
    }

    private var detail: String {
        if volumeParts.isEmpty { return "Nothing on the G-RAID that macOS can open. Use Disk Utility to create a volume." }
        if volumeParts.count == 1, let v = volumeParts.first {
            let windows = v.format.localizedCaseInsensitiveContains("exfat") || v.format.localizedCaseInsensitiveContains("fat") ? ", so it also works on Windows" : ""
            return "\(v.name) uses the whole array. \(v.format)\(windows)."
        }
        return "Mount or unmount each one separately. Eject unmounts them all."
    }

    @ViewBuilder private func diskGroup(_ disk: String) -> some View {
        let parts = unit.partitions.filter { $0.physicalDisk == disk }
        let vols = parts.filter { $0.kind == .volume }
        VStack(alignment: .leading, spacing: 14) {
            if unit.bsdNames.count > 1 { Text(disk).font(.caption).foregroundStyle(.secondary) }
            ForEach(vols) { v in
                volumeRow(v)
                if v.id != vols.last?.id { Divider() }
            }
            if !parts.isEmpty {
                PartitionMap(partitions: parts).frame(height: 26)
                legend(parts)
            }
        }
        .contentGroup(padding: 18)
    }

    private func volumeRow(_ v: Partition) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(v.name, systemImage: "externaldrive").font(.headline).lineLimit(1)
            StatusDot(text: v.isMounted ? "Mounted" : "Not mounted", color: v.isMounted ? .green : .secondary).font(.callout)
            Text(v.isMounted ? "\(formatBytes(v.used)) used of \(formatBytes(v.total))" : "\(formatBytes(v.size)) · \(v.format)")
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            if let url = v.mountURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Unmount") { model.unmount(v) }.disabled(model.isWorking)
            } else if v.mountable {
                Button("Mount") { model.mount(v) }.disabled(model.isWorking)
            }
        }
    }

    private func legend(_ parts: [Partition]) -> some View {
        let vols = parts.filter { $0.kind == .volume }
        let used = vols.reduce(0) { $0 + $1.used }
        let total = vols.reduce(0) { $0 + ($1.isMounted ? $1.total : $1.size) }
        let system = parts.filter { $0.kind != .volume }.reduce(0) { $0 + $1.size }
        return HStack(spacing: 18) {
            key(brandBlue, "Used", formatBytes(used))
            key(brandBlue.opacity(0.22), "Free", formatBytes(max(0, total - used)))
            if system > 0 { key(Color.secondary.opacity(0.5), "System", formatBytes(system)) }
            Spacer()
            if vols.count == 1, let v = vols.first, let url = v.mountURL {
                Text("\(v.format) · \(url.path)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .font(.caption)
    }

    private func key(_ c: Color, _ name: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10)
            Text(name).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }

    @ViewBuilder private var systemGroup: some View {
        if !otherParts.isEmpty {
            DisclosureGroup(isExpanded: $model.showSystemPartitions) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(otherParts) { p in
                        HStack {
                            Image(systemName: p.kind == .system ? "gearshape" : "questionmark.square.dashed").foregroundStyle(.secondary)
                            Text(p.name)
                            Text(otherDetail(p)).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            if p.isMounted {
                                Button("Unmount") { model.unmount(p) }.buttonStyle(.link).disabled(model.isWorking)
                            } else if p.mountable {
                                Button("Mount…") { model.mount(p) }.buttonStyle(.link).disabled(model.isWorking)
                                    .help("Asks for an administrator password if macOS requires one")
                            }
                        }
                        .font(.callout)
                        .help(p.bsd)
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack {
                    Text("System partitions").font(.callout)
                    Text("\(otherParts.count)").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .contentGroup(padding: 14)
        }
    }

    private func otherDetail(_ p: Partition) -> String {
        var parts = [formatBytes(p.size), p.format]
        if p.kind == .unreadable { parts.append("macOS can't read it") }
        else { parts.append(p.isMounted ? "Mounted" : (p.mountable ? "Not mounted" : "Can't be mounted")) }
        return parts.joined(separator: " · ")
    }
}

/// One physical disk as a bar, Disk Utility style. Volumes in the accent (used solid, free light);
/// system partitions in mid grey; partitions macOS can't read in light grey.
struct PartitionMap: View {
    let partitions: [Partition]

    private struct Segment: Identifiable { let id: String; let size: Double; let used: Double?; let color: Color }

    private var segments: [Segment] {
        var out: [Segment] = []
        var containers: [String: Int] = [:]
        for p in partitions {
            switch p.kind {
            case .system: out.append(Segment(id: p.bsd, size: p.size, used: nil, color: Color.secondary.opacity(0.5)))
            case .unreadable: out.append(Segment(id: p.bsd, size: p.size, used: nil, color: Color.secondary.opacity(0.25)))
            case .volume where p.isAPFS:
                // APFS volumes share their container: draw the container once, with their combined use.
                if let i = containers[p.parentDisk] {
                    let s = out[i]
                    out[i] = Segment(id: s.id, size: s.size, used: (s.used ?? 0) + p.used, color: s.color)
                } else {
                    containers[p.parentDisk] = out.count
                    out.append(Segment(id: p.parentDisk, size: p.size, used: p.used, color: brandBlue))
                }
            case .volume:
                out.append(Segment(id: p.bsd, size: p.size, used: p.isMounted ? p.used : 0, color: brandBlue))
            }
        }
        return out
    }

    var body: some View {
        GeometryReader { g in
            let segs = segments
            let total = max(1, segs.reduce(0) { $0 + $1.size })
            let minW: CGFloat = 8
            let gaps = CGFloat(max(0, segs.count - 1)) * 2
            let flexible = max(0, g.size.width - gaps - CGFloat(segs.count) * minW)
            HStack(spacing: 2) {
                ForEach(segs) { s in
                    let w = minW + flexible * s.size / total
                    if let used = s.used {
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(s.color.opacity(0.22))
                            if used > 0 {
                                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(s.color)
                                    .frame(width: max(10, w * min(1, used / max(1, s.size))))
                            }
                        }
                        .frame(width: w)
                    } else {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(s.color).frame(width: w)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Activity

struct ActivityTab: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let unit: Unit

    private var events: [GRAIDEvent] { model.recentEvents.filter { $0.unitID == unit.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                SectionHeading(title: title, detail: detail)
                Spacer(minLength: 16)
                Button("Event History") { openWindow(id: "history"); NSApp.activate(ignoringOtherApps: true) }
                    .controlSize(.large)
                    .help("Every recorded event, with CSV export (⌘Y)")
            }

            let recent = Array(events.suffix(5).reversed())
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { i, e in
                        EventRow(event: e, last: i == recent.count - 1)
                    }
                }
                .contentGroup(padding: 16)
            }

            speedTest
        }
    }

    private var title: String {
        let today = events.filter { Calendar.current.isDateInToday($0.date) }.count
        if events.isEmpty { return "No events yet" }
        if today == 0 { return "Nothing new today" }
        return today == 1 ? "1 event today" : "\(today) events today"
    }

    /// What's recorded, not the latest event: a past "Disconnected" here would read like the
    /// current state while the G-RAID is connected.
    private var detail: String {
        events.isEmpty
            ? "Connects, disconnects, disk problems and mode changes are recorded here."
            : "Connects, disconnects, disk problems and mode changes, newest first."
    }

    /// The last measured speed on this unit, or a way to measure it.
    @ViewBuilder private var speedTest: some View {
        let last = model.lastSpeedTest(unit)
        let canRun = !unit.writableVolumes.isEmpty && !model.isWorking
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Speed").font(.headline)
                    Text(last.map { "\($0.date.formatted(date: .abbreviated, time: .shortened)) · \($0.sizeGB) GB on \($0.volume)" }
                         ?? (unit.writableVolumes.isEmpty ? "Mount a volume to measure speed." : "Not measured yet. Writes and reads a temporary file, then deletes it."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(last == nil ? "Run Speed Test" : "Run Again") { model.startSpeedTest(unit) }.disabled(!canRun)
            }
            if let last {
                SpeedChart(rows: [("Write", last.writeMBps), ("Read", last.readMBps)])
            }
        }
        .contentGroup(padding: 16)
    }
}

/// Measured bars on one labelled scale: continuous hairline gridlines behind both rows, the
/// scale directly under the plot. The scale grows in 100 MB/s steps to fit the faster result.
struct SpeedChart: View {
    let rows: [(String, Double)]
    private let labelWidth: CGFloat = 44
    private let valueWidth: CGFloat = 76
    private let barHeight: CGFloat = 10
    private let rowHeight: CGFloat = 22
    private let rowSpacing: CGFloat = 6
    private var scaleMax: Double { max(400, ((rows.map(\.1).max() ?? 0) / 100).rounded(.up) * 100) }
    private var ticks: [Double] { stride(from: 0, through: scaleMax, by: scaleMax / 4).map { $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: rowSpacing) {
                    ForEach(rows, id: \.0) { r in
                        Text(r.0).font(.callout).foregroundStyle(.secondary).frame(height: rowHeight)
                    }
                }
                .frame(width: labelWidth, alignment: .leading)
                plot
                VStack(alignment: .trailing, spacing: rowSpacing) {
                    ForEach(rows, id: \.0) { r in
                        Text("\(Int(r.1.rounded())) MB/s").font(.callout.weight(.semibold)).monospacedDigit()
                            .frame(height: rowHeight)
                    }
                }
                .frame(width: valueWidth, alignment: .trailing)
            }
            HStack(spacing: 12) {
                Color.clear.frame(width: labelWidth, height: 1)
                GeometryReader { g in
                    ForEach(ticks, id: \.self) { t in
                        Text("\(Int(t))").font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                            .fixedSize()
                            .position(x: g.size.width * t / scaleMax, y: 6)
                    }
                }
                .frame(height: 12)
                Text("MB/s").font(.caption2).foregroundStyle(.tertiary).frame(width: valueWidth, alignment: .trailing)
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rows.map { "\($0.0): \(Int($0.1.rounded())) megabytes per second" }.joined(separator: ", "))
    }

    private var plot: some View {
        let height = CGFloat(rows.count) * rowHeight + CGFloat(max(0, rows.count - 1)) * rowSpacing
        return GeometryReader { g in
            ZStack(alignment: .topLeading) {
                ForEach(ticks, id: \.self) { t in
                    Rectangle().fill(Color(nsColor: .separatorColor))
                        .frame(width: 1, height: height)
                        .offset(x: min(g.size.width - 1, g.size.width * t / scaleMax))
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(brandBlue)
                        .frame(width: max(barHeight, g.size.width * min(1, r.1 / scaleMax)), height: barHeight)
                        .offset(y: CGFloat(i) * (rowHeight + rowSpacing) + (rowHeight - barHeight) / 2)
                }
            }
        }
        .frame(height: height)
    }
}

struct EventRow: View {
    let event: GRAIDEvent
    let last: Bool

    /// Height of the title line; the icon is centred on it.
    private static let line: CGFloat = 18
    /// Space between rows, and between a connector and the icons it joins.
    private static let gap: CGFloat = 14
    private static let inset: CGFloat = 4

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(tint)
                    .frame(width: 22, height: Self.line)
                if !last {
                    Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 1).frame(maxHeight: .infinity)
                        .padding(.vertical, Self.inset)
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(event.title).font(.callout).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(time).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .frame(minHeight: Self.line)
                if !event.detail.isEmpty { Text(event.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.bottom, last ? 0 : Self.gap)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var time: String {
        Calendar.current.isDateInToday(event.date)
            ? event.date.formatted(date: .omitted, time: .shortened)
            : event.date.formatted(.dateTime.month(.abbreviated).day())
    }

    private var symbol: String {
        switch event.title {
        case "Connected": return "checkmark.circle"
        case "Disconnected": return "xmark.circle"
        case "Ejected": return "eject.circle"
        default:
            switch event.severity {
            case .critical: return "exclamationmark.octagon"
            case .warning: return "exclamationmark.triangle"
            case .info: return "info.circle"
            }
        }
    }

    private var tint: Color {
        switch event.title {
        case "Connected": return .green
        case "Ejected": return .secondary
        default: return event.severity == .critical ? .red : event.severity == .warning ? .orange : .secondary
        }
    }
}
