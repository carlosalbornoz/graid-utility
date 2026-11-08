import AppKit
import SwiftUI

// MARK: - Assets from the original Configurator

func asset(_ name: String) -> Image {
    if let url = Bundle.main.url(forResource: name, withExtension: "png"), let img = NSImage(contentsOf: url) {
        return Image(nsImage: img)
    }
    // The artwork isn't in the repository (tools/fetch-artwork.sh); fall back to a system symbol.
    return Image(systemName: name.hasPrefix("Img_RaidStatus") ? "circle.fill" : "externaldrive")
}

extension Unit.Health {
    var image: Image {
        switch self {
        case .good: return asset("Img_RaidStatus_Good")
        case .attention: return asset("Img_RaidStatus_Attn")
        case .bad: return asset("Img_RaidStatus_Bad")
        }
    }
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
            asset("Img_GR_Icon").resizable().frame(width: 96, height: 96).opacity(0.35)
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
            asset("Img_Authentication_Lock").resizable().scaledToFit().frame(height: 72)
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
    var preview: (step: Int, choice: TargetMode?, typed: String)? = nil   // used by tests/render_previews.sh
    let commit: (TargetMode, String) -> Void
    let cancel: () -> Void

    final class Form: ObservableObject {
        @Published var step = 1
        @Published var choice: TargetMode?
        @Published var name = "G-RAID"
        @Published var typed = ""
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
            if let p = preview { form.step = p.step; form.choice = p.choice; form.typed = p.typed }
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
                Button("Continue") { form.typed = ""; form.step = 2 }
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

    // Step 2
    private var confirmStep: some View {
        let mode = form.choice ?? .raid1
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                asset("Img_RaidStatus_Bad").resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Erase everything on this G-RAID?").font(.title2.weight(.semibold))
                    Text("Switching from \(unit.currentTarget?.label ?? modeText(unit.caps.currentMode)) to \(mode.label) deletes all data on both disks. This can't be undone.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if unit.volumes.isEmpty {
                    Label("No volume is mounted, so the data on it can't be measured.", systemImage: "externaldrive")
                } else {
                    ForEach(unit.volumes, id: \.url) { v in
                        Label("\(v.name): \(formatBytes(v.used)) of data will be erased", systemImage: "externaldrive.fill")
                            .foregroundStyle(v.used > 0 ? .red : .primary)
                    }
                }
                ForEach(unit.unmountedVolumes) { p in
                    Label("\(p.name) (not mounted): everything on it will be erased", systemImage: "externaldrive")
                        .foregroundStyle(.red)
                }
                Label("New setup: \(unit.resultText(for: mode))", systemImage: mode.symbol)
                ForEach(unit.disks.presentPorts, id: \.index) { p in
                    Label("Disk \(p.index + 1): \(p.model), S/N \(p.serial)", systemImage: "internaldrive").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            Text("Next: the volume is ejected, the G-RAID rebuilds the array and reconnects. Then use Disk Utility to erase it and create a new volume.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Type ERASE to confirm").font(.caption).foregroundStyle(.secondary)
                TextField("ERASE", text: $form.typed).textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("Back") { form.step = 1 }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Erase and Set Up \(mode.name)") { commit(mode, form.name) }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(form.typed != "ERASE")
            }
        }
    }
}
