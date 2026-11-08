// Mockups: three ways to show a RAID 1 rebuild once, with motion.
// swiftc -parse-as-library mockups/RebuildProgressOptions.swift -o build/mock/rebuild && build/mock/rebuild build/mock
// Writes numbered frames per option; tests/… use ffmpeg to turn them into GIFs.
import AppKit
import SwiftUI

let brandBlue = Color(red: 0.0, green: 0.56, blue: 0.80)
let drive = NSImage(contentsOfFile: "Resources/Img_Device_GRAID.png").map { Image(nsImage: $0) } ?? Image(systemName: "externaldrive.fill")

/// Live numbers as a real rebuild would give them (2026-11-08 run).
let fraction = 0.412
let timeLeft = "about 5 h 10 min left"
let speed = "163 MB/s"

// MARK: - Shared: a drive sled like the app's Array view

struct Sled<Content: View>: View {
    let title: String
    var highlighted = false
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(.headline)
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1.2)
                ForEach([CGPoint(x: 14, y: 14), CGPoint(x: 196, y: 14), CGPoint(x: 14, y: 286), CGPoint(x: 196, y: 286)], id: \.x.self) { _ in EmptyView() }
                content.padding(18)
            }
            .frame(width: 210, height: 300)
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1.2)
                    .frame(width: 70, height: 9).padding(.bottom, 12)
            }
        }
    }
}

struct DriveLabel: View {
    let brand: String
    let model: String
    let status: String
    let dot: Color
    let role: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(brand).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            Text(model).font(.caption.monospaced()).foregroundStyle(.secondary)
            Spacer()
            Text("4 TB").font(.system(size: 40, weight: .semibold))
            HStack(spacing: 6) { Circle().fill(dot).frame(width: 8, height: 8); Text(status).font(.callout) }
            Text(role).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatusRow: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
            Text(text).font(.title3.weight(.medium))
            Spacer()
        }
    }
}

// MARK: - A · The receiving drive fills up, data flows across

/// Dots travelling from the source bay to the receiving bay. `t` loops 0…1.
struct Flow: View {
    let t: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18)).frame(height: 2)
                ForEach(0..<4, id: \.self) { i in
                    let p = (t + Double(i) / 4).truncatingRemainder(dividingBy: 1)
                    Circle().fill(brandBlue)
                        .frame(width: 6, height: 6)
                        .opacity(sin(p * .pi))               // fade in at the source, out at the target
                        .offset(x: p * (g.size.width - 6))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 70, height: 20)
    }
}

struct OptionA: View {
    let t: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StatusRow(text: "Copying Bay 1 onto Bay 2")
            HStack(alignment: .center, spacing: 14) {
                Sled(title: "Bay 1") {
                    DriveLabel(brand: "HGST", model: "HUS724040ALE640", status: "Online", dot: .green, role: "Source")
                }
                Flow(t: t).padding(.top, 28)
                Sled(title: "Bay 2") {
                    ZStack(alignment: .bottom) {
                        // The fill: the sled itself is the progress bar, rising as the copy lands.
                        GeometryReader { g in
                            let h = g.size.height * fraction
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                Rectangle().fill(brandBlue)
                                    .frame(height: 2)
                                    .opacity(0.55 + 0.45 * (0.5 + 0.5 * sin(t * 2 * .pi)))   // the write front breathes
                                Rectangle().fill(brandBlue.opacity(0.12)).frame(height: h)
                            }
                        }
                        .padding(-18)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("HGST").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                            Text("HUS724040ALE640").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text("41 %").font(.system(size: 40, weight: .semibold)).monospacedDigit().padding(.top, 22)
                            Text("1.64 of 4.00 TB").font(.callout).monospacedDigit()
                            Text(timeLeft).font(.callout).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 600)
    }
}

// MARK: - B · A map of the disk being copied, block by block

struct SectorMap: View {
    let t: Double
    let cols = 40, rows = 8
    var body: some View {
        let total = cols * rows
        let done = Int(Double(total) * fraction)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: 3) {
                    ForEach(0..<cols, id: \.self) { c in
                        let i = r * cols + c
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(i < done ? brandBlue : (i == done ? brandBlue.opacity(0.25 + 0.6 * (0.5 + 0.5 * sin(t * 2 * .pi))) : Color.secondary.opacity(0.16)))
                            .frame(width: 10, height: 10)
                    }
                }
            }
        }
    }
}

struct OptionB: View {
    let t: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StatusRow(text: "Copying Bay 1 onto Bay 2")
            HStack(spacing: 14) {
                Sled(title: "Bay 1") {
                    DriveLabel(brand: "HGST", model: "HUS724040ALE640", status: "Online", dot: .green, role: "Source")
                }
                Image(systemName: "arrow.right").font(.title2.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 28)
                Sled(title: "Bay 2") {
                    DriveLabel(brand: "HGST", model: "HUS724040ALE640", status: "Receiving the copy", dot: .orange, role: "Copy 2 of 2")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectorMap(t: t)
                HStack {
                    Text("41 %").font(.headline).monospacedDigit()
                    Text("· 1.64 of 4.00 TB · \(speed)").foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Text(timeLeft).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(24)
        .frame(width: 600)
    }
}

// MARK: - C · A ring in the overview, the bays only name their roles

struct Ring: View {
    let t: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.16), lineWidth: 10)
            Circle().trim(from: 0, to: fraction)
                .stroke(brandBlue, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            // The leading end pulses: the copy is landing there right now.
            Circle().fill(brandBlue)
                .frame(width: 10 + 6 * (0.5 + 0.5 * sin(t * 2 * .pi)), height: 10 + 6 * (0.5 + 0.5 * sin(t * 2 * .pi)))
                .opacity(0.35)
                .offset(y: -70)
                .rotationEffect(.degrees(360 * fraction))
            VStack(spacing: 2) {
                Text("41 %").font(.system(size: 30, weight: .semibold)).monospacedDigit()
                Text("copied").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 140, height: 140)
    }
}

struct OptionC: View {
    let t: Double
    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                drive.resizable().scaledToFit().frame(width: 200)
                HStack(spacing: 16) {
                    Ring(t: t)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Rebuilding").font(.title3.weight(.semibold))
                        Text("Bay 1 → Bay 2").foregroundStyle(.secondary)
                        Text(timeLeft).foregroundStyle(.secondary)
                        Text(speed).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
            .frame(width: 330, alignment: .leading)
            HStack(spacing: 10) {
                Sled(title: "Bay 1") { DriveLabel(brand: "HGST", model: "HUS724040ALE640", status: "Online", dot: .green, role: "Source") }
                    .scaleEffect(0.8)
                Sled(title: "Bay 2") { DriveLabel(brand: "HGST", model: "HUS724040ALE640", status: "Receiving", dot: .orange, role: "Copy 2 of 2") }
                    .scaleEffect(0.8)
            }
            .frame(width: 380)
        }
        .padding(24)
        .frame(width: 780)
    }
}

// MARK: - Render

@MainActor func frame<V: View>(_ view: V, dark: Bool) -> NSBitmapImageRep {
    let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}

@main
struct Render {
    @MainActor static func main() {
        _ = NSApplication.shared
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let n = 36
        for (name, make) in [("A", { (t: Double) in AnyView(OptionA(t: t)) }),
                             ("B", { (t: Double) in AnyView(OptionB(t: t)) }),
                             ("C", { (t: Double) in AnyView(OptionC(t: t)) })] {
            let sub = dir.appendingPathComponent("rebuild-\(name)")
            try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            for i in 0..<n {
                let rep = frame(make(Double(i) / Double(n)), dark: false)
                try! rep.representation(using: .png, properties: [:])!.write(to: sub.appendingPathComponent(String(format: "f%03d.png", i)))
            }
            print("wrote \(sub.path)")
        }
    }
}
