import Charts
import SwiftUI
import osasfom_cadCore
import osasfom_cadSolver

/// Overlays the S11 traces of several runs on one chart, labelled by what
/// actually differs between them, with click-to-place markers.
struct RunComparisonChart: View {
    let runs: [RunRecord]
    @Binding var markers: [Double]

    private var labels: [Int: String] { RunComparison.labels(for: runs) }

    private var domain: S11PlotDomain {
        // One domain across every visible trace, or the curves would be drawn
        // to different scales and look comparable when they are not.
        S11PlotDomain(runs.flatMap(\.s11Spectrum))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            chart
            if !markers.isEmpty { markerTable }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(runs) { run in
                ForEach(run.s11Spectrum, id: \.hertz) { point in
                    LineMark(
                        x: .value("Frequency", point.hertz / 1e9),
                        y: .value("S11", point.decibels)
                    )
                    .foregroundStyle(by: .value("Run", labels[run.id] ?? "#\(run.id)"))
                }
            }
            ForEach(markers, id: \.self) { marker in
                RuleMark(x: .value("Marker", marker / 1e9))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.secondary)
            }
        }
        .chartXScale(domain: domain.frequencyGHz)
        .chartYScale(domain: domain.decibels)
        .chartXAxisLabel("GHz")
        .chartYAxisLabel("dB")
        .chartLegend(position: .bottom, alignment: .leading, spacing: 6)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        addMarker(at: location, proxy: proxy, geometry: geometry)
                    }
            }
        }
        .frame(height: 230)
    }

    /// Click-to-place: the x position under the pointer becomes a marker
    /// frequency, which every visible trace is then read at.
    private func addMarker(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        // `plotFrame` is macOS 14; the deployment target is 13, so the plot
        // area is located through the deprecated anchor instead.
        let x = location.x - geometry[proxy.plotAreaFrame].origin.x
        guard let ghz: Double = proxy.value(atX: x) else { return }
        let hertz = ghz * 1e9
        guard domain.frequencyGHz.contains(ghz) else { return }
        // Snapping avoids a pile of near-identical markers from imprecise clicks.
        guard !markers.contains(where: { abs($0 - hertz) < 1e6 }) else { return }
        markers = (markers + [hertz]).sorted()
    }

    // MARK: - Marker read-out

    private var markerTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Markers").font(.caption.bold())
                Spacer()
                Button("Clear") { markers = [] }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }

            ForEach(markers, id: \.self) { marker in
                HStack(alignment: .top, spacing: 8) {
                    Text(FrequencyFormatter.string(hertz: marker))
                        .font(.caption.monospacedDigit().bold())
                        .frame(width: 78, alignment: .leading)

                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(runs) { run in
                            HStack(spacing: 6) {
                                Text(labels[run.id] ?? "#\(run.id)")
                                    .foregroundStyle(.secondary)
                                Text(Self.readingText(run, atHertz: marker))
                                    .monospacedDigit()
                            }
                            .font(.caption)
                        }
                    }

                    Spacer(minLength: 0)

                    Button {
                        markers.removeAll { $0 == marker }
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Linear interpolation between the two sampled points either side, so a
    /// marker reads the curve rather than the nearest sample.
    static func reading(_ run: RunRecord, atHertz hertz: Double) -> Double? {
        let points = run.s11Spectrum
        guard let first = points.first, let last = points.last, points.count > 1 else {
            return points.first?.decibels
        }
        guard hertz >= first.hertz, hertz <= last.hertz else { return nil }

        for index in 1..<points.count where points[index].hertz >= hertz {
            let low = points[index - 1], high = points[index]
            let span = high.hertz - low.hertz
            guard span > 0 else { return low.decibels }
            let f = (hertz - low.hertz) / span
            return low.decibels + (high.decibels - low.decibels) * f
        }
        return last.decibels
    }

    private static func readingText(_ run: RunRecord, atHertz hertz: Double) -> String {
        guard let value = reading(run, atHertz: hertz) else { return "—" }
        return String(format: "%.2f dB", value)
    }
}

/// The same overlay idea for the radiation-pattern cuts: one polar plot per
/// plane, with one trace per selected run.
struct FarFieldComparisonView: View {
    let runs: [RunRecord]
    let quantity: FarFieldQuantity
    let thetaCutDegrees: Double
    let dynamicRangeDb: Double

    private var labels: [Int: String] { RunComparison.labels(for: runs) }

    /// Runs that actually recorded a pattern. A run without far field is not
    /// an error here — it simply has nothing to draw.
    private var comparable: [(run: RunRecord, pattern: FarFieldPattern)] {
        runs.compactMap { run in
            guard let pattern = run.farFieldPatterns.first else { return nil }
            return (run, pattern)
        }
    }

    var body: some View {
        if comparable.isEmpty {
            Text("None of the selected runs recorded a far field.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(planes.enumerated()), id: \.offset) { _, plane in
                    OverlaidPolarPlotView(
                        title: plane.title,
                        subtitle: plane.subtitle,
                        traces: comparable.map { entry in
                            OverlaidPolarPlotView.Trace(
                                name: labels[entry.run.id] ?? "#\(entry.run.id)",
                                cut: plane.cut(entry.pattern)
                            )
                        },
                        dynamicRangeDb: dynamicRangeDb
                    )
                }
            }
        }
    }

    private struct Plane {
        let title: String
        let subtitle: String?
        let cut: (FarFieldPattern) -> PatternCut
    }

    private var planes: [Plane] {
        let quantity = quantity
        let theta = thetaCutDegrees
        return [
            Plane(title: "φ = 0°", subtitle: "E-plane") { $0.cut(atPhiDegrees: 0, quantity: quantity) },
            Plane(title: "φ = 90°", subtitle: "H-plane") { $0.cut(atPhiDegrees: 90, quantity: quantity) },
            Plane(title: "θ = \(Int(theta))°", subtitle: theta == 90 ? "horizon" : nil) {
                $0.cut(atThetaDegrees: theta, quantity: quantity)
            }
        ]
    }
}

/// A polar plot carrying several traces at once.
struct OverlaidPolarPlotView: View {
    struct Trace {
        let name: String
        let cut: PatternCut
    }

    let title: String
    let subtitle: String?
    let traces: [Trace]
    let dynamicRangeDb: Double

    /// One shared peak across every trace, so the traces are drawn to the same
    /// scale — normalizing each to its own peak would hide the very difference
    /// the comparison exists to show.
    private var peak: Double { traces.map(\.cut.peakDecibels).max() ?? 0 }
    private var floor: Double { peak - dynamicRangeDb }

    private static let palette: [Color] = [.accentColor, .orange, .green, .purple, .pink, .teal]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.callout.bold())
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(alignment: .top, spacing: 10) {
                Canvas { context, size in draw(in: &context, size: size) }
                    .frame(width: 200, height: 200)

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(traces.enumerated()), id: \.offset) { index, trace in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Self.palette[index % Self.palette.count])
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(trace.name).font(.caption)
                                if let beamwidth = trace.cut.halfPowerBeamwidthDegrees {
                                    Text(String(format: "HPBW %.0f°", beamwidth))
                                        .font(.system(size: 9).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let radius = min(size.width, size.height) / 2 - 14
        guard radius > 0 else { return }
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)

        var ringDb = peak
        while ringDb > floor {
            let r = radius * ((ringDb - floor) / dynamicRangeDb)
            context.stroke(
                Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)),
                with: .color(.secondary.opacity(0.22)),
                lineWidth: 0.5
            )
            ringDb -= 10
        }
        for degrees in stride(from: 0, to: 360, by: 30) {
            let angle = Angle(degrees: Double(degrees) - 90).radians
            var spoke = Path()
            spoke.move(to: centre)
            spoke.addLine(to: CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle)))
            context.stroke(spoke, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
        }

        for (index, trace) in traces.enumerated() {
            var path = Path()
            var started = false
            for point in trace.cut.points {
                let r = radius * max(0, (point.decibels - floor) / dynamicRangeDb)
                let angle = Angle(degrees: point.angleDegrees - 90).radians
                let position = CGPoint(x: centre.x + r * cos(angle), y: centre.y + r * sin(angle))
                if started { path.addLine(to: position) } else { path.move(to: position); started = true }
            }
            context.stroke(path, with: .color(Self.palette[index % Self.palette.count]), lineWidth: 1.6)
        }
    }
}
