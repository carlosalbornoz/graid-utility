// Mockups: three ways to onboard a first-time user.
// swiftc -parse-as-library mockups/OnboardingOptions.swift -o build/mock/onboard && build/mock/onboard build/mock
import AppKit
import SwiftUI

let brandBlue = Color(red: 0.0, green: 0.56, blue: 0.80)
let enclosure = NSImage(contentsOfFile: "Resources/Img_Device_GRAID.png").map { Image(nsImage: $0) } ?? Image(systemName: "externaldrive.fill")
let appIcon = NSImage(contentsOfFile: "Resources/AppIcon.icns").map { Image(nsImage: $0) } ?? Image(systemName: "app")

// MARK: - Shared pieces

/// A faux window: title bar with traffic lights, then the 940 × 440 content area the app uses
/// before a G-RAID is ready.
struct Window<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var height: CGFloat = 440
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 12, height: 12) }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.leading, 14)
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 52)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            content.frame(width: 940, height: height)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 940)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.15)))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}

enum StepState { case done, needed, attention, optional, waiting }

struct StateMark: View {
    let state: StepState
    var body: some View {
        Group {
            switch state {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .needed: Image(systemName: "circle").foregroundStyle(brandBlue)
            case .attention: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case .optional: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            case .waiting: ProgressView().controlSize(.small)
            }
        }
        .font(.system(size: 18)).frame(width: 22, height: 22)
    }
}

/// A small drawn System Settings row, to show exactly what to switch on.
struct SettingsToggleSketch: View {
    var on = true
    var body: some View {
        HStack(spacing: 10) {
            appIcon.resizable().frame(width: 22, height: 22)
            Text("G-RAID Utility").font(.callout)
            Spacer()
            Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 34, height: 20)
                .overlay(alignment: on ? .trailing : .leading) { Circle().fill(.white).padding(2).shadow(radius: 0.5, y: 0.5) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

// MARK: - A · One setup checklist in the window

struct ChecklistRow<Trailing: View>: View {
    let state: StepState
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StateMark(state: state)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(state == .done ? .secondary : .primary)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}

struct OptionA: View {
    var body: some View {
        Window(title: "G-RAID Utility", subtitle: "Setup") {
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 10) {
                    enclosure.resizable().scaledToFit().frame(width: 220)
                    Text("Set up G-RAID Utility").font(.title2.weight(.semibold)).padding(.top, 6)
                    Text("A minute or two. Everything here can be changed later in Settings.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 250, alignment: .leading)

                VStack(alignment: .leading, spacing: 14) {
                    VStack(spacing: 0) {
                        ChecklistRow(state: .done, title: "Full Disk Access",
                                     detail: "Allowed. macOS needs this before any app can talk to the G-RAID's controller.") { EmptyView() }
                        Divider().padding(.leading, 48)
                        ChecklistRow(state: .attention, title: "Old Configurator found",
                                     detail: "G-RAID with Thunderbolt Configurator 1.1 is in Downloads. Both apps talking to the controller at once can mix up its commands.") {
                            HStack { Button("Keep") {}; Button("Move to Trash") {} }
                        }
                        Divider().padding(.leading, 48)
                        ChecklistRow(state: .needed, title: "Connect your G-RAID",
                                     detail: "Found on Thunderbolt. Reading it needs your administrator password once per connection.") {
                            Button("Allow Access…") {}.buttonStyle(.borderedProminent).tint(brandBlue)
                        }
                        Divider().padding(.leading, 48)
                        ChecklistRow(state: .optional, title: "Watch it in the background",
                                     detail: "Menu bar icon, and a notification if a drive fails or goes missing.") {
                            Toggle("", isOn: .constant(false)).toggleStyle(.switch).labelsHidden()
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
                    HStack {
                        Button("Skip Setup") {}.buttonStyle(.link)
                        Spacer()
                        Button("Done") {}.disabled(true)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 40).padding(.top, 34)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - B · One step at a time

struct StepDots: View {
    let current: Int, count: Int
    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Circle().fill(i == current ? Color.primary.opacity(0.75) : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
            }
        }
    }
}

struct OptionBStep<Art: View>: View {
    let step: Int
    let title: String
    let body1: String
    let primary: String
    var secondary: String? = nil
    @ViewBuilder let art: Art
    var body: some View {
        Window(title: "Welcome to G-RAID Utility", height: 440) {
            VStack(spacing: 0) {
                Spacer(minLength: 20)
                art.frame(height: 130)
                Text(title).font(.title2.weight(.semibold)).padding(.top, 22)
                Text(body1).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .frame(maxWidth: 480).padding(.top, 6).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if let secondary { Button(secondary) {}.controlSize(.large) }
                    Button(primary) {}.controlSize(.large).buttonStyle(.borderedProminent).tint(brandBlue)
                }
                .padding(.top, 20)
                Spacer(minLength: 20)
                HStack {
                    Button("Back") {}.buttonStyle(.link).opacity(step == 0 ? 0 : 1)
                    Spacer()
                    StepDots(current: step, count: 4)
                    Spacer()
                    Button("Skip") {}.buttonStyle(.link)
                }
                .padding(.horizontal, 28).padding(.bottom, 18)
            }
        }
    }
}

struct OptionB: View {
    var body: some View {
        HStack(alignment: .top, spacing: 30) {
            OptionBStep(step: 1, title: "Allow Full Disk Access",
                        body1: "macOS only lets apps with Full Disk Access talk to the G-RAID's controller. Switch on G-RAID Utility in the list, then choose Quit & Reopen when macOS asks.",
                        primary: "Open Privacy Settings…") {
                VStack(spacing: 8) {
                    SettingsToggleSketch(on: false).frame(width: 300)
                    Image(systemName: "arrow.down").foregroundStyle(.tertiary)
                    SettingsToggleSketch(on: true).frame(width: 300)
                }
            }
            OptionBStep(step: 2, title: "Remove the old Configurator?",
                        body1: "G-RAID with Thunderbolt Configurator 1.1 is in Downloads. G-RAID Utility does everything it did except firmware flashing, and running both at once can mix up commands to the controller.",
                        primary: "Move to Trash", secondary: "Keep It") {
                ZStack {
                    enclosure.resizable().scaledToFit().frame(width: 150).opacity(0.25)
                    Image(systemName: "trash.circle.fill").font(.system(size: 46)).foregroundStyle(.secondary)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-3))
                        .offset(x: 62, y: 36)
                }
            }
        }
    }
}

// MARK: - C · No separate setup: each screen says what's missing

struct OptionC: View {
    var body: some View {
        HStack(alignment: .top, spacing: 30) {
            // The old app as a bar on whatever screen is showing.
            Window(title: "G-RAID Utility", subtitle: "G-RAID found · Needs Full Disk Access") {
                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 18)).foregroundStyle(.orange).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("The old G-RAID Configurator is still on this Mac").font(.callout.weight(.semibold))
                            Text("It's in Downloads. Running both apps at once can mix up commands to the controller.").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 16)
                        Button("Move to Trash") {}
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 22)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    Divider()
                    VStack(spacing: 14) {
                        enclosure.resizable().scaledToFit().frame(height: 110)
                        Text("Allow Full Disk Access").font(.title3.weight(.semibold))
                        Text("The G-RAID is connected, but macOS blocks apps from talking to its controller until they have Full Disk Access.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
                        SettingsToggleSketch().frame(width: 300)
                        Button("Open Privacy Settings…") {}.controlSize(.large).buttonStyle(.borderedProminent).tint(brandBlue)
                        Text("Choose Quit & Reopen when macOS asks.").font(.caption).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

// MARK: - Render

struct Board: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text("First run: three directions").font(.largeTitle.weight(.semibold))
            label("A · One setup checklist (recommended)", "Every step at once, each with live status and its one action. Skippable; the required steps tick themselves off.")
            OptionA()
            label("B · One step at a time", "Welcome pages with Back / Skip, like Setup Assistant. Clear, but more clicks and more ceremony.")
            OptionB()
            label("C · No separate setup", "Each screen explains what's missing when it's missing. Least ceremony, but monitoring and the old app are easy to miss.")
            OptionC()
        }
        .padding(40)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
    func label(_ t: String, _ d: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t).font(.title2.weight(.semibold))
            Text(d).foregroundStyle(.secondary)
        }
        .padding(.bottom, -14)
    }
}

@main
struct Render {
    @MainActor static func main() {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: Board())
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("onboarding.png")
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
        print("wrote \(url.path)")
    }
}
