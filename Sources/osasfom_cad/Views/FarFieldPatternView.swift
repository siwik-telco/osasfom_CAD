import SwiftUI
import osasfom_cadCore
import osasfom_cadSolver

/// The 1D radiation-pattern cuts: the two principal planes and a horizon cut.
///
/// Polar rather than cartesian because that is how an antenna pattern is
/// read — the angle on the page is the angle in space, so a lobe points where
/// it actually points.
struct FarFieldPatternView: View {
    let patterns: [FarFieldPattern]
    @Binding var frequencyIndex: Int
    @Binding var quantity: FarFieldQuantity
    /// The elevation the third cut is taken at. 90° is the horizon.
    @State private var thetaCutDegrees: Double = 90
    @State private var dynamicRangeDb: Double = 40

    private var pattern: FarFieldPattern? {
        guard !patterns.isEmpty else { return nil }
        return patterns.indices.contains(frequencyIndex) ? patterns[frequencyIndex] : patterns[0]
    }

    var body: some View {
        if let pattern {
            VStack(alignment: .leading, spacing: 12) {
                controls(pattern)
                summary(pattern)
                cuts(pattern)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text("No radiation pattern").font(.headline)
                Text("Enable far-field recording in Simulation settings and run again. The pattern is accumulated during the run, so it can't be added to a finished one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private func controls(_ pattern: FarFieldPattern) -> some View {
        if patterns.count > 1 {
            Picker("Frequency", selection: $frequencyIndex) {
                ForEach(patterns.indices, id: \.self) { index in
                    Text(FrequencyFormatter.string(hertz: patterns[index].hertz)).tag(index)
                }
            }
            .pickerStyle(.segmented)
        }

        Picker("Quantity", selection: $quantity) {
            ForEach(FarFieldQuantity.allCases) { option in
                Text(option.displayName)
                    .tag(option)
            }
        }
        .pickerStyle(.segmented)
        // Realized gain needs port data; offering it when it can't be formed
        // would just produce an empty plot.
        .onChange(of: quantity) { newValue in
            if !pattern.supports(newValue) { quantity = .directivity }
        }

        if !pattern.supports(.realizedGain) {
            Label(
                "Realized gain needs an excited port with usable voltage and current; only directivity is available for this run.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Summary

    private func summary(_ pattern: FarFieldPattern) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("Peak directivity").foregroundStyle(.secondary)
                Text(String(format: "%.2f dBi", pattern.peakDirectivityDbi))
            }
            if let gain = pattern.peakGainDbi {
                GridRow {
                    Text("Peak gain").foregroundStyle(.secondary)
                    Text(String(format: "%.2f dBi", gain))
                }
            }
            if let realized = pattern.peakRealizedGainDbi {
                GridRow {
                    Text("Realized gain").foregroundStyle(.secondary)
                    Text(String(format: "%.2f dBi", realized))
                }
            }
            if let efficiency = pattern.radiationEfficiency {
                GridRow {
                    Text("Radiation efficiency").foregroundStyle(.secondary)
                    Text(String(format: "%.1f%%", efficiency * 100))
                }
            }
            if let direction = pattern.peakDirection {
                GridRow {
                    Text("Boresight").foregroundStyle(.secondary)
                    Text(String(format: "θ %.0f°, φ %.0f°", direction.thetaDegrees, direction.phiDegrees))
                }
            }
        }
        .font(.callout)
    }

    // MARK: - Cuts

    private func cuts(_ pattern: FarFieldPattern) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("θ cut")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $thetaCutDegrees, in: 0...180, step: 5)
                Text("\(Int(thetaCutDegrees))°")
                    .font(.caption.monospacedDigit())
                    .frame(width: 34, alignment: .trailing)
            }

            ForEach(pattern.principalCuts(quantity: quantity, thetaCutDegrees: thetaCutDegrees)) { cut in
                PolarPlotView(cut: cut, dynamicRangeDb: dynamicRangeDb)
            }

            HStack {
                Text("Range")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $dynamicRangeDb, in: 10...60, step: 5)
                Text("\(Int(dynamicRangeDb)) dB")
                    .font(.caption.monospacedDigit())
                    .frame(width: 50, alignment: .trailing)
            }
        }
    }
}

/// One polar trace with its rings, labels and read-outs.
struct PolarPlotView: View {
    let cut: PatternCut
    let dynamicRangeDb: Double

    private var peak: Double { cut.peakDecibels }
    private var floor: Double { peak - dynamicRangeDb }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(cut.name).font(.callout.bold())
                if let conventional = cut.conventionalName {
                    Text(conventional)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let beamwidth = cut.halfPowerBeamwidthDegrees {
                    Text(String(format: "HPBW %.0f°", beamwidth))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let frontToBack = cut.frontToBackDb {
                    Text(String(format: "F/B %.1f dB", frontToBack))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .frame(height: 220)
            .accessibilityLabel("\(cut.name) radiation pattern, peak \(Int(peak)) dB")
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let radius = min(size.width, size.height) / 2 - 18
        guard radius > 0 else { return }
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)

        // Rings every 10 dB down from the peak, so the grid means something
        // rather than being decorative.
        let ringStep = 10.0
        var ringDb = peak
        while ringDb > floor {
            let fraction = (ringDb - floor) / dynamicRangeDb
            let r = radius * CGFloat(fraction)
            context.stroke(
                Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)),
                with: .color(.secondary.opacity(0.25)),
                lineWidth: 0.5
            )
            context.draw(
                Text("\(Int(ringDb))").font(.system(size: 8)).foregroundColor(.secondary),
                at: CGPoint(x: centre.x + 8, y: centre.y - r)
            )
            ringDb -= ringStep
        }

        // Spokes every 30°.
        for degrees in stride(from: 0, to: 360, by: 30) {
            // CGFloat, not Double: both `cos` overloads are visible here and the
            // arm64 slice rejects the mixed-type expression as ambiguous, even
            // though x86_64 resolves it happily.
            let angle = CGFloat(Angle(degrees: Double(degrees) - 90).radians)
            var spoke = Path()
            spoke.move(to: centre)
            spoke.addLine(to: CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle)))
            context.stroke(spoke, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)
        }

        // 0° at the top, angles increasing clockwise — the orientation an
        // antenna pattern is conventionally read in.
        var trace = Path()
        var started = false
        for point in cut.points {
            let fraction = max(0, (point.decibels - floor) / dynamicRangeDb)
            let r = radius * CGFloat(fraction)
            let angle = CGFloat(Angle(degrees: point.angleDegrees - 90).radians)
            let position = CGPoint(x: centre.x + r * cos(angle), y: centre.y + r * sin(angle))
            if started {
                trace.addLine(to: position)
            } else {
                trace.move(to: position)
                started = true
            }
        }
        context.stroke(trace, with: .color(.accentColor), lineWidth: 1.8)

        for (label, degrees) in [("0°", 0.0), ("90°", 90.0), ("±180°", 180.0), ("-90°", 270.0)] {
            let angle = CGFloat(Angle(degrees: degrees - 90).radians)
            context.draw(
                Text(label).font(.system(size: 9)).foregroundColor(.secondary),
                at: CGPoint(x: centre.x + (radius + 12) * cos(angle), y: centre.y + (radius + 12) * sin(angle))
            )
        }
    }
}
