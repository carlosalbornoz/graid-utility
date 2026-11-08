import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings (⌘,)

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Pref.monitorEnabled) private var monitor = false
    @AppStorage(Pref.notifyDisk) private var notifyDisk = true
    @AppStorage(Pref.notifyArray) private var notifyArray = true
    @AppStorage(Pref.notifyConnection) private var notifyConnection = false
    @AppStorage(Pref.notifyConfig) private var notifyConfig = false
    @AppStorage(Pref.letDrivesSleep) private var letDrivesSleep = true
    @AppStorage(Pref.systemReadOnly) private var systemReadOnly = true
    @Environment(\.openWindow) private var openWindow

    final class ServiceState: ObservableObject {
        @Published var unlock: UnlockService.State = UnlockService.status()
        @Published var busy = false
        @Published var error: String?
        @Published var loginNeedsApproval = LoginItem.needsApproval
        @Published var diskSleep: Int?
        private var checkingDiskSleep = false
        func reload() {
            unlock = UnlockService.status()
            loginNeedsApproval = LoginItem.needsApproval
            // pmset is a subprocess: run it in the background, never during a view update.
            guard !checkingDiskSleep else { return }
            checkingDiskSleep = true
            DispatchQueue.global(qos: .utility).async {
                let minutes = SystemSettings.diskSleepMinutes()
                DispatchQueue.main.async {
                    self.checkingDiskSleep = false
                    if self.diskSleep != minutes { self.diskSleep = minutes }
                }
            }
        }
    }
    @StateObject private var svc = ServiceState()
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Monitor in the background", isOn: $monitor)
                    .onChange(of: monitor) { on in
                        if let e = LoginItem.set(on) { svc.error = "Couldn't change the login item: \(e)" }
                        if on { Notifier.requestPermission() }
                        svc.reload()
                    }
                Text("Shows a G-RAID icon in the menu bar, keeps checking after you close the window, and opens at login. Off: the app only checks while its window is open.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Let the drives sleep when the G-RAID isn't in use", isOn: $letDrivesSleep)
                    .disabled(!monitor)
                Text("Checking the G-RAID's status spins its drives up. With this on, background checks pause while nothing is reading or writing the disk, and resume as soon as something does. Off: checks every minute, so the drives never sleep.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if monitor && letDrivesSleep && svc.diskSleep == 0 {
                    Text("macOS is set to never put hard disks to sleep, so the drives keep spinning while the G-RAID is connected. That's easiest on older drives, since spin-ups cause the most wear. To spin them down when you're done, eject the G-RAID.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if monitor && svc.loginNeedsApproval {
                    HStack {
                        Label("Allow G-RAID Utility in Login Items so it can start at login.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") { SystemSettings.openLoginItems() }
                    }
                }
            } header: { Text("Background Monitoring") }

            Section {
                Toggle("Disk problems: failed, missing, or predicted to fail", isOn: $notifyDisk)
                Toggle("Array health: degraded, rebuild started or finished", isOn: $notifyArray)
                Toggle("G-RAID connected or disconnected", isOn: $notifyConnection)
                Toggle("RAID mode changes", isOn: $notifyConfig)
            } header: { Text("Notify Me About") }
            .disabled(!monitor)

            Section {
                Toggle("Unlock the G-RAID automatically when it's connected", isOn: Binding(
                    get: { svc.unlock != .notInstalled },
                    set: { on in toggleService(on) }))
                    .disabled(svc.busy)
                Text("Installs a small background service (one password prompt) so you aren't asked for your password every time you plug the G-RAID in. It only unlocks G-RAID disks, read-only, for your account. Turning this off removes it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                serviceStatus
            } header: { Text("Automatic Unlock") }

            Section {
                Toggle("Mount system partitions read-only", isOn: $systemReadOnly)
                Text("System partitions such as EFI hold startup files, not your data. Read-only lets you look inside without macOS or other apps changing anything; mounted normally, macOS adds its own index folders to them. Turn this off only to edit files there. Your volumes always mount normally.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: { Text("Partitions") }

            Section {
                HStack {
                    Text("\(model.recentEvents.count) events recorded").foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Event History") { openWindow(id: "history"); NSApp.activate(ignoringOtherApps: true) }
                }
            } header: { Text("History") }

            if let e = svc.error {
                Section { Label(e, systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(tick) { _ in svc.reload() }
        .onAppear { svc.reload() }
    }

    @ViewBuilder private var serviceStatus: some View {
        switch svc.unlock {
        case .notInstalled:
            EmptyView()
        case .needsFullDiskAccess:
            VStack(alignment: .leading, spacing: 6) {
                Label("The service needs Full Disk Access to read the G-RAID.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("In Full Disk Access, click +, press ⌘⇧G, and add \(UnlockService.helperPath).")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("Open Full Disk Access") { SystemSettings.openFullDiskAccess() }
                    Button("Show Service in Finder") {
                        NSWorkspace.shared.selectFile(UnlockService.helperPath, inFileViewerRootedAtPath: "")
                    }
                }
            }
        case .outdated:
            HStack {
                Label("The installed service is from an older version of the app.", systemImage: "arrow.triangle.2.circlepath")
                Spacer()
                Button("Update Service") { toggleService(true) }.disabled(svc.busy)
            }
        case .running(let date):
            Label("Working" + (date.map { " · last check \($0.formatted(date: .omitted, time: .shortened))" } ?? ""),
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .stopped:
            HStack {
                Label("Installed but not running.", systemImage: "pause.circle").foregroundStyle(.orange)
                Spacer()
                Button("Reinstall") { toggleService(true) }.disabled(svc.busy)
            }
        }
    }

    private func toggleService(_ on: Bool) {
        svc.busy = true
        svc.error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = on ? UnlockService.install() : UnlockService.uninstall()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                svc.busy = false
                if let r = result, !r.isEmpty { svc.error = r }
                svc.reload()
                model.refresh()
            }
        }
    }
}

// MARK: - Menu bar (only when background monitoring is on)

struct MenuBarIcon: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        switch (model.phase, model.menuHealth) {
        case (.ready, .good?): Image(systemName: "externaldrive.badge.checkmark")
        case (.ready, .attention?): Image(systemName: "externaldrive.badge.exclamationmark")
        case (.ready, .bad?): Image(systemName: "externaldrive.badge.xmark")
        case (.needsAccess, _), (.startingUp, _): Image(systemName: "externaldrive.badge.questionmark")
        case (.ejected, _): Image(systemName: "eject")
        default: Image(systemName: "externaldrive")
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch model.phase {
        case .ready:
            ForEach(model.units) { u in
                Text("\(model.units.count > 1 ? model.name(of: u) : u.model.name): \(modeText(u.caps.currentMode)), \(u.statusText)")
                ForEach(u.disks.presentPorts, id: \.index) { p in
                    Text("    Disk \(p.index + 1): \(diskStatusText(p.status))")
                }
            }
            if let idle = model.idleSince {
                Text("Idle, letting the drives sleep · last checked \(idle.formatted(date: .omitted, time: .shortened))")
            }
        case .needsAccess: Text("G-RAID connected: open the app to allow access")
        case .noDevice: Text(model.usbGRAIDs.isEmpty ? "No G-RAID connected" : "G-RAID connected over USB")
        case .scanning: Text("Checking…")
        case .startingUp: Text("G-RAID connected: starting up…")
        case .ejected:
            Text("G-RAID ejected: safe to unplug")
            Button("Mount Again") { model.mountAgain() }
        }
        if let last = model.recentEvents.last {
            Divider()
            Text("Last event: \(last.title), \(last.date.formatted(date: .abbreviated, time: .shortened))")
        }
        Divider()
        Button("Open G-RAID Utility") { show("main") }
        Button("Event History…") { show("history") }
        Button("Settings…") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        Divider()
        Button("Quit G-RAID Utility") { NSApp.terminate(nil) }
    }

    private func show(_ id: String) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Event history

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    final class Confirm: ObservableObject { @Published var clearing = false }
    @StateObject private var confirm = Confirm()

    var body: some View {
        VStack(spacing: 0) {
            if model.recentEvents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No events yet").font(.headline)
                    Text("Changes in RAID mode, array health and disks, and connects and disconnects, appear here.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.recentEvents.reversed()) {
                    TableColumn("") { e in
                        Image(systemName: icon(e.severity)).foregroundStyle(color(e.severity))
                    }
                    .width(20)
                    TableColumn("Date") { e in Text(e.date.formatted(date: .abbreviated, time: .shortened)) }
                        .width(min: 120, ideal: 140)
                    TableColumn("Event") { e in Text(e.title) }.width(min: 120, ideal: 170)
                    TableColumn("Details") { e in Text(e.detail).foregroundStyle(.secondary).help(e.detail) }.width(min: 160, ideal: 240)
                    TableColumn("Device") { e in Text(e.unitName).foregroundStyle(.secondary) }.width(min: 100, ideal: 160)
                }
            }
            Divider()
            HStack {
                Text("Stored in \(model.eventLog.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                    .font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                Spacer()
                Button("Clear…") { confirm.clearing = true }.disabled(model.recentEvents.isEmpty)
                Button("Export CSV…") { export() }.disabled(model.recentEvents.isEmpty)
            }
            .padding(10)
        }
        .frame(minWidth: 820, minHeight: 360)
        .confirmationDialog("Clear the event history?", isPresented: $confirm.clearing) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: { Text("This deletes all recorded events. It doesn't affect the G-RAID.") }
    }

    private func icon(_ s: EventSeverity) -> String {
        s == .critical ? "exclamationmark.octagon.fill" : s == .warning ? "exclamationmark.triangle.fill" : "info.circle"
    }
    private func color(_ s: EventSeverity) -> Color { s == .critical ? .red : s == .warning ? .orange : .secondary }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "G-RAID events.csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? EventLog.csv(model.recentEvents).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
