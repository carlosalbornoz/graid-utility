import AppKit
import SwiftUI

// MARK: - Enclosure picture

/// The enclosure picture from G-Technology's public icon pack (tools/fetch-artwork.sh). It isn't
/// in the repository, so without it the app shows the system drive symbol.
func asset(_ name: String) -> Image {
    if let url = Bundle.main.url(forResource: name, withExtension: "png"), let img = NSImage(contentsOf: url) {
        return Image(nsImage: img)
    }
    return Image(systemName: "externaldrive.fill")
}

/// The enclosure with a small lock in the corner, for the Allow Access screen.
struct LockedDrive: View {
    var body: some View {
        asset("Img_Device_GRAID").resizable().scaledToFit().foregroundStyle(.secondary)
            .frame(width: 120, height: 84)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "lock.circle.fill").font(.system(size: 34))
                    .symbolRenderingMode(.palette).foregroundStyle(.white, brandBlue)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-2))
                    .offset(x: 6, y: 6)
            }
            .accessibilityHidden(true)
    }
}

extension Unit.Health {
    var tint: Color {
        switch self {
        case .good: return .green
        case .attention: return .orange
        case .bad: return .red
        }
    }
}

// MARK: - Empty states

struct NoDeviceView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            asset("Img_Device_GRAID").resizable().scaledToFit().foregroundStyle(.secondary).frame(height: 96).opacity(0.35)
            Text("No G-RAID connected").font(.title3.weight(.semibold))
            Text("Connect the drive and switch it on. It appears here automatically.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown for a few seconds after connecting while the unlock service does its job.
struct UnlockingView: View {
    var body: some View {
        VStack(spacing: 14) {
            asset("Img_Device_GRAID").resizable().scaledToFit().frame(height: 120)
            ProgressView().controlSize(.small)
            Text("Unlocking the G-RAID…").font(.title3.weight(.semibold))
            Text("The automatic unlock service is getting the G-RAID ready.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The old Configurator refused USB connections ("USB not support"): the RAID controller is
/// managed over Thunderbolt. The drive itself still works normally over USB.
struct USBOnlyView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            asset("Img_Device_GRAID").resizable().scaledToFit().frame(height: 120)
            Text("G-RAID connected over USB").font(.title3.weight(.semibold))
            Text("Your files are available as usual, but the RAID controller can only be checked and configured over Thunderbolt. Connect the G-RAID with a Thunderbolt cable to see its status here.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            Text(model.usbGRAIDs.map { "\($0.bsdName) · \(formatBytes(Double($0.size)))" }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AccessView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            LockedDrive()
            Text("Allow access to the G-RAID").font(.title3.weight(.semibold))
            Text("The utility talks to the G-RAID controller by reading special sectors from the disk, which needs an administrator password. Only G-RAID disks are opened up, read-only and for your account, until the drive is disconnected.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            Button("Allow Access…") { model.requestAccess() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isWorking)
            Text("Found: \(model.lockedDisks.joined(separator: ", "))").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension TargetMode {
    var summary: String {
        switch self {
        case .individual: return "Each disk is its own volume. A failed disk loses only its own data."
        case .raid0: return "Both disks work as one fast volume. If either disk fails, all data is lost."
        case .raid1: return "Both disks hold the same data. If one disk fails, nothing is lost."
        }
    }
    var symbol: String {
        switch self {
        case .individual: return "square.split.2x1"
        case .raid0: return "speedometer"
        case .raid1: return "lock.shield"
        }
    }
}

// MARK: - Change RAID mode (two steps: choose, then confirm the erase)

struct ChangeModeSheet: View {
    let unit: Unit
    var preview: (step: Int, choice: TargetMode?, backedUp: Bool)? = nil   // used by tests/render_previews.sh
    let commit: (TargetMode, String) -> Void
    let cancel: () -> Void

    final class Form: ObservableObject {
        @Published var step = 1
        @Published var choice: TargetMode?
        @Published var name = "G-RAID"
        @Published var backedUp = false
        @Published var showDisks = false
    }
    @StateObject private var form = Form()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if form.step == 1 { chooseStep } else { confirmStep }
        }
        .padding(22)
        .frame(width: 540)
        .onAppear {
            if !unit.caps.raidSetName.isEmpty { form.name = unit.caps.raidSetName }
            if let p = preview { form.step = p.step; form.choice = p.choice; form.backedUp = p.backedUp }
        }
    }

    // Step 1
    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Change RAID Mode").font(.title2.weight(.semibold))
                Text("Pick how the two disks should work together. You'll review what gets erased before anything changes.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            sectionLabel("Current mode")
            currentModePanel

            sectionLabel("Switch to")
            VStack(spacing: 8) {
                ForEach(alternatives) { mode in modeRow(mode) }
            }

            if form.choice != nil && form.choice != .individual {
                HStack {
                    Text("Array name").foregroundStyle(.secondary)
                    TextField("G-RAID", text: $form.name).frame(width: 160)
                    Text("Stored on the G-RAID, up to 15 characters.").font(.caption).foregroundStyle(.tertiary)
                }
            }
            if let p = problem { Label(p, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Continue") { form.backedUp = false; form.step = 2 }
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.choice == nil || problem != nil)
            }
        }
    }

    /// Modes the user can switch to (everything except the current one).
    private var alternatives: [TargetMode] { TargetMode.allCases.filter { $0 != unit.currentTarget } }

    private func sectionLabel(_ s: String) -> some View {
        Text(s.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, -8)
    }

    /// Informational, not a choice: how the array is set up right now.
    private var currentModePanel: some View {
        // Same layout as the option rows: mode icon on the left, indicator on the right,
        // both vertically centred on the card.
        HStack(alignment: .center, spacing: 12) {
            ModeDiagram(mode: unit.currentTarget)
            VStack(alignment: .leading, spacing: 3) {
                if let cur = unit.currentTarget {
                    ModeName(mode: cur, raw: cur.rawValue, font: .body.weight(.semibold))
                    Text(cur.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(currentResultText).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(modeText(unit.caps.currentMode)).font(.body.weight(.semibold))
                    Text(unit.statusText).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.green, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current mode: \(unit.currentTarget?.label ?? modeText(unit.caps.currentMode))")
    }

    private var currentResultText: String {
        let used = unit.usedBytes > 0 ? " · \(formatBytes(unit.usedBytes)) used" : ""
        // The current size is known from the controller, so no estimate here.
        return "\(unit.capacityText) now" + used
    }

    private func modeRow(_ mode: TargetMode) -> some View {
        let selected = form.choice == mode
        return Button { form.choice = mode } label: {
            HStack(alignment: .center, spacing: 12) {
                ModeDiagram(mode: mode, animate: selected)
                VStack(alignment: .leading, spacing: 3) {
                    ModeName(mode: mode, raw: mode.rawValue, font: .body.weight(.semibold))
                    Text(mode.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(unit.resultText(for: mode)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? brandBlue : Color.secondary.opacity(0.6))
            }
            .padding(12)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? brandBlue : Color(nsColor: .separatorColor), lineWidth: selected ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var problem: String? {
        guard let c = form.choice else { return nil }
        return modeChangeProblem(mode: c, name: form.name, disks: unit.disks)
    }

    // Step 2: what is lost, what you get, what happens next, and a backup checkbox.
    private var confirmStep: some View {
        let mode = form.choice ?? .raid1
        let used = unit.volumes.reduce(0) { $0 + $1.used }
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                asset("Img_Device_GRAID").resizable().scaledToFit().foregroundStyle(.secondary).frame(width: 72)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Switch the G-RAID to \(mode.name)?").font(.title2.weight(.semibold))
                    Text("To switch modes, the G-RAID starts over empty.").foregroundStyle(.secondary)
                }
            }
            lossBar(used: used)
            HStack(spacing: 10) {
                SetupCard(label: "Now", symbol: unit.currentTarget?.symbol ?? "externaldrive",
                          mode: unit.currentTarget?.name ?? modeText(unit.caps.currentMode),
                          detail: unit.currentTarget.map(Self.layout) ?? "",
                          fraction: nowCapacity > 0 ? used / nowCapacity : 0,
                          usage: unit.volumes.isEmpty ? formatBytes(nowCapacity) : "\(formatBytes(used)) used of \(formatBytes(nowCapacity))",
                          usageColor: .primary)
                Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                SetupCard(label: "After", symbol: mode.symbol, mode: mode.name, detail: Self.layout(mode),
                          fraction: 0, usage: "Empty · \(formatBytes(capacity(mode))) free", usageColor: .secondary)
            }
            Text(benefit(mode))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            NumberedSteps(title: "What happens next", steps: [
                "The G-RAID ejects and sets itself up. Takes a few seconds.",
                "It reconnects by itself, empty.",
                mode == .individual ? "Create a volume on each disk in Disk Utility, then copy your files back."
                    : "Create a volume on it in Disk Utility, then copy your files back.",
            ])
            DisclosureGroup(isExpanded: $form.showDisks) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(unit.disks.presentPorts, id: \.index) { p in
                        Text("Disk \(p.index + 1): Model \(p.model) · Serial \(p.serial) · \(formatBytes(p.capacityBytes))")
                            .textSelection(.enabled)
                    }
                }
                .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
            } label: {
                Text(disksSummary).font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            Toggle(isOn: $form.backedUp) { Text("My files are backed up somewhere else") }
                .toggleStyle(.checkbox)
            HStack {
                Button("Back") { form.step = 1 }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(used > 0 ? "Erase \(formatBytes(used)) and Switch" : "Erase and Switch") { commit(mode, form.name) }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(!form.backedUp)
            }
        }
    }

    /// The red bar that says what is lost, with the amount when it can be measured.
    private func lossBar(used: Double) -> some View {
        let names = unit.volumes.map(\.name)
        let unmounted = unit.unmountedVolumes.map(\.name)
        let title: String
        if !names.isEmpty && used > 0 {
            title = "\(formatBytes(used)) of files on \(ListFormatter.localizedString(byJoining: names)) will be deleted"
        } else if !names.isEmpty && unmounted.isEmpty {
            title = "\(ListFormatter.localizedString(byJoining: names)) is empty, but it will be erased too"
        } else {
            title = "Everything on the G-RAID will be deleted"
        }
        var detail = "Both disks are erased, all \(formatBytes(nowCapacity)), and nothing on them can be recovered afterwards."
        if !unmounted.isEmpty {
            detail += " That includes \(ListFormatter.localizedString(byJoining: unmounted)), which isn't mounted, so its size can't be shown."
        } else if names.isEmpty {
            detail += " No volume is mounted, so how much is stored can't be shown."
        }
        detail += " Back up anything you need first."
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 17)).foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.red.opacity(0.45), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    private func capacity(_ mode: TargetMode) -> Double {
        let ports = unit.disks.presentPorts
        guard let first = ports.first else { return 0 }
        return modeCapacity(mode, members: ports.map(\.totalBlocks), bytesPerBlock: UInt64(first.bytesPerBlock)).usable
    }
    private var nowCapacity: Double { unit.currentTarget.map(capacity) ?? unit.volumeBytes }

    private static func layout(_ mode: TargetMode) -> String {
        switch mode {
        case .individual: return "Two separate disks"
        case .raid0: return "RAID 0 · no copy"
        case .raid1: return "RAID 1 · copy on each disk"
        }
    }

    private func benefit(_ mode: TargetMode) -> String {
        let after = formatBytes(capacity(mode)), now = formatBytes(nowCapacity)
        switch mode {
        case .raid1: return "You'll have \(after) instead of \(now), but every file is kept on both disks, so the G-RAID keeps working if one of them fails."
        case .raid0: return "You'll have \(after) in one fast volume instead of \(now), but if either disk fails, everything on the G-RAID is lost."
        case .individual: return "Each disk becomes its own volume. If one disk fails, only the files on that disk are lost."
        }
    }

    private var disksSummary: String {
        let models = unit.disks.presentPorts.map(\.model)
        if let first = models.first, models.allSatisfy({ $0 == first }) { return "Disks: \(models.count) × \(first)" }
        return "Disks: " + models.joined(separator: ", ")
    }
}

/// One side of the before/after in the erase confirmation: the mode and how full it is.
struct SetupCard: View {
    let label: String
    let symbol: String
    let mode: String
    let detail: String
    let fraction: Double
    let usage: String
    let usageColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(brandBlue).frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(mode).font(.body.weight(.semibold))
                    if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary) }
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(brandBlue).frame(width: fraction > 0 ? max(4, g.size.width * min(1, fraction)) : 0)
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
            Text(usage).font(.callout).foregroundStyle(usageColor).monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

/// A short numbered list, for "what happens next".
struct NumberedSteps: View {
    let title: String
    let steps: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.semibold))
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(i + 1)").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 16, height: 16).overlay(Circle().strokeBorder(Color(nsColor: .separatorColor)))
                        .accessibilityHidden(true)
                    Text(step).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
