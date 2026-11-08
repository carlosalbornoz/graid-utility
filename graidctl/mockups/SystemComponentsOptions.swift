// Mockups: each custom component next to the system one that could replace it.
// swiftc -parse-as-library mockups/SystemComponentsOptions.swift -o build/mock/system && build/mock/system build/mock
import AppKit
import Charts
import SwiftUI

let brandBlue = Color(red: 0.0, green: 0.56, blue: 0.80)

// MARK: - Shared bits

struct Pair<A: View, B: View>: View {
    let title: String
    let note: String
    @ViewBuilder let current: A
    @ViewBuilder let system: B
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 900, alignment: .leading)
            HStack(alignment: .top, spacing: 20) {
                Panel(label: "Now (custom)") { current }
                Panel(label: "System") { system }
            }
        }
    }
}

struct Panel<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(16)
        .frame(width: 440, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

// MARK: - 1. Capacity bar

struct Meter: View {   // copied from MainUI.swift
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(brandBlue).frame(width: max(6, g.size.width * fraction))
            }
        }
        .frame(height: 6)
    }
}

struct VolumeHeader: View {
    var body: some View {
        Label("G-RAID", systemImage: "externaldrive").font(.callout.weight(.medium))
    }
}
let usedText = "718.0 GB used of 4.00 TB"

// MARK: - 2. Speed results chart

let speeds: [(String, Double)] = [("Write", 285), ("Read", 306)]

struct CurrentSpeedChart: View {   // simplified from MainUI.swift's SpeedChart, same look
    let rows: [(String, Double)]
    let scaleMax = 400.0
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows, id: \.0) { Text($0.0).font(.callout).foregroundStyle(.secondary).frame(height: 22) }
                }.frame(width: 44, alignment: .leading)
                GeometryReader { g in
                    ZStack(alignment: .topLeading) {
                        ForEach([0.0, 100, 200, 300, 400], id: \.self) { t in
                            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1, height: 50)
                                .offset(x: min(g.size.width - 1, g.size.width * t / scaleMax))
                        }
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(brandBlue)
                                .frame(width: g.size.width * r.1 / scaleMax, height: 10)
                                .offset(y: CGFloat(i) * 28 + 6)
                        }
                    }
                }.frame(height: 50)
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(rows, id: \.0) { Text("\(Int($0.1)) MB/s").font(.callout.weight(.semibold)).monospacedDigit().frame(height: 22) }
                }.frame(width: 76, alignment: .trailing)
            }
            HStack(spacing: 12) {
                Color.clear.frame(width: 44, height: 1)
                GeometryReader { g in
                    ForEach([0.0, 100, 200, 300, 400], id: \.self) { t in
                        Text("\(Int(t))").font(.caption2).foregroundStyle(.tertiary).fixedSize().position(x: g.size.width * t / scaleMax, y: 6)
                    }
                }.frame(height: 12)
                Text("MB/s").font(.caption2).foregroundStyle(.tertiary).frame(width: 76, alignment: .trailing)
            }
        }
    }
}

struct SystemSpeedChart: View {
    let rows: [(String, Double)]
    var body: some View {
        Chart(rows, id: \.0) { r in
            BarMark(x: .value("MB/s", r.1), y: .value("Test", r.0), height: .fixed(12))
                .foregroundStyle(brandBlue)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .annotation(position: .trailing, spacing: 6) {
                    Text("\(Int(r.1)) MB/s").font(.callout.weight(.semibold)).monospacedDigit()
                }
        }
        .chartXScale(domain: 0...400)
        .chartXAxis {
            AxisMarks(values: [0, 100, 200, 300, 400]) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisValueLabel().font(.callout)
            }
        }
        .padding(.trailing, 14)
        .frame(height: 96)
    }
}

// MARK: - 3. Speed test live graph

struct Sample: Identifiable { let id: Int; let at: Double; let mbps: Double }
let samples: [Sample] = {
    var out: [Sample] = []
    let values: [Double] = [180, 260, 292, 288, 301, 279, 296, 284, 270, 290, 299, 286, 281, 294, 288, 276, 290, 297, 283, 289]
    for (i, v) in values.enumerated() { out.append(Sample(id: i, at: Double(i + 1) / Double(values.count), mbps: v)) }
    return out
}()
let average = 285.0

struct CurrentTrace: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary.opacity(0.6))
                Path { p in
                    var x0 = 0.0
                    for s in samples {
                        let height = h * s.mbps / 400
                        p.addRect(CGRect(x: w * x0, y: h - height, width: w * (s.at - x0), height: height))
                        x0 = s.at
                    }
                }
                .fill(brandBlue)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Rectangle().fill(Color.primary.opacity(0.55)).frame(width: w, height: 1).offset(y: -(h * average / 400))
            }
        }
        .frame(height: 46)
    }
}

struct SystemTrace: View {
    var body: some View {
        Chart {
            ForEach(samples) { s in
                AreaMark(x: .value("Written", s.at), y: .value("MB/s", s.mbps))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(brandBlue)
            }
            RuleMark(y: .value("Average", average))
                .foregroundStyle(Color.primary.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
        .chartXScale(domain: 0...1)
        .chartYScale(domain: 0...400)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 200, 400]) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .frame(height: 60)
    }
}

struct LaneHeader: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Write").font(.headline)
            Text("average").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("285").font(.system(size: 22, weight: .semibold)).monospacedDigit()
            Text("MB/s").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 4. Rebuilding bays: dots between the bays, or none

struct MiniBay: View {
    let bay: Int
    let model: String
    var copy: Double? = nil
    var body: some View {
        HStack(spacing: 12) {
            Text("\(bay)").font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Circle().fill(copy == nil ? Color.green : Color.orange))
            VStack(alignment: .leading, spacing: 3) {
                if let copy {
                    Text("\(Int(copy * 100)) %").font(.system(size: 20, weight: .semibold)).monospacedDigit()
                    ProgressView(value: copy).controlSize(.small)
                } else {
                    Text("4 TB").font(.system(size: 20, weight: .semibold))
                    Text("Online · Copy 1 of 2").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text(model).font(.caption2.monospaced()).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1.25))
    }
}

struct Dots: View {   // VerticalFlow, frozen mid-cycle
    var body: some View {
        ZStack {
            Capsule().fill(Color.secondary.opacity(0.2)).frame(width: 2, height: 18)
            Circle().fill(brandBlue).frame(width: 4, height: 4).offset(y: -4)
            Circle().fill(brandBlue.opacity(0.5)).frame(width: 4, height: 4).offset(y: 5)
        }
        .frame(height: 18)
    }
}

struct Bays: View {
    let dots: Bool
    var body: some View {
        VStack(spacing: 0) {
            MiniBay(bay: 2, model: "HUS724040ALE640", copy: 0.41)
            if dots { Dots() } else { Color.clear.frame(height: 12) }
            MiniBay(bay: 1, model: "HUS724040ALE640")
        }
    }
}

// MARK: - 5. Refreshing indicator

struct Toolbarish<Icon: View>: View {
    @ViewBuilder let icon: Icon
    var body: some View {
        HStack(spacing: 6) { icon; Text("Refreshing").font(.callout) }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(.quaternary.opacity(0.5)))
    }
}

// MARK: - 6. Text formatting

func formatBytes(_ b: Double) -> String { b >= 1e12 ? String(format: "%.2f TB", b / 1e12) : String(format: "%.1f GB", b / 1e9) }
func percentText(_ f: Double) -> String { let p = f * 100; return p < 10 ? String(format: "%.1f %%", p) : String(format: "%.0f %%", p.rounded(.down)) }
func durationText(_ t: TimeInterval) -> String {
    let hours = t / 3600
    if hours >= 1.5 { return "\(Int(hours.rounded())) hours" }
    if hours >= 0.75 { return "1 hour" }
    return "\(max(1, Int((t / 60).rounded()))) minutes"
}
func speedText(_ bps: Double) -> String { String(format: "%.0f MB/s", bps / 1e6) }

func systemBytes(_ b: Double) -> String { Int64(b).formatted(.byteCount(style: .file)) }
func systemPercent(_ f: Double) -> String { f.formatted(.percent.precision(.fractionLength(f < 0.1 ? 1 : 0))) }
func systemDuration(_ t: TimeInterval) -> String {
    let f = DateComponentsFormatter()
    f.unitsStyle = .full
    f.maximumUnitCount = 1
    f.includesApproximationPhrase = true
    f.allowedUnits = [.hour, .minute]
    return f.string(from: t) ?? ""
}
func systemSpeed(_ bps: Double) -> String {
    Measurement(value: bps / 1e6, unit: UnitInformationStorage.megabytes).formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0)))) + "/s"
}

struct FormatTable: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            GridRow {
                Text("Value").foregroundStyle(.secondary)
                Text("Now").foregroundStyle(.secondary)
                Text("System").foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
            Divider().gridCellUnsizedAxes(.horizontal)
            row("718 GB used", formatBytes(717.8e9), systemBytes(717.8e9))
            row("4 TB volume", formatBytes(4_000_728_481_792), systemBytes(4_000_728_481_792))
            row("Rebuild 0.55 %", percentText(0.0055), systemPercent(0.0055))
            row("Rebuild 41 %", percentText(0.412), systemPercent(0.412))
            row("4.6 hours left", "about " + durationText(4.6 * 3600), systemDuration(4.6 * 3600))
            row("40 minutes left", "about " + durationText(40 * 60), systemDuration(40 * 60))
            row("Speed", speedText(163e6), systemSpeed(163e6))
        }
        .font(.callout)
        .frame(width: 900, alignment: .leading)
    }
    private func row(_ what: String, _ now: String, _ sys: String) -> some View {
        GridRow {
            Text(what)
            Text(now).monospacedDigit()
            Text(sys).monospacedDigit().foregroundStyle(now == sys ? .secondary : .primary)
        }
    }
}

// MARK: - Board

struct Board: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            Text("Custom components vs system ones").font(.largeTitle.weight(.semibold))

            Pair(title: "1 · Capacity bar (overview)",
                 note: "Gauge with the linear-capacity style is the system's \"used of total\" bar. It sizes and colours itself; the tint keeps the brand blue.") {
                VStack(alignment: .leading, spacing: 7) { VolumeHeader(); Meter(fraction: 0.18); Text(usedText).font(.caption).foregroundStyle(.secondary) }
            } system: {
                VStack(alignment: .leading, spacing: 7) {
                    VolumeHeader()
                    Gauge(value: 0.18) { EmptyView() }.gaugeStyle(.linearCapacity).tint(brandBlue)
                    Text(usedText).font(.caption).foregroundStyle(.secondary)
                }
            }

            Pair(title: "2 · Last speed test (Activity)",
                 note: "Swift Charts draws the axis, grid and labels itself and reads the bars out to VoiceOver. The look stays close to today's.") {
                CurrentSpeedChart(rows: speeds)
            } system: {
                SystemSpeedChart(rows: speeds)
            }

            Pair(title: "3 · Speed test live graph (optional)",
                 note: "The stepped area and the average line as a chart. Today's version works; this mainly gains a speed scale on the side.") {
                VStack(alignment: .leading, spacing: 6) { LaneHeader(); CurrentTrace() }
            } system: {
                VStack(alignment: .leading, spacing: 6) { LaneHeader(); SystemTrace() }
            }

            Pair(title: "4 · Rebuilding: dots between the bays",
                 note: "No system version exists. Proposal: remove the dots (the progress bar already shows the copy moving). Shown with the new system progress bar.") {
                Bays(dots: true)
            } system: {
                Bays(dots: false)
            }

            Pair(title: "5 · Refreshing indicator (toolbar)",
                 note: "The standard small spinner instead of a turning arrow. Motion can't be seen in a still; the spinner is the one used on the \"Looking for a G-RAID…\" screen.") {
                Toolbarish { Image(systemName: "arrow.clockwise").font(.callout) }
            } system: {
                Toolbarish { ProgressView().controlSize(.small).frame(width: 16, height: 16) }
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("6 · Numbers and times").font(.title3.weight(.semibold))
                    Text("The system formatters follow the Mac's language and region. Real output from this Mac below; differences in black.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                FormatTable()
                    .padding(16)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(32)
        .background(Color(nsColor: .underPageBackgroundColor))
        .environment(\.controlActiveState, .key)
    }
}

@main
struct Render {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: Board())
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame.offsetBy(dx: -10000, dy: -10000), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("system-components.png")
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
        print("wrote \(url.path)")
    }
}
