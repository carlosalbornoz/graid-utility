// Mockups: the message banner and the erase confirmation, current vs proposed.
// swiftc -parse-as-library mockups/BannerEraseOptions.swift -o build/mock/banner && build/mock/banner build/mock
import AppKit
import SwiftUI

let brandBlue = Color(red: 0.0, green: 0.56, blue: 0.80)
let drive = NSImage(contentsOfFile: "Resources/Img_Device_GRAID.png").map { Image(nsImage: $0) } ?? Image(systemName: "externaldrive.fill")

// MARK: - Shared bits

struct Caption: View {
    let title: String
    let note: String
    var width: CGFloat = 620
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: width, alignment: .leading)
    }
}

/// A plain window frame with a title bar, standing in for the main window.
struct WindowFrame<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 12, height: 12) }
                VStack(alignment: .leading, spacing: 0) {
                    Text("G-RAID Utility").font(.headline)
                    Text("G-RAID found · Starting up…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 30)
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 52)
            content
        }
        .frame(width: width)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}

struct StartingUp: View {
    var body: some View {
        VStack(spacing: 12) {
            drive.resizable().scaledToFit().frame(height: 90)
            ProgressView().controlSize(.small)
            Text("Starting up…").font(.title3.weight(.semibold))
            Text("G-RAID with Thunderbolt is connected. Its disk usually appears within about 30 seconds.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity).frame(height: 300)
    }
}

// MARK: - Banner

enum Tone { case done, problem, info
    var symbol: String { self == .done ? "checkmark.circle.fill" : self == .problem ? "exclamationmark.triangle.fill" : "info.circle.fill" }
    var color: Color { self == .done ? .green : self == .problem ? .orange : brandBlue }
}

/// Today's banner, reproduced.
struct CurrentBanner: View {
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "info.circle")
            Text("RAID mode changed to Protected (RAID 1). The G-RAID reconnects in a few seconds. Then erase it in Disk Utility to create a volume.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Open Disk Utility") {}
            Button("Dismiss") {}.buttonStyle(.link)
        }
        .padding(12)
        .background(.thinMaterial)
    }
}

/// Proposed: a title line plus one sentence, a tone icon centred on the block, the action and a
/// close button on the same centre line.
struct NewBanner: View {
    let tone: Tone
    let title: String
    let detail: String
    var action: String?
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: tone.symbol).font(.system(size: 18)).foregroundStyle(tone.color).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            if let action { Button(action) {}.controlSize(.regular) }
            Button {} label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Dismiss")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct BannerBoard: View {
    let done = NewBanner(tone: .done, title: "Switched to Protected (RAID 1)",
                         detail: "The G-RAID reconnects in a few seconds. Then create a volume on it in Disk Utility.",
                         action: "Open Disk Utility")
    let problem = NewBanner(tone: .problem, title: "G-RAID couldn't be ejected",
                            detail: "It's in use by Finder. Close any open files on it and try again.")
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Message banner").font(.title.weight(.semibold))
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 10) {
                    WindowFrame(width: 620) { StartingUp(); Divider(); CurrentBanner() }
                    Caption(title: "Now", note: "Icon pinned to the first line, a bordered button next to a link so their text doesn't line up, the same ⓘ for good news and problems, and it sits at the bottom edge, away from where you're looking.")
                }
                VStack(alignment: .leading, spacing: 10) {
                    WindowFrame(width: 620) {
                        Divider()
                        done.background(Color(nsColor: .controlBackgroundColor))
                        Divider()
                        StartingUp()
                    }
                    Caption(title: "A · Top bar, under the title (recommended)", note: "Where macOS apps put information bars (Safari, Mail). Read straight after the title, before the content. A short bold headline and one sentence; a green check for done, orange triangle for problems; the action and an ✕ on one centre line.")
                }
            }
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 10) {
                    WindowFrame(width: 620) { StartingUp(); Divider(); done.background(Color(nsColor: .controlBackgroundColor)) }
                    Caption(title: "B · Same bar, kept at the bottom", note: "Fixes the alignment and tone only, if you'd rather the content never shifts down when a message appears.")
                }
                VStack(alignment: .leading, spacing: 10) {
                    WindowFrame(width: 620) {
                        Divider()
                        problem.background(Color(nsColor: .controlBackgroundColor))
                        Divider()
                        StartingUp()
                    }
                    Caption(title: "A, with a problem", note: "The same bar for an error: orange triangle, what happened, what to do. No button when there's nothing to press.")
                }
            }
        }
    }
}

// MARK: - Erase sheet

struct SheetFrame<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(22)
            .frame(width: 540)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}

struct CurrentErase: View {
    var body: some View {
        SheetFrame {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).font(.system(size: 40)).frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Erase everything on this G-RAID?").font(.title2.weight(.semibold))
                        Text("Switching from Performance (RAID 0) to Protected (RAID 1) deletes all data on both disks. This can't be undone.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label("G-RAID: 718.0 GB of data will be erased", systemImage: "externaldrive.fill").foregroundStyle(.red)
                    Label("New setup: 4.00 TB, an exact copy on each disk", systemImage: "lock.shield")
                    Label("Disk 1: HGST HUS724040ALE640, S/N PK1334PEHT4U9S", systemImage: "internaldrive").foregroundStyle(.secondary)
                    Label("Disk 2: HGST HUS724040ALE640, S/N PK1334PEHNVSSS", systemImage: "internaldrive").foregroundStyle(.secondary)
                }
                .font(.callout)
                Text("Next: the volume is ejected, the G-RAID rebuilds the array and reconnects. Then use Disk Utility to erase it and create a new volume.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Type ERASE to confirm").font(.caption).foregroundStyle(.secondary)
                    TextField("ERASE", text: .constant("ERA")).textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button("Back") {}
                    Spacer()
                    Button("Cancel") {}
                    Button("Erase and Set Up Protected") {}.buttonStyle(.borderedProminent).tint(.red).disabled(true)
                }
            }
        }
    }
}

/// One side of the before/after.
struct SetupCard: View {
    let label: String
    let symbol: String
    let mode: String
    let size: String
    let contents: String
    let contentsColor: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(brandBlue).frame(width: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(mode).font(.body.weight(.semibold))
                    Text(size).font(.callout).foregroundStyle(.secondary)
                }
            }
            Text(contents).font(.callout.weight(.medium)).foregroundStyle(contentsColor)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

struct NextSteps: View {
    let steps = ["The G-RAID ejects and sets itself up. Takes a few seconds.",
                 "It reconnects by itself, empty.",
                 "Create a volume on it in Disk Utility, then copy your files back."]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What happens next").font(.callout.weight(.semibold))
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(i + 1)").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 16, height: 16).overlay(Circle().strokeBorder(Color(nsColor: .separatorColor)))
                    Text(s).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A: before → after, then what happens, then the typed confirmation.
struct EraseA: View {
    var body: some View {
        SheetFrame {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Switch to Protected and erase the G-RAID?").font(.title2.weight(.semibold))
                    Text("Everything on it is deleted, including **718 GB** on the G-RAID volume. This can't be undone, so make sure your files are backed up first.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    SetupCard(label: "Now", symbol: "speedometer", mode: "Performance", size: "8.00 TB · RAID 0",
                              contents: "718 GB of files", contentsColor: .primary)
                    Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                    SetupCard(label: "After", symbol: "lock.shield", mode: "Protected", size: "4.00 TB · RAID 1",
                              contents: "Empty", contentsColor: .red)
                }
                NextSteps()
                DisclosureGroup(isExpanded: .constant(false)) { EmptyView() } label: {
                    Text("Disks: 2 × HGST HUS724040ALE640").font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                HStack(spacing: 10) {
                    Text("Type **ERASE** to confirm").font(.callout)
                    TextField("", text: .constant("")).textFieldStyle(.roundedBorder).frame(width: 110)
                    Spacer()
                }
                HStack {
                    Button("Back") {}
                    Spacer()
                    Button("Cancel") {}
                    Button("Erase and Switch") {}.buttonStyle(.borderedProminent).tint(.red).disabled(true)
                }
            }
        }
    }
}

/// B: a plain-spoken note, with a backup checkbox instead of typing.
struct EraseB: View {
    var body: some View {
        SheetFrame {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 14) {
                    drive.resizable().scaledToFit().frame(width: 72)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).font(.system(size: 22))
                                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-3)).offset(x: 6, y: 4)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Erase the G-RAID?").font(.title2.weight(.semibold))
                        Text("To switch to Protected, the G-RAID starts over empty.").foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your **718 GB** of files on the G-RAID volume will be deleted, and they can't be recovered afterwards.")
                    Text("You'll end up with **4.00 TB** of space instead of 8.00 TB, with every file kept on both disks, so the G-RAID keeps working if one of them fails.")
                    Text("It takes a few seconds. Afterwards, create a volume on it in Disk Utility and copy your files back.")
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: .constant(false)) { Text("My files are backed up somewhere else") }
                    .toggleStyle(.checkbox)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack {
                    Button("Back") {}
                    Spacer()
                    Button("Cancel") {}
                    Button("Erase 718 GB and Switch") {}.buttonStyle(.borderedProminent).tint(.red).disabled(true)
                }
            }
        }
    }
}

struct EraseBoard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Erase confirmation").font(.title.weight(.semibold))
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 10) {
                    CurrentErase()
                    Caption(title: "Now", note: "Eight equal rows. The number that matters, 718 GB of your files, is one red line among serial numbers. What happens next is small grey print.", width: 540)
                }
                VStack(alignment: .leading, spacing: 10) {
                    EraseA()
                    Caption(title: "A · Before and after (recommended)", note: "The question in words, the 718 GB in the first sentence, then the change as two cards you can compare at a glance. Next steps numbered. Disk details folded away. Keeps typing ERASE, as a short inline field.", width: 540)
                }
                VStack(alignment: .leading, spacing: 10) {
                    EraseB()
                    Caption(title: "B · Plain note", note: "Three short sentences, like a person explaining it: what you lose, what you get, what happens after. A backup checkbox instead of typing; the button names the amount. Friendlier, but a checkbox is easier to tick without reading.", width: 540)
                }
            }
        }
    }
}


/// Space used on a setup, as a thin solid bar.
struct UsageBar: View {
    let fraction: Double
    let tint: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(tint).frame(width: max(fraction > 0 ? 4 : 0, g.size.width * fraction))
            }
        }
        .frame(height: 6)
    }
}

struct SpaceCard: View {
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
                VStack(alignment: .leading, spacing: 0) {
                    Text(mode).font(.body.weight(.semibold))
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            }
            UsageBar(fraction: fraction, tint: brandBlue)
            Text(usage).font(.callout).foregroundStyle(usageColor).monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

/// The data-loss bar: a tinted panel with a hairline border in the same hue.
struct LossBar: View {
    let tint: Color
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 17)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("718 GB of files on G-RAID will be deleted").font(.body.weight(.semibold))
                Text("Both disks are erased, all 8.00 TB, and nothing on them can be recovered afterwards. Back up anything you need first.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.45), lineWidth: 0.5))
    }
}

/// A + B combined: B's picture and plain words, A's before/after and typed confirmation,
/// plus a tinted bar that states the loss.
struct EraseCombined: View {
    let tint: Color
    let typed: String
    var body: some View {
        SheetFrame {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 14) {
                    drive.resizable().scaledToFit().frame(width: 72)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Switch the G-RAID to Protected?").font(.title2.weight(.semibold))
                        Text("To switch modes, the G-RAID starts over empty.").foregroundStyle(.secondary)
                    }
                }
                LossBar(tint: tint)
                HStack(spacing: 10) {
                    SpaceCard(label: "Now", symbol: "speedometer", mode: "Performance", detail: "RAID 0 · no copy",
                              fraction: 718.0 / 8001.0, usage: "718 GB used of 8.00 TB", usageColor: .primary)
                    Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                    SpaceCard(label: "After", symbol: "lock.shield", mode: "Protected", detail: "RAID 1 · copy on each disk",
                              fraction: 0, usage: "Empty · 4.00 TB free", usageColor: .secondary)
                }
                Text("You'll have half the space, but every file is kept on both disks, so the G-RAID keeps working if one of them fails.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                NextSteps()
                DisclosureGroup(isExpanded: .constant(false)) { EmptyView() } label: {
                    Text("Disks: 2 × HGST HUS724040ALE640").font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                HStack(spacing: 10) {
                    Text("Type **ERASE** to confirm").font(.callout)
                    TextField("", text: .constant(typed)).textFieldStyle(.roundedBorder).frame(width: 110)
                    Spacer()
                }
                HStack {
                    Button("Back") {}
                    Spacer()
                    Button("Cancel") {}
                    Button("Erase 718 GB and Switch") {}.buttonStyle(.borderedProminent).tint(.red).disabled(typed != "ERASE")
                }
            }
        }
    }
}

struct CombinedBoard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Erase confirmation · A + B").font(.title.weight(.semibold))
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 10) {
                    EraseCombined(tint: .red, typed: "")
                    Caption(title: "Red loss bar (recommended)", note: "Red is what macOS uses for data that can't come back, and it matches the red Erase button. The bar states the amount first, then that both disks and all 8.00 TB go.", width: 540)
                }
                VStack(alignment: .leading, spacing: 10) {
                    EraseCombined(tint: .orange, typed: "ERASE")
                    Caption(title: "Amber loss bar, ERASE typed", note: "Amber reads as caution rather than loss; it's what the Replace a Drive guide uses for its erase warning. Shown with ERASE typed, so the button is live.", width: 540)
                }
            }
        }
    }
}

// MARK: - Render

@MainActor func render<V: View>(_ view: V, _ name: String, dark: Bool, into dir: String) {
    let host = NSHostingView(rootView: view.padding(32).background(Color(nsColor: .underPageBackgroundColor)))
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path)")
}

@main
struct Render {
    @MainActor static func main() {
        _ = NSApplication.shared
        let dir = CommandLine.arguments[1]
        for dark in [false, true] {
            render(BannerBoard(), "banner", dark: dark, into: dir)
            render(EraseBoard(), "erase", dark: dark, into: dir)
            render(CombinedBoard(), "erase-combined", dark: dark, into: dir)
        }
    }
}
