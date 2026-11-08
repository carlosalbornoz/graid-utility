import AppKit
import SwiftUI

/// Checks GitHub Releases for a newer G-RAID Utility, once a day while the app runs (if the
/// user lets it) and whenever they choose Check for Updates…. It only tells the user; they
/// download and install the new version themselves.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    /// A newer release found by an automatic check, shown as a bar until dismissed or skipped.
    @Published var available: ReleaseInfo?
    @Published private(set) var checking = false
    @Published private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: Pref.lastUpdateCheck) as? Date

    private var timer: Timer?
    private let interval: TimeInterval = 24 * 3600

    static var currentVersionText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    var currentVersion: AppVersion { AppVersion(Self.currentVersionText) ?? AppVersion("0")! }

    /// Called once at launch: checks now if the last check is a day old, then looks again every
    /// hour (cheap: it only goes to GitHub when a day has passed).
    func start() {
        guard timer == nil else { return }
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in UpdateChecker.shared.checkIfDue() }
        }
    }

    func checkIfDue() {
        guard Pref.checkForUpdates else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < interval { return }
        Task { await check(userInitiated: false) }
    }

    /// Automatic checks stay quiet unless they find something new that the user hasn't skipped.
    /// A check the user asked for always answers, in an alert.
    func check(userInitiated: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        do {
            let releases = try await fetchReleases()
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: Pref.lastUpdateCheck)
            let newer = newerRelease(than: currentVersion, in: releases, includePrereleases: Pref.includePrereleases)
            if userInitiated {
                available = nil
                present(newer)
            } else if let newer, newer.tag != Pref.skippedRelease {
                available = newer
            }
        } catch {
            guard userInitiated else { return }   // offline at launch: try again next hour
            alert("Couldn't check for updates", (error as? ToolError)?.description ?? error.localizedDescription)
        }
    }

    func openRelease(_ r: ReleaseInfo) {
        NSWorkspace.shared.open(r.page)
        available = nil
    }

    func skip(_ r: ReleaseInfo) {
        UserDefaults.standard.set(r.tag, forKey: Pref.skippedReleaseKey)
        available = nil
    }

    // MARK: Alerts for Check for Updates…

    private func present(_ release: ReleaseInfo?) {
        guard let r = release else {
            alert("You're up to date", "G-RAID Utility \(currentVersion) is the newest version\(Pref.includePrereleases ? ", including pre-releases" : "").")
            return
        }
        let a = NSAlert()
        a.messageText = "\(r.title) is available"
        a.informativeText = [
            "You have \(currentVersion).\(r.prerelease ? " This is a pre-release." : "")",
            releaseSummary(r.notes, limit: 300),
            "Download it from the release page, quit G-RAID Utility, and replace the app in Applications.",
        ].compactMap { $0 }.joined(separator: "\n\n")
        a.addButton(withTitle: "View Release")
        a.addButton(withTitle: "Not Now")
        a.addButton(withTitle: "Skip This Version")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: openRelease(r)
        case .alertThirdButtonReturn: skip(r)
        default: break
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

/// "Check for Updates…" under the app menu's About item, where Mac apps put it.
struct UpdateCommands: Commands {
    @ObservedObject var updates = UpdateChecker.shared
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await updates.check(userInitiated: true) } }
                .disabled(updates.checking)
        }
    }
}

/// The bar shown at the top of the window when an automatic check found a newer release.
struct UpdateBar: View {
    @ObservedObject var updates = UpdateChecker.shared
    let release: ReleaseInfo
    var body: some View {
        NoticeBar(notice: Notice(.info, "\(release.title) is available\(release.prerelease ? " (pre-release)" : "")",
                                 releaseSummary(release.notes) ?? "You have \(updates.currentVersion)."),
                  action: ("View Release", { updates.openRelease(release) }),
                  dismiss: { updates.available = nil })
            .contextMenu { Button("Skip This Version") { updates.skip(release) } }
    }
}

/// Settings → Updates.
struct UpdateSettings: View {
    @ObservedObject var updates = UpdateChecker.shared
    @AppStorage(Pref.checkUpdates) private var automatic = true
    @AppStorage(Pref.prereleases) private var prereleases = false

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: $automatic)
                .onChange(of: automatic) { on in if on { updates.checkIfDue() } }
            Toggle("Include pre-releases", isOn: $prereleases)
            Text("Once a day, asks GitHub whether a newer version has been published, and shows a bar at the top of the window if so. Nothing about your Mac or G-RAID is sent.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(statusText).foregroundStyle(.secondary)
                Spacer()
                if updates.checking { ProgressView().controlSize(.small) }
                Button("Check Now") { Task { await updates.check(userInitiated: true) } }
                    .disabled(updates.checking)
            }
        } header: { Text("Updates") }
    }

    private var statusText: String {
        var s = "Version \(UpdateChecker.currentVersionText)"
        if let d = updates.lastChecked {
            s += " · checked " + d.formatted(.relative(presentation: .named))
        }
        return s
    }
}
