// Mockup: replacing the old Configurator's status and lock pictures with SF Symbols.
// swiftc -parse-as-library mockups/SymbolOptions.swift -o build/mock/symbols && build/mock/symbols build/mock
import AppKit
import SwiftUI

let brandBlue = Color(red: 0.0, green: 0.56, blue: 0.80)

func old(_ name: String) -> Image? {
    NSImage(contentsOfFile: "Resources/\(name).png").map { Image(nsImage: $0) }
}

struct Caption: View {
    let title: String
    let note: String
    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.caption.weight(.semibold))
            Text(note).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(width: 200)
    }
}

/// Drive with a small lock in the corner, built from two system symbols.
struct DriveLock: View {
    var body: some View {
        Image(systemName: "externaldrive.fill").font(.system(size: 54)).foregroundStyle(.secondary)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "lock.circle.fill").font(.system(size: 30))
                    .symbolRenderingMode(.palette).foregroundStyle(.white, brandBlue)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-2))
                    .offset(x: 10, y: 8)
            }
            .frame(height: 72)
    }
}

/// The old pictures' idea (a gauge with a status shield) rebuilt from two system symbols.
struct GaugeBadge: View {
    let badge: String
    let color: Color
    let size: CGFloat
    var body: some View {
        Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: size)).foregroundStyle(brandBlue)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: badge).font(.system(size: size * 0.55))
                    .symbolRenderingMode(.palette).foregroundStyle(.white, color)
                    .background(Circle().fill(Color(nsColor: .controlBackgroundColor)).padding(-1))
                    .offset(x: size * 0.18, y: size * 0.12)
            }
    }
}

struct AccessCard<Icon: View>: View {
    let icon: Icon
    var body: some View {
        VStack(spacing: 10) {
            icon
            Text("Allow access to the G-RAID").font(.headline)
            Text("Needs an administrator password.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 200, height: 170)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

struct EraseHeader<Icon: View>: View {
    let icon: Icon
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Erase everything?").font(.headline)
                Text("Deletes all data on both disks.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 200, height: 76, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

struct StatusSet: View {
    let images: [AnyView]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 10) {
                    images[i].frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(["Healthy", "Degraded", "Broken"][i]).font(.callout.weight(.semibold))
                        Text(["Both disks working normally", "Check the disks in Array", "The volume can't be read"][i])
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 200, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

func sym(_ name: String, _ size: CGFloat, _ mode: SymbolRenderingMode = .hierarchical, _ colors: [Color]) -> AnyView {
    var img = AnyView(Image(systemName: name).font(.system(size: size)).symbolRenderingMode(mode))
    switch colors.count {
    case 1: img = AnyView(Image(systemName: name).font(.system(size: size)).symbolRenderingMode(mode).foregroundStyle(colors[0]))
    case 2: img = AnyView(Image(systemName: name).font(.system(size: size)).symbolRenderingMode(mode).foregroundStyle(colors[0], colors[1]))
    default: break
    }
    return img
}

struct Sheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            section("Allow access screen (replaces Img_Authentication_Lock)") {
                column(old("Img_Authentication_Lock").map { AnyView(AccessCard(icon: $0.resizable().scaledToFit().frame(height: 72))) },
                       "Now", "The old Configurator's lock")
                column(AnyView(AccessCard(icon: sym("lock.shield.fill", 60, .hierarchical, [brandBlue]))), "A · lock.shield.fill", "Hierarchical, accent blue")
                column(AnyView(AccessCard(icon: sym("lock.circle.fill", 64, .palette, [.white, brandBlue]))), "B · lock.circle.fill", "Closest to the old round lock")
                column(AnyView(AccessCard(icon: DriveLock())), "C · drive + lock badge", "externaldrive.fill with lock.circle.fill")
            }
            section("Erase confirmation (replaces Img_RaidStatus_Bad)") {
                column(old("Img_RaidStatus_Bad").map { AnyView(EraseHeader(icon: $0.resizable().scaledToFit())) }, "Now", "The old gauge with a red shield")
                column(AnyView(EraseHeader(icon: sym("exclamationmark.triangle.fill", 36, .multicolor, []))), "A · exclamationmark.triangle.fill", "The standard macOS caution sign")
                column(AnyView(EraseHeader(icon: sym("externaldrive.fill.badge.xmark", 34, .palette, [.red, .secondary]))), "B · externaldrive.fill.badge.xmark", "Says what gets erased")
                column(AnyView(EraseHeader(icon: sym("xmark.octagon.fill", 38, .hierarchical, [.red]))), "C · xmark.octagon.fill", "Stop sign, strongest")
                column(AnyView(EraseHeader(icon: GaugeBadge(badge: "xmark.shield.fill", color: .red, size: 36))), "D · gauge + shield", "The old idea, from system symbols")
            }
            section("Status set (old Good / Attention / Bad pictures; only used in the confirmation now)") {
                column(old("Img_RaidStatus_Good").map { _ in AnyView(StatusSet(images: ["Good", "Attn", "Bad"].map { AnyView(old("Img_RaidStatus_\($0)")!.resizable().scaledToFit()) })) },
                       "Old pictures", "Gauge with a coloured shield")
                column(AnyView(StatusSet(images: [sym("checkmark.circle.fill", 26, .hierarchical, [.green]), sym("exclamationmark.triangle.fill", 24, .hierarchical, [.orange]), sym("xmark.octagon.fill", 26, .hierarchical, [.red])])),
                       "A · circle, triangle, octagon", "What the overview uses today")
                column(AnyView(StatusSet(images: [sym("externaldrive.fill.badge.checkmark", 24, .palette, [.green, .secondary]), sym("externaldrive.fill.badge.exclamationmark", 24, .palette, [.orange, .secondary]), sym("externaldrive.fill.badge.xmark", 24, .palette, [.red, .secondary])])),
                       "B · drive with badge", "Ties status to the drive")
                column(AnyView(StatusSet(images: [sym("checkmark.shield.fill", 26, .hierarchical, [.green]), sym("exclamationmark.shield.fill", 26, .hierarchical, [.orange]), sym("xmark.shield.fill", 26, .hierarchical, [.red])])),
                       "C · shields", "Reads as protection")
                column(AnyView(StatusSet(images: [AnyView(GaugeBadge(badge: "checkmark.shield.fill", color: .green, size: 24)), AnyView(GaugeBadge(badge: "exclamationmark.shield.fill", color: .orange, size: 24)), AnyView(GaugeBadge(badge: "xmark.shield.fill", color: .red, size: 24))])),
                       "D · gauge + shield", "The old idea, from system symbols")
            }
        }
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) { content() }
        }
    }

    func column(_ view: AnyView?, _ title: String, _ note: String) -> some View {
        VStack(spacing: 8) {
            view ?? AnyView(Text("(not available)").frame(width: 200, height: 76))
            Caption(title: title, note: note)
        }
    }
}

@main
struct Render {
    @MainActor static func main() {
        _ = NSApplication.shared
        for dark in [false, true] {
            let host = NSHostingView(rootView: Sheet())
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(dark ? "symbols-dark.png" : "symbols-light.png")
            try! rep.representation(using: .png, properties: [:])!.write(to: url)
            print("wrote \(url.path)")
        }
    }
}
