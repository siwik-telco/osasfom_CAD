import SwiftUI
import osasfom_cadCore

/// The colour scale for the 3D radiation pattern.
///
/// Reads its ramp from `FarFieldColorRamp`, the same definition the surface
/// itself is coloured from, so the legend cannot drift out of step with what
/// it is explaining.
struct FarFieldLegendView: View {
    let mesh: FarFieldMesh
    let unitLabel: String

    /// Peak at the top down to the display floor, which is the direction the
    /// numbers run on the bar.
    private var gradient: Gradient {
        Gradient(
            stops: FarFieldColorRamp.stops.reversed().map { stop in
                Gradient.Stop(color: Color(rgba: stop.color), location: 1 - stop.level)
            }
        )
    }

    /// Labelled every 10 dB where the range allows, so the ticks land on
    /// round numbers rather than wherever the range happens to divide.
    private var tickValues: [Double] {
        let span = mesh.peakDb - mesh.floorDb
        guard span > 0 else { return [mesh.peakDb] }
        let step = span > 45 ? 20.0 : (span > 18 ? 10.0 : 5.0)

        var values: [Double] = [mesh.peakDb]
        var value = (mesh.peakDb / step).rounded(.down) * step
        while value > mesh.floorDb {
            if mesh.peakDb - value > step * 0.4 { values.append(value) }
            value -= step
        }
        values.append(mesh.floorDb)
        return values
    }

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            LinearGradient(gradient: gradient, startPoint: .top, endPoint: .bottom)
                .frame(width: 12)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 0.5)
                )

            GeometryReader { geometry in
                ForEach(tickValues, id: \.self) { value in
                    let span = max(mesh.peakDb - mesh.floorDb, 1e-9)
                    let fraction = (mesh.peakDb - value) / span
                    Text(String(format: "%.0f", value))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .alignmentGuide(.top) { $0[.top] }
                        .position(
                            x: 14,
                            y: min(max(geometry.size.height * fraction, 6), geometry.size.height - 6)
                        )
                }
            }
            .frame(width: 30)
        }
        .frame(height: 110)
        .overlay(alignment: .bottomLeading) {
            Text(unitLabel)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .offset(y: 13)
        }
    }
}


extension Color {
    /// The project's own colour type as a SwiftUI colour. `NSColor` already
    /// has this conversion in the render module, which the app's views don't
    /// import.
    init(rgba: RGBAColor) {
        self.init(
            .sRGB,
            red: rgba.red,
            green: rgba.green,
            blue: rgba.blue,
            opacity: rgba.alpha
        )
    }
}
