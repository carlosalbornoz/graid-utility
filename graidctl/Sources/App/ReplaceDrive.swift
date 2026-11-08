import SwiftUI

/// Guides replacing a drive in a degraded RAID 1 and follows the copy. The controller starts the
/// copy by itself the moment a drive goes into the empty bay (FIRMWARE.md "Rebuild"), so this
/// sheet sends nothing to the G-RAID: it explains each step and reads the status as it changes.
struct ReplaceDriveSheet: View {
    @EnvironmentObject var model: AppModel
    let unitID: String
    var previewUnit: Unit? = nil   // used by tests/render_previews.sh
    var previewSince: Date? = nil
    let close: () -> Void

    final class Memory: ObservableObject {
        @Published var bay: Int?
        @Published var hadRemove = false
        @Published var sawCopy = false
    }
    @StateObject private var memory = Memory()

    private enum Phase: Int { case remove, insert, copy, done }

    private var unit: Unit? { previewUnit ?? model.units.first { $0.id == unitID } }
    private var step: ReplaceStep? { unit?.replaceStep }
    private var phase: Phase {
        switch step {
        case .remove?: return .remove
        case .insert?, .waiting?: return .insert
        case .copying?, .paused?, .failed?: return .copy
        case nil: return memory.sawCopy ? .done : .insert
        }
    }
    private var target: Int { memory.bay ?? step?.bay ?? 1 }
    private var source: Int { target == 0 ? 1 : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Replace a Drive").font(.title2.weight(.semibold))
                Text("The G-RAID copies everything from Bay \(source + 1) onto the new drive in Bay \(target + 1). You can keep using the volume while it copies.")
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
        if case .waiting? = step {
            detail = "A drive is in, but the copy hasn't started. If nothing changes within a minute, take it out and insert it again."
        } else if state(.insert) == .done, let p = unit?.disks.presentPorts.first(where: { $0.index == target }) {
            detail = "\(p.model) · \(p.serial)"
        }
        return StepRow(number: memory.hadRemove ? 2 : 1, title: "Insert a drive of \(min) or more in Bay \(target + 1)",
                       detail: detail, state: state(.insert))
    }

    private var copyRow: some View {
        let volume = unit?.volumeBytes ?? 0
        let estimate = durationText(rebuildEstimate(volumeBytes: volume))
        let detail: String
        var extra: AnyView? = nil
        switch step {
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
                : "Starts by itself once the drive is in. About \(estimate) for \(driveSizeText(volume))."
        }
        return StepRow(number: memory.hadRemove ? 3 : 2, title: phase == .done ? "The copy is complete" : (step.map { if case .failed = $0 { return true } else { return false } } == true ? "The copy failed" : "The G-RAID copies the data"),
                       detail: detail, state: step.map { if case .failed = $0 { return .problem } else { return state(.copy) } } ?? state(.copy),
                       isLast: true, extra: extra)
    }

    private var waiting: Bool { if case .waiting? = step { return true } else { return false } }

    private var eraseWarning: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(waiting
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

/// "about 8 hours", "about 40 minutes".
func durationText(_ t: TimeInterval) -> String {
    let hours = t / 3600
    if hours >= 1.5 { return "\(Int(hours.rounded())) hours" }
    if hours >= 0.75 { return "1 hour" }
    return "\(max(1, Int((t / 60).rounded()))) minutes"
}
