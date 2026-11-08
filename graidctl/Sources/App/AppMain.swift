import AppKit
import SwiftUI

@main
struct GRAIDUtilityApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared
    @AppStorage(Pref.monitorEnabled) private var monitor = false

    var body: some Scene {
        Window("G-RAID Utility", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Device") {
                Button("Refresh") { model.refreshNow() }
                    .keyboardShortcut("r")
                    .disabled(model.isWorking)
                Divider()
                Button("Eject") { if let u = model.selected { model.eject(u) } }
                    .keyboardShortcut("e")
                    .disabled(model.isWorking || model.phase != .ready || !(model.selected?.hasMountedPartitions ?? false))
                Button("Mount Again") { model.mountAgain() }
                    .disabled(model.isWorking || model.phase != .ejected)
                Menu("Partitions") {
                    if let u = model.selected, model.phase == .ready, !u.partitions.isEmpty {
                        ForEach(u.partitions) { p in
                            let label = p.kind == .volume ? p.name : "\(p.name) (\(p.kind == .system ? "system" : "unreadable"))"
                            if p.isMounted {
                                Button("Unmount \(label)") { model.unmount(p) }
                            } else if p.mountable {
                                Button("Mount \(label)") { model.mount(p) }
                            } else {
                                Text("\(label): can't be mounted")
                            }
                        }
                    } else {
                        Text("No partitions")
                    }
                }
                .disabled(model.isWorking || model.phase != .ready)
                Button("Check Drive Spin State") { model.checkSpinState() }
                    .disabled(model.isWorking || !(model.phase == .ready || model.phase == .ejected))
                Divider()
                Button("Speed Test…") { if let u = model.selected { model.startSpeedTest(u) } }
                    .disabled(model.phase != .ready || (model.selected?.writableVolumes.isEmpty ?? true))
                Button("Export Health Report…") { if let u = model.selected { HealthReport.export(unit: u, events: model.recentEvents) } }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.phase != .ready)
            }
            CommandGroup(before: .toolbar) {
                ForEach(Array(MainTab.allCases.enumerated()), id: \.element) { i, t in
                    Button(t.rawValue) { model.tab = t }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                        .disabled(model.phase != .ready)
                }
                Divider()
            }
            HistoryCommand()
            UpdateCommands()
        }

        Window("Event History", id: "history") {
            HistoryView().environmentObject(model)
        }

        Settings {
            SettingsView().environmentObject(model)
        }

        // Only present while background monitoring is on.
        MenuBarExtra(isInserted: $monitor) {
            MenuBarContent().environmentObject(model)
        } label: {
            MenuBarIcon().environmentObject(model)
        }
    }
}

struct HistoryCommand: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(before: .windowArrangement) {
            Button("Event History") { openWindow(id: "history") }
                .keyboardShortcut("y")
            Divider()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Pref.register()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AppModel.shared.start()
            UpdateChecker.shared.start()
        }
    }

    /// With background monitoring on, closing the window keeps the app running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Pref.monitor
    }
}
