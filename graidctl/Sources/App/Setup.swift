import AppKit
import SwiftUI

// MARK: - What setup needs to know

/// Full Disk Access, the old Configurator, and whether setup has been finished. Checked at
/// launch, whenever the app becomes active, and every two seconds while access is missing
/// (a file-open check, nothing more).
@MainActor
final class SetupState: ObservableObject {
    static let shared = SetupState()

    @Published var fullDiskAccess = true
    /// Copies of the old Configurator that macOS knows about, outside the Trash.
    @Published var oldCopies: [URL] = []
    @Published var oldRunning = false
    /// Set after Move to Trash, so the checklist can say it's done.
    @Published var oldTrashed = false
    @Published var openedPrivacySettings = false
    @Published var problem: String?
    /// The old-app bar was closed for this session.
    @Published var oldBarDismissed = false
    /// Off in tests/render_previews.sh, which sets the state by hand.
    var checksSystem = true

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        refresh()
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in SetupState.shared.refreshOldApp() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in SetupState.shared.refresh() }
        })
    }

    func refresh() {
        guard checksSystem else { return }
        refreshAccess()
        refreshOldApp()
    }

    private func refreshAccess() {
        let granted = Self.hasFullDiskAccess()
        if granted != fullDiskAccess { fullDiskAccess = granted }
        if granted { timer?.invalidate(); timer = nil }
        else if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { @MainActor in SetupState.shared.refreshAccess() }
            }
        }
    }

    func refreshOldApp() {
        guard checksSystem else { return }
        let copies = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: oldConfiguratorBundleID)
            .filter { !$0.path.contains("/.Trash/") }
        if copies != oldCopies { oldCopies = copies }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: oldConfiguratorBundleID).isEmpty
        if running != oldRunning { oldRunning = running }
    }

    /// macOS protects its privacy database with Full Disk Access, so being able to open it is
    /// the standard way to tell whether this app has that access. A missing file means we can't
    /// tell; then the disk reads themselves report it.
    nonisolated static func hasFullDiskAccess() -> Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return errno != EPERM && errno != EACCES
    }

    // MARK: Old Configurator

    var oldPlaces: String {
        placesText(oldCopies.map { FileManager.default.displayName(atPath: $0.deletingLastPathComponent().path) })
    }

    var keepOld: Bool { UserDefaults.standard.bool(forKey: Pref.keepOldConfigurator) }

    func keepOldConfigurator() {
        UserDefaults.standard.set(true, forKey: Pref.keepOldConfigurator)
        objectWillChange.send()
    }

    /// Quits it if it's open, then moves every copy to the Trash (the user can put it back).
    func trashOldConfigurator() {
        problem = nil
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: oldConfiguratorBundleID)
        running.forEach { $0.terminate() }
        let urls = oldCopies
        DispatchQueue.main.asyncAfter(deadline: .now() + (running.isEmpty ? 0 : 1.5)) {
            NSWorkspace.shared.recycle(urls) { _, error in
                Task { @MainActor in
                    let s = SetupState.shared
                    if let error { s.problem = "Couldn't move the old Configurator to the Trash: \(error.localizedDescription)" }
                    else { s.oldTrashed = true }
                    s.refreshOldApp()
                }
            }
        }
    }

    func quitOldConfigurator() {
        NSRunningApplication.runningApplications(withBundleIdentifier: oldConfiguratorBundleID).forEach { $0.terminate() }
    }

    // MARK: Full Disk Access

    func openPrivacySettings() {
        openedPrivacySettings = true
        SystemSettings.openFullDiskAccess()
    }

    /// macOS applies Full Disk Access when an app starts, so after switching it on the app
    /// opens itself again.
    func reopen() {
        Self.openAgainAfterExit()
        NSApp.terminate(nil)
    }

    /// Starts a small shell that waits for this process to exit, then opens the app again.
    /// Waiting on the process (not a fixed delay) matters: `open` on an app that is still
    /// quitting just activates the dying copy.
    nonisolated static func openAgainAfterExit() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                       Bundle.main.bundlePath, String(getpid())]
        try? p.run()
    }

    /// System Settings' Quit & Reopen (after a Full Disk Access change) quits the app but
    /// doesn't always open it again (seen on macOS 27, 2026-11-09: the quit arrived, no launch
    /// followed). When the quit request comes from System Settings, reopen ourselves.
    nonisolated static func quitCameFromSystemSettings(_ quit: NSAppleEventDescriptor? = nil) -> Bool {
        guard let event = quit ?? NSAppleEventManager.shared().currentAppleEvent,
              let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value,
              let sender = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier else { return false }
        NSLog("Quit requested by %@", sender)
        return sender == "com.apple.systempreferences" || sender.hasPrefix("com.apple.settings")
    }

    // MARK: Finishing setup

    static var isDone: Bool { UserDefaults.standard.bool(forKey: Pref.setupDone) }

    /// People updating from an earlier version have already set things up: the app writes a
    /// status file after every successful read, so its presence means "not a first run".
    static func skipForExistingUsers() {
        guard UserDefaults.standard.object(forKey: Pref.setupDone) == nil else { return }
        let status = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/G-RAID Utility/last-status.json")
        if FileManager.default.fileExists(atPath: status.path) {
            UserDefaults.standard.set(true, forKey: Pref.setupDone)
        }
    }
}

// MARK: - The setup checklist (first run, and G-RAID Utility → Show Setup…)

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var setup = SetupState.shared
    @AppStorage(Pref.monitorEnabled) private var monitor = false
    @AppStorage(Pref.setupDone) private var done = false

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 10) {
                asset("Img_Device_GRAID").resizable().scaledToFit().frame(width: 220, height: 150)
                    .foregroundStyle(.secondary)
                Text("Set up G-RAID Utility").font(.title2.weight(.semibold)).padding(.top, 6)
                Text("A minute or two. You can change all of this later in Settings.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 250, alignment: .leading)

            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 0) {
                    accessRow
                    if showOldRow { Divider().padding(.leading, 48); oldAppRow }
                    Divider().padding(.leading, 48)
                    connectRow
                    Divider().padding(.leading, 48)
                    monitorRow
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
                if let p = setup.problem {
                    Label(p, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Skip Setup") { done = true }.buttonStyle(.link)
                    Spacer()
                    if !setup.fullDiskAccess {
                        Text("Full Disk Access is needed to finish.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Done") { done = true }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!setup.fullDiskAccess)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 40).padding(.top, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { setup.refresh() }
    }

    // Full Disk Access
    private var accessRow: some View {
        let stillBlocked = setup.fullDiskAccess && model.phase == .needsFullDiskAccess
        return SetupRow(state: setup.fullDiskAccess && !stillBlocked ? .done : .needed, title: "Full Disk Access",
                        detail: setup.fullDiskAccess
                            ? (stillBlocked ? "Allowed. Reopen G-RAID Utility so macOS applies it." : "Allowed. macOS needs this before any app can talk to the G-RAID's controller.")
                            : "macOS only lets apps with Full Disk Access talk to the G-RAID's controller. Switch on G-RAID Utility in the list\(setup.openedPrivacySettings ? ", then choose Quit & Reopen" : "").") {
            if stillBlocked {
                Button("Reopen") { setup.reopen() }
            } else if !setup.fullDiskAccess {
                Button("Open Privacy Settings…") { setup.openPrivacySettings() }
            }
        }
    }

    // The old Configurator
    private var showOldRow: Bool { setup.oldTrashed || (!setup.oldCopies.isEmpty && !setup.keepOld) }

    private var oldAppRow: some View {
        Group {
            if setup.oldTrashed && setup.oldCopies.isEmpty {
                SetupRow(state: .done, title: "Old Configurator removed",
                         detail: "Moved to the Trash. You can put it back from there if you ever need it.") { EmptyView() }
            } else {
                SetupRow(state: .attention, title: "Old Configurator found",
                         detail: "G-RAID with Thunderbolt Configurator is \(setup.oldRunning ? "open, and it's " : "")\(setup.oldPlaces). G-RAID Utility replaces it, and both apps talking to the controller at once can mix up its commands.") {
                    HStack {
                        Button("Keep") { setup.keepOldConfigurator() }
                        Button(setup.oldRunning ? "Quit and Move to Trash" : "Move to Trash") { setup.trashOldConfigurator() }
                    }
                }
            }
        }
    }

    // Connecting the G-RAID
    private var connectRow: some View {
        let title = "Connect your G-RAID"
        switch model.phase {
        case .ready:
            let u = model.selected
            return AnyView(SetupRow(state: .done, title: "G-RAID connected",
                                    detail: [u?.model.name, u.map { $0.currentTarget?.chip ?? modeText($0.caps.currentMode) }, u?.capacityText].compactMap { $0 }.joined(separator: " · ")) { EmptyView() })
        case .needsAccess:
            if model.isWorking {
                return AnyView(SetupRow(state: .waiting, title: title, detail: "Waiting for your password…") { EmptyView() })
            }
            if model.wakingDrives {
                return AnyView(SetupRow(state: .waiting, title: title,
                                        detail: "Access allowed. Waking the drives… this can take about 30 seconds.") { EmptyView() })
            }
            if model.waitingForUnlockService {
                return AnyView(SetupRow(state: .waiting, title: title, detail: "Found. The automatic unlock service is getting it ready.") { EmptyView() })
            }
            return AnyView(SetupRow(state: .needed, title: title,
                                    detail: "Found on Thunderbolt. Reading it needs your administrator password, once each time it's connected.") {
                Button("Allow Access…") { model.requestAccess() }.disabled(model.isWorking)
            })
        case .needsFullDiskAccess:
            return AnyView(SetupRow(state: .needed, title: title, detail: "Found on Thunderbolt. Allow Full Disk Access first.") { EmptyView() })
        case .startingUp:
            return AnyView(SetupRow(state: model.startingUpTooLong ? .attention : .waiting, title: title,
                                    detail: model.startingUpTooLong ? "Found, but its disk hasn't appeared. Check both drives are seated, then switch it off and on."
                                                                    : "Found on Thunderbolt. Its disk usually appears within about 30 seconds.") { EmptyView() })
        case .scanning:
            return AnyView(SetupRow(state: .waiting, title: title, detail: "Looking for a G-RAID…") { EmptyView() })
        case .ejected:
            return AnyView(SetupRow(state: .optional, title: title, detail: "Ejected. Choose Device → Mount Again to use it.") { EmptyView() })
        case .noDevice:
            if !model.usbGRAIDs.isEmpty {
                return AnyView(SetupRow(state: .attention, title: title,
                                        detail: "Connected over USB. Your files work, but the RAID controller can only be checked over Thunderbolt.") { EmptyView() })
            }
            return AnyView(SetupRow(state: .needed, title: title,
                                    detail: "Connect it with a Thunderbolt cable and switch it on. You can also finish setup without it.") { EmptyView() })
        }
    }

    // Background monitoring
    private var monitorRow: some View {
        SetupRow(state: monitor ? .done : .optional, title: "Watch it in the background",
                 detail: "A menu bar icon, and a notification if a drive fails or goes missing. Opens at login.") {
            // Acts only on the user's click, not when Settings changes the same preference.
            Toggle("Watch in the background", isOn: Binding(get: { monitor }, set: { on in
                monitor = on
                if let e = LoginItem.set(on) { setup.problem = "Couldn't change the login item: \(e)" }
                if on { Notifier.requestPermission() }
            }))
            .toggleStyle(.switch).labelsHidden()
        }
    }
}

enum SetupStep { case done, needed, attention, optional, waiting }

struct SetupRow<Trailing: View>: View {
    let state: SetupStep
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            mark.font(.system(size: 18)).frame(width: 22, height: 22).accessibilityLabel(stateName)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(state == .done ? .secondary : .primary)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var mark: some View {
        switch state {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .needed: Image(systemName: "circle").foregroundStyle(brandBlue)
        case .attention: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .optional: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .waiting: ProgressView().controlSize(.small)
        }
    }

    private var stateName: String {
        switch state {
        case .done: return "Done"
        case .needed: return "To do"
        case .attention: return "Needs attention"
        case .optional: return "Optional"
        case .waiting: return "In progress"
        }
    }
}

// MARK: - Full Disk Access screen (whenever it's missing, after setup too)

struct FullDiskAccessView: View {
    @ObservedObject var setup = SetupState.shared
    var body: some View {
        VStack(spacing: 14) {
            asset("Img_Device_GRAID").resizable().scaledToFit().frame(height: 110)
            Text("Allow Full Disk Access").font(.title3.weight(.semibold))
            if setup.fullDiskAccess {
                Text("Full Disk Access is on. macOS applies it when G-RAID Utility starts, so reopen the app to read the G-RAID.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
                Button("Reopen G-RAID Utility") { setup.reopen() }
                    .controlSize(.large).keyboardShortcut(.defaultAction)
            } else {
                Text("The G-RAID is connected, but macOS blocks apps from talking to its controller until they have Full Disk Access.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
                SettingsToggleSketch().frame(width: 300)
                Button("Open Privacy Settings…") { setup.openPrivacySettings() }
                    .controlSize(.large).keyboardShortcut(.defaultAction)
                Text("Switch on G-RAID Utility, then choose Quit & Reopen when macOS asks.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A small drawing of the System Settings row to switch on.
struct SettingsToggleSketch: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage()).resizable().frame(width: 22, height: 22)
            Text("G-RAID Utility").font(.callout)
            Spacer()
            Capsule().fill(Color.accentColor).frame(width: 34, height: 20)
                .overlay(alignment: .trailing) { Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .accessibilityLabel("In the list, switch on G-RAID Utility")
    }
}

// MARK: - The old Configurator, after setup

/// Shown at the top of the window when the old app is still around (unless the user chose to
/// keep it), and always while it's open.
struct OldConfiguratorBar: View {
    @ObservedObject var setup = SetupState.shared
    var body: some View {
        NoticeBar(notice: setup.oldRunning
                    ? Notice(.problem, "The old G-RAID Configurator is open",
                             "Both apps talking to the controller at once can mix up its commands. Quit it while you use G-RAID Utility.")
                    : Notice(.problem, "The old G-RAID Configurator is still on this Mac",
                             "It's \(setup.oldPlaces). G-RAID Utility replaces it, and both apps talking to the controller at once can mix up its commands."),
                  action: setup.oldRunning ? ("Quit It", { setup.quitOldConfigurator() })
                                           : ("Move to Trash", { setup.trashOldConfigurator() }),
                  dismiss: { if !setup.oldRunning { setup.keepOldConfigurator() }; setup.oldBarDismissed = true })
    }

    /// Whether the bar belongs on screen now.
    @MainActor static var shouldShow: Bool {
        let s = SetupState.shared
        if s.oldBarDismissed { return false }
        return s.oldRunning || (!s.oldCopies.isEmpty && !s.keepOld)
    }
}

/// G-RAID Utility → Show Setup…
struct SetupCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Show Setup…") { UserDefaults.standard.set(false, forKey: Pref.setupDone) }
        }
    }
}
