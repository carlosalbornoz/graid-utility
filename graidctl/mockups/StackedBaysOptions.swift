// Mockups: the two bays stacked like the enclosure (Bay 2 on top, Bay 1 at the bottom).
// swiftc -parse-as-library mockups/StackedBaysOptions.swift -o build/mock/stacked && build/mock/stacked build/mock
import AppKit
import SwiftUI

let brandBlue = Color(red: 0.0, green: 0.56, blue: 0.80)

struct Drive {
    let bay: Int
    let vendor: String
    let model: String
    let serial: String
    let status: String
    let dot: Color
    let role: String
    var copy: Double? = nil       // receiving the copy: fraction done
}

let healthy = [Drive(bay: 2, vendor: "HGST", model: "HUS724040ALE640", serial: "PK1334PEHNVSSS", status: "Online", dot: .green, role: "Copy 2 of 2 · RAID 1"),
               Drive(bay: 1, vendor: "HGST", model: "HUS724040ALE640", serial: "PK1334PEHT4U9S", status: "Online", dot: .green, role: "Copy 1 of 2 · RAID 1")]
let rebuilding = [Drive(bay: 2, vendor: "HGST", model: "HUS724040ALE640", serial: "PK1334PEHNVSSS", status: "Receiving", dot: .orange, role: "", copy: 0.41),
                  Drive(bay: 1, vendor: "HGST", model: "HUS724040ALE640", serial: "PK1334PEHT4U9S", status: "Online", dot: .green, role: "Source · RAID 1")]

/// The soft band, as in the app.
struct Band: View {
    var body: some View {
        HStack(spacing: 0) { ForEach([0.18, 0.38, 0.6, 0.38, 0.18], id: \.self) { Rectangle().fill(Color.white.opacity($0)) } }
    }
}

/// One drive lying flat, front edge facing you: a sled with a latch on the right.
struct FlatSled: View {
    let d: Drive
    var width: CGFloat = 470
    var body: some View {
        let label = RoundedRectangle(cornerRadius: 6, style: .continuous)
        HStack(spacing: 0) {
            // The label: drive facts, or the copy's progress filling left to right.
            ZStack(alignment: .leading) {
                label.fill(Color(nsColor: .controlBackgroundColor))
                if let f = d.copy {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(brandBlue.opacity(0.13))
                            Band().frame(width: 40).offset(x: g.size.width * f * 0.55)
                        }
                        .frame(width: g.size.width * f)
                        .clipped()
                    }
                    .clipShape(label)
                }
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.vendor).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(d.model).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        Text(d.serial).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                    .frame(width: 130, alignment: .leading)
                    if let f = d.copy {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(Int(f * 100)) %").font(.system(size: 26, weight: .semibold)).monospacedDigit()
                            Text("1.64 of 4.00 TB · about 5 h left · 163 MB/s").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    } else {
                        Text("4 TB").font(.system(size: 26, weight: .semibold))
                        VStack(alignment: .leading, spacing: 2) {
                            // No dot: the bay number beside the drive is already coloured by status.
                            Text(d.status).font(.caption.weight(.medium)).foregroundStyle(d.dot == .green ? Color.primary : d.dot)
                            Text(d.role).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
            }
            .overlay(label.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            .padding(10)
            // The latch, like the real sled's handle.
            RoundedRectangle(cornerRadius: 2).strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.2)
                .frame(width: 10, height: 46).padding(.trailing, 12)
        }
        .frame(width: width, height: 96)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1.2))
    }
}

/// Vertical flow between the bays, from Bay 1 (bottom) up to Bay 2.
struct UpFlow: View {
    let t: Double
    var body: some View {
        ZStack(alignment: .bottom) {
            Capsule().fill(Color.secondary.opacity(0.2)).frame(width: 2)
            ForEach(0..<2, id: \.self) { i in
                let p = (t + Double(i) / 2).truncatingRemainder(dividingBy: 1)
                Circle().fill(brandBlue).frame(width: 4, height: 4).opacity(sin(p * .pi)).offset(y: -p * 14)
            }
        }
        .frame(width: 10, height: 18)
    }
}

/// A · Two flat sleds stacked, bay labels on the left, the volume named by a bracket.
struct OptionA: View {
    let drives: [Drive]
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Bracket naming the volume both drives form.
            HStack(spacing: 6) {
                Text("One 4.00 TB volume, mirrored").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    .fixedSize().rotationEffect(.degrees(-90)).frame(width: 18, height: 200)
                Path { p in p.move(to: CGPoint(x: 8, y: 0)); p.addLine(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 0, y: 200)); p.addLine(to: CGPoint(x: 8, y: 200)) }
                    .stroke(Color.secondary.opacity(0.5), lineWidth: 1).frame(width: 8, height: 200)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(drives.enumerated()), id: \.offset) { i, d in
                    HStack(spacing: 12) {
                        Text("Bay \(d.bay)").font(.headline).frame(width: 46, alignment: .leading)
                        FlatSled(d: d)
                    }
                    if i == 0 {
                        HStack { Spacer().frame(width: 58 + 230); if drives[0].copy != nil { UpFlow(t: 0.35) } else { Color.clear.frame(height: 18) } }
                            .frame(height: 18)
                    }
                }
            }
        }
        .padding(24)
    }
}

/// B · The enclosure's front drawn around the two bays, like looking at the G-RAID itself.
struct OptionB: View {
    let drives: [Drive]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One 4.00 TB volume, mirrored").font(.callout.weight(.medium)).foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.secondary.opacity(0.06))
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1.2)
                VStack(spacing: 0) {
                    ForEach(Array(drives.enumerated()), id: \.offset) { i, d in
                        HStack(spacing: 12) {
                            // The bay number, coloured by the drive's state.
                            Text("\(d.bay)").font(.caption.weight(.bold)).foregroundStyle(.white)
                                .frame(width: 22, height: 22).background(Circle().fill(d.dot))
                            FlatSled(d: d, width: 470)
                        }
                        if i == 0 {
                            // Gap between the drives; the copy flows up through it while rebuilding.
                            HStack { Spacer().frame(width: 34 + 235); if drives[0].copy != nil { UpFlow(t: 0.35) }; Spacer() }
                                .frame(height: 22)
                        }
                    }
                }
                .padding(18)
            }
            .fixedSize()
        }
        .padding(24)
    }
}

struct Board: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("Stacked bays, Bay 2 on top as on the enclosure").font(.title.weight(.semibold))
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("A · Stacked sleds (recommended)").font(.headline)
                    OptionA(drives: healthy).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    OptionA(drives: rebuilding).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("B · Inside the enclosure's front, revised").font(.headline)
                    OptionB(drives: healthy).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    OptionB(drives: rebuilding).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(32)
        .background(Color(nsColor: .underPageBackgroundColor))
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
        let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("stacked-bays.png")
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
        print("wrote \(url.path)")
    }
}
