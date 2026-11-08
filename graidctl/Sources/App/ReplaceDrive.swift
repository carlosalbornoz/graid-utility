import SwiftUI

/// Guides replacing a drive in a degraded RAID 1 and follows the copy. The controller starts the
/// copy by itself the moment a drive goes into the empty bay (FIRMWARE.md "Rebuild"), so this
/// sheet sends nothing to the G-RAID: it explains each step and reads the status as it changes.
struct ReplaceDriveSheet: View {
    @EnvironmentObject var model: AppModel
    let unitID: String
    var previewUnit: Unit? = nil   // used by tests/render_previews.sh
    var previewSince: Date? = nil
    var previewLeft: TimeInterval? = nil
    var previewRate: Double? = nil
    let close: () -> Void

    final class Memory: ObservableObject {
        @Published var bay: Int?
        @Published var hadRemove = false
        @Published var sawCopy = false
        @Published var confirmingRebuild = false
        @Published var checkedFiles = false
    }
    @StateObject private var memory = Memory()

    private enum Phase: Int { case remove, insert, copy, done }

    private var unit: Unit? { previewUnit ?? model.units.first { $0.id == unitID } }
    private var step: ReplaceStep? { unit?.replaceStep }
    private var phase: Phase {
        switch step {
        case .remove?: return .remove
        case .insert?, .waiting?, .checking?, .needsRebuild?: return .insert
        case .copying?, .paused?, .failed?: return .copy
        case nil: return memory.sawCopy ? .done : .insert
        }
    }
    private var target: Int { memory.bay ?? step?.bay ?? 1 }

    /// Named for why the sheet was opened: watching a copy, starting a rebuild, or replacing a drive.
    private var sheetTitle: String {
        switch step {
        case .copying?, .paused?, .failed?: return "Rebuild"
        case .needsRebuild?: return "Rebuild Bay \(target + 1)"
        case nil where memory.sawCopy: return "Rebuild"
        default: return "Replace a Drive"
        }
    }
    private var sheetIntro: String {
        switch step {
        case .copying?, .paused?:
            return "The G-RAID is copying everything from Bay \(source + 1) onto Bay \(target + 1). You can keep using the volume while it copies."
        case .needsRebuild?:
            return "Bay \(target + 1) holds a drive the G-RAID isn't using. A rebuild replaces its contents with a copy of Bay \(source + 1)."
        default:
            return "The G-RAID copies everything from Bay \(source + 1) onto the new drive in Bay \(target + 1). You can keep using the volume while it copies."
        }
    }
    private var source: Int { target == 0 ? 1 : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(sheetTitle).font(.title2.weight(.semibold))
                Text(sheetIntro)
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if unit == nil {
                Label("The G-RAID isn't connected. Reconnect it to continue.", systemImage: "cable.connector.slash")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if memory.hadRemove { removeRow }
                    insertRow
                    copyRow
                }
                if phase == .remove || phase == .insert { eraseWarning }
            }

            HStack {
                Spacer()
                Button(phase == .done ? "Done" : "Close", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 500)
        .onAppear(perform: remember)
        .onChange(of: step) { _ in remember() }
    }

    private func remember() {
        guard let step else { return }
        if memory.bay == nil { memory.bay = step.bay }
        if case .remove = step { memory.hadRemove = true }
        switch step {
        case .copying, .paused, .failed: memory.sawCopy = true
        default: break
        }
    }

    // MARK: Steps

    private func state(_ p: Phase) -> StepRow.State {
        p.rawValue < phase.rawValue ? .done : (p == phase ? .current : .upcoming)
    }

    private var removeRow: some View {
        let failed = unit?.disks.presentPorts.first { $0.index == target && [6, 8].contains($0.status) }
        let detail = state(.remove) == .done ? "Removed."
            : failed.map { "\($0.model) · \($0.serial) · \(diskStatusText($0.status))" } ?? "The drive the controller marked as failed."
        return StepRow(number: 1, title: "Remove the failed drive from Bay \(target + 1)", detail: detail, state: state(.remove))
    }

    private var insertRow: some View {
        let min = unit.map { driveSizeText($0.replacementMinBytes) } ?? ""
        let blocks = unit.map { replacementMinBlocks(volumeBlocks: $0.raid.volume(0).totalBlocks) } ?? 0
        var detail = "Any make or model with at least \(blocks.formatted()) sectors."
        var extra: AnyView? = nil
        switch step {
        case .checking?:
            detail = "The G-RAID is checking the drive. This takes about 15 seconds."
        case .waiting?:
            detail = "A drive is in. The copy usually starts by itself within a minute."
        case .needsRebuild?:
            detail = "The G-RAID set this drive aside and won't copy onto it by itself. Its contents haven't been erased."
            extra = AnyView(rebuildPanel)
        default:
            break
        }
        if case .needsRebuild? = step {
        } else if state(.insert) == .done, let p = unit?.disks.presentPorts.first(where: { $0.index == target }) {
            detail = "\(p.model) · \(p.serial)"
        }
        let title: String = {
            if case .needsRebuild? = step { return "Rebuild Bay \(target + 1) from Bay \(source + 1)" }
            if state(.insert) == .done { return "Drive in Bay \(target + 1)" }
            return "Insert a drive of \(min) or more in Bay \(target + 1)"
        }()
        return StepRow(number: memory.hadRemove ? 2 : 1, title: title, detail: detail, state: state(.insert), extra: extra)
    }

    private var copyRow: some View {
        let volume = unit?.volumeBytes ?? 0
        let estimate = durationText(rebuildEstimate(volumeBytes: volume))
        let detail: String
        var extra: AnyView? = nil
        switch step {
        case .copying? where unit?.rebuild != nil:
            // The real position, read from the controller's memory.
            let r = unit!.rebuild!
            let left = previewLeft ?? model.rebuildLeft[unitID]
            let rate = previewRate ?? model.rebuildRate[unitID]
            detail = "Copying from Bay \(source + 1) · " + (left.map { "about \(durationText($0)) left" } ?? "working out the time left")
                + (rate.map { " · \(speedText($0))" } ?? "")
            extra = AnyView(VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: r.fraction).accessibilityLabel("Rebuild progress")
                HStack {
                    Text("\(percentText(r.fraction)) · \(formatBytes(Double(r.position) * 512)) of \(formatBytes(Double(r.end) * 512))")
                        .monospacedDigit()
                    Spacer()
                    Text("You can close this window.").foregroundStyle(.secondary)
                }
                .font(.caption)
            })
        case .copying?:
            var parts = ["Copying from Bay \(source + 1)"]
            if let since = previewSince ?? model.rebuildSeenSince(unit: unitID) {
                parts.append("seen since \(since.formatted(date: .omitted, time: .shortened))")
            }
            parts.append("about \(estimate) in total")
            detail = parts.joined(separator: " · ")
            extra = AnyView(VStack(alignment: .leading, spacing: 6) {
                ProgressView().progressViewStyle(.linear)
                Text("The controller doesn't report how far it has got. You can close this window; you'll be notified when it finishes.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            })
        case .paused?:
            detail = "Paused by the controller. It carries on from where it stopped."
        case .failed?:
            detail = "Check the new drive, or try another one. The drive in Bay \(source + 1) still holds everything."
        default:
            detail = phase == .done ? "Both drives hold the same data again."
                : needsRebuild ? "Starts when you rebuild. About \(estimate) for \(driveSizeText(volume))."
                : "Starts by itself once the drive is in. About \(estimate) for \(driveSizeText(volume))."
        }
        return StepRow(number: memory.hadRemove ? 3 : 2, title: phase == .done ? "The copy is complete" : (step.map { if case .failed = $0 { return true } else { return false } } == true ? "The copy failed" : "The G-RAID copies the data"),
                       detail: detail, state: step.map { if case .failed = $0 { return .problem } else { return state(.copy) } } ?? state(.copy),
                       isLast: true, extra: extra)
    }

    private var waiting: Bool { if case .waiting? = step { return true } else { return false } }
    private var needsRebuild: Bool { if case .needsRebuild? = step { return true } else { return false } }

    /// Starts the manual rebuild from inside the guide. The kept drive is the one the controller
    /// is running on; after a detected swap that may be the older copy, so the panel says so.
    @ViewBuilder private var rebuildPanel: some View {
        let keep = unit?.disks.presentPorts.first { $0.index == source }
        let erase = unit?.disks.presentPorts.first { $0.index == target }
        let swapped = model.memberSwapSince(unit: unitID)
        if !memory.confirmingRebuild {
            Button("Rebuild…") { memory.confirmingRebuild = true; memory.checkedFiles = false }
                .disabled(model.isWorking || unit.flatMap { rebuildProblem(caps: $0.caps, raid: $0.raid, disks: $0.disks, source: source) } != nil)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let swapped {
                    Label {
                        Text("At \(swapped.formatted(date: .omitted, time: .shortened)) the G-RAID switched to Bay \(source + 1)'s copy. It may be the older one: changes made while Bay \(source + 1) was out could be missing. Check your files first.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: { Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red) }
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        Text("Keep").foregroundStyle(.secondary)
                        Text("Bay \(source + 1) · \(keep?.model ?? "") · \(keep?.serial ?? "")")
                    }
                    GridRow {
                        Text("Erase").foregroundStyle(.red)
                        Text("Bay \(target + 1) · \(erase?.model ?? "") · \(erase?.serial ?? "")")
                    }
                }
                .font(.callout)
                Toggle(isOn: $memory.checkedFiles) {
                    Text("The files on the G-RAID now are the ones I want to keep")
                }
                .toggleStyle(.checkbox)
                HStack {
                    Button("Cancel") { memory.confirmingRebuild = false }
                    Spacer()
                    Button("Erase Bay \(target + 1) and Copy") {
                        if let u = unit { model.rebuild(unit: u, source: source) }
                        memory.confirmingRebuild = false
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(!memory.checkedFiles || model.isWorking)
                }
            }
            .padding(12)
            .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.red.opacity(0.35), lineWidth: 0.5))
        }
    }

    private var eraseWarning: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(needsRebuild
                 ? "Nothing is erased until you start the rebuild. Then everything on Bay \(target + 1) is replaced with a copy of Bay \(source + 1)."
                 : waiting
                 ? "The drive in Bay \(target + 1) will be erased when the copy starts. If it holds anything you need, take it out now."
                 : "The drive you insert in Bay \(target + 1) is erased as soon as it's in, without asking. Make sure it holds nothing you need.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5))
    }
}

/// One numbered step, with a line down to the next one.
struct StepRow: View {
    enum State { case done, current, upcoming, problem }
    let number: Int
    let title: String
    let detail: String
    let state: State
    var isLast = false
    var extra: AnyView? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                marker
                if !isLast {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1).frame(maxHeight: .infinity).padding(.vertical, 4)
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                    .foregroundStyle(state == .upcoming ? Color.secondary : Color.primary)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let extra { extra.padding(.top, 6) }
            }
            .padding(.bottom, isLast ? 0 : 18)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var marker: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.green).frame(width: 22, height: 22)
        case .problem:
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 20)).foregroundStyle(.red).frame(width: 22, height: 22)
        case .current, .upcoming:
            Text("\(number)").font(.callout.weight(.semibold)).monospacedDigit()
                .foregroundStyle(state == .current ? brandBlue : Color.secondary)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(state == .current ? brandBlue : Color(nsColor: .separatorColor), lineWidth: state == .current ? 1.5 : 1))
        }
    }
}

/// A symbol that turns while the G-RAID is working (the circling arrows during a rebuild), and
/// stays still when it's paused or Reduce Motion is on.
struct SpinningSymbol: View {
    let name: String
    let spinning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A plain rotation rather than the system rotate effect, which didn't always draw.
        if spinning && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                Image(systemName: name)
                    .rotationEffect(.degrees((context.date.timeIntervalSinceReferenceDate / 2).truncatingRemainder(dividingBy: 1) * 360))
            }
        } else {
            Image(systemName: name)
        }
    }
}

/// "42%", or "0.5%" early on so the first minutes visibly move. Rounded down, so it never shows
/// 100% before the copy has finished.
func percentText(_ f: Double) -> String {
    f.formatted(.percent.precision(.fractionLength(f < 0.1 ? 1 : 0)).rounded(rule: .down))
}

/// "5 hours", "40 minutes": the largest unit only, rounded. Callers add "about".
func durationText(_ t: TimeInterval) -> String {
    let f = DateComponentsFormatter()
    f.unitsStyle = .full
    f.maximumUnitCount = 1
    f.allowedUnits = [.hour, .minute]
    return f.string(from: max(60, t)) ?? ""
}
