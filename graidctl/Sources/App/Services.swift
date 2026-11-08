import AppKit
import Foundation
import Security
import ServiceManagement
import UserNotifications

// MARK: - Preferences (all background behaviour is off by default)

enum Pref {
    static let monitorEnabled = "monitorEnabled"
    static let notifyDisk = "notifyDisk"
    static let notifyArray = "notifyArray"
    static let notifyConnection = "notifyConnection"
    static let notifyConfig = "notifyConfig"
    static let letDrivesSleep = "letDrivesSleep"
    static let systemReadOnly = "mountSystemPartitionsReadOnly"
    static let checkUpdates = "checkForUpdates"
    static let prereleases = "includePrereleases"
    static let lastUpdateCheck = "lastUpdateCheck"
    static let skippedReleaseKey = "skippedRelease"
    static let setupDone = "setupDone"
    static let keepOldConfigurator = "keepOldConfigurator"

    static func register() {
        UserDefaults.standard.register(defaults: [
            monitorEnabled: false, notifyDisk: true, notifyArray: true, notifyConnection: false, notifyConfig: false,
            letDrivesSleep: true, systemReadOnly: true, checkUpdates: true, prereleases: false,
        ])
    }
    static var monitor: Bool { UserDefaults.standard.bool(forKey: monitorEnabled) }
    static var drivesMaySleep: Bool { UserDefaults.standard.bool(forKey: letDrivesSleep) }
    /// EFI and other system partitions mount read-only unless the user turns this off.
    static var mountSystemReadOnly: Bool { UserDefaults.standard.bool(forKey: systemReadOnly) }
    static var checkForUpdates: Bool { UserDefaults.standard.bool(forKey: checkUpdates) }
    static var includePrereleases: Bool { UserDefaults.standard.bool(forKey: prereleases) }
    /// The release tag the user chose to skip; automatic checks don't show it again.
    static var skippedRelease: String? { UserDefaults.standard.string(forKey: skippedReleaseKey) }
}

// MARK: - Running a command and reading its output

enum Shell {
    /// Runs a command and returns its standard output. Blocks, and `waitUntilExit` spins the
    /// calling thread's run loop, so never call this on the main thread (SwiftUI can re-enter
    /// mid-update and abort).
    nonisolated static func output(_ path: String, _ args: [String]) -> Data? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }
}

// MARK: - Running a shell script as root (one administrator prompt)

enum Admin {
    /// Runs `script` with bash as root via the standard macOS password dialog.
    /// Returns nil on success, "" if the user cancelled, or an error message.
    static func run(_ script: String, prompt: String) -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("graid-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = dir.appendingPathComponent("run.sh")
            try script.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: dir) }
            func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
            let apple = "do shell script \"/bin/bash \" & quoted form of \"\(esc(file.path))\" with prompt \"\(esc(prompt))\" with administrator privileges"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", apple]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 { return nil }
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return text.contains("-128") ? "" : text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "\(error)"
        }
    }
}

// MARK: - Unlock service (root launchd daemon running `graidctl unlock-daemon`)

enum UnlockService {
    static let label = "local.graid.unlockd"
    static let helperPath = "/Library/PrivilegedHelperTools/local.graid.unlockd"
    static let plistPath = "/Library/LaunchDaemons/local.graid.unlockd.plist"

    enum State: Equatable {
        case notInstalled
        case needsFullDiskAccess
        case outdated
        case running(lastCheck: Date?)
        case stopped
    }

    static var bundledHelper: URL? { Bundle.main.url(forAuxiliaryExecutable: "graidctl") }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: helperPath) && FileManager.default.fileExists(atPath: plistPath)
    }

    static func status() -> State {
        guard isInstalled else { return .notInstalled }
        // Compare code hashes, not bytes: every build re-signs with a new timestamp.
        if let bundled = bundledHelper, let a = codeHash(bundled), let b = codeHash(URL(fileURLWithPath: helperPath)), a != b {
            return .outdated
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "/Library/Application Support/G-RAID Utility/unlockd-status.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .stopped }
        if obj["needs_full_disk_access"] as? Bool == true { return .needsFullDiskAccess }
        if let pid = obj["pid"] as? Int, kill(pid_t(pid), 0) != 0 && errno == ESRCH { return .stopped }
        let date = (obj["time"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return .running(lastCheck: date)
    }

    /// The signature's code directory hash (changes only when the code changes).
    static func codeHash(_ url: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoUnique as String] as? Data
    }

    static func install() -> String? {
        guard let helper = bundledHelper?.path else { return "The graidctl helper is missing from the app bundle." }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key>
          <array><string>\(helperPath)</string><string>unlock-daemon</string><string>--uid</string><string>\(getuid())</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ThrottleInterval</key><integer>30</integer>
          <key>StandardErrorPath</key><string>/Library/Logs/local.graid.unlockd.log</string>
        </dict>
        </plist>
        """
        let q: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        set -e
        launchctl bootout system/\(label) 2>/dev/null || true
        mkdir -p /Library/PrivilegedHelperTools '/Library/Application Support/G-RAID Utility'
        chmod 755 '/Library/Application Support/G-RAID Utility'
        cp -f \(q(helper)) \(helperPath)
        chown root:wheel \(helperPath)
        chmod 755 \(helperPath)
        cat > \(plistPath) <<'PLIST'
        \(plist)
        PLIST
        chown root:wheel \(plistPath)
        chmod 644 \(plistPath)
        launchctl bootstrap system \(plistPath)
        """
        return Admin.run(script, prompt: "G-RAID Utility wants to install a small service that unlocks your G-RAID whenever it's connected.")
    }

    static func uninstall() -> String? {
        let script = """
        launchctl bootout system/\(label) 2>/dev/null || true
        rm -f \(plistPath) \(helperPath) '/Library/Application Support/G-RAID Utility/unlockd-status.json'
        """
        return Admin.run(script, prompt: "G-RAID Utility wants to remove its unlock service.")
    }
}

// MARK: - Login item

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return "\(error.localizedDescription)"
        }
    }
}

// MARK: - Notifications

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func allows(_ e: GRAIDEvent) -> Bool {
        let d = UserDefaults.standard
        guard Pref.monitor else { return false }
        switch e.category {
        case .disk: return d.bool(forKey: Pref.notifyDisk)
        case .array: return d.bool(forKey: Pref.notifyArray)
        case .connection: return d.bool(forKey: Pref.notifyConnection)
        case .config: return d.bool(forKey: Pref.notifyConfig)
        }
    }

    static func post(_ events: [GRAIDEvent]) {
        for e in events where allows(e) {
            let c = UNMutableNotificationContent()
            c.title = e.severity == .critical ? "⚠️ \(e.title)" : e.title
            c.subtitle = e.unitName
            c.body = e.detail
            c.sound = e.severity == .critical ? .defaultCritical : .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: e.id.uuidString, content: c, trigger: nil))
        }
    }
}

// MARK: - Opening System Settings panes

enum SystemSettings {
    static func openFullDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!)
    }
    /// Minutes before macOS spins idle hard disks down (0 = never), from `pmset -g`.
    /// Runs a subprocess: call it off the main thread.
    nonisolated static func diskSleepMinutes() -> Int? {
        guard let data = Shell.output("/usr/bin/pmset", ["-g"]) else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[0] == "disksleep" { return Int(parts[1]) }
        }
        return nil
    }
    static func openLoginItems() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
}
