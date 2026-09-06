import Foundation

/// A renderable radiation pattern: a sphere deformed so each direction's
/// radius follows the pattern value in that direction.
///
/// Lives in Core, and carries a normalized 0…1 value per vertex rather than a
/// colour, so the solver can build the geometry without knowing anything
/// about the renderer and the renderer can pick the palette without knowing
/// anything about antennas.
public struct FarFieldMesh: Sendable {
    public struct Vertex: Sendable {
        public let position: Vec3
        /// 0 at the display floor, 1 at the peak — what the colour ramp reads.
        public let level: Double

        public init(position: Vec3, level: Double) {
            self.position = position
            self.level = level
        }
    }

    public let vertices: [Vertex]
    /// Triples of indices into `vertices`.
    public let indices: [Int]
    /// The dB window the levels were normalized against, for the legend.
    public let floorDb: Double
    public let peakDb: Double
    /// Longest radius in model units, so the caller can sanity-check scale.
    public let radius: Double

    public init(vertices: [Vertex], indices: [Int], floorDb: Double, peakDb: Double, radius: Double) {
        self.vertices = vertices
        self.indices = indices
        self.floorDb = floorDb
        self.peakDb = peakDb
        self.radius = radius
    }

    public var isEmpty: Bool { indices.isEmpty }

    /// Builds the deformed sphere from a θ/φ grid of dB values.
    ///
    /// `valueDb(thetaIndex, phiIndex)` supplies the pattern; everything else
    /// here is presentation. Values below `floorDb` collapse to the origin
    /// rather than going negative, which is what keeps a deep null looking
    /// like a pinch in the surface instead of turning it inside out.
    public static func make(
        thetaDegrees: [Double],
        phiDegrees: [Double],
        peakDb: Double,
        dynamicRangeDb: Double,
        radius: Double,
        valueDb: (Int, Int) -> Double
    ) -> FarFieldMesh {
        guard thetaDegrees.count >= 2, phiDegrees.count >= 3 else {
            return FarFieldMesh(vertices: [], indices: [], floorDb: 0, peakDb: 0, radius: 0)
        }
        let floorDb = peakDb - max(dynamicRangeDb, 1)
        let toRadians = Double.pi / 180

        var vertices: [Vertex] = []
        vertices.reserveCapacity(thetaDegrees.count * (phiDegrees.count + 1))

        // The φ ring is closed by repeating the first column, so the seam gets
        // its own vertices and the wrap doesn't stretch a triangle all the way
        // back around the sphere.
        let columnCount = phiDegrees.count + 1
        for (thetaIndex, theta) in thetaDegrees.enumerated() {
            for column in 0..<columnCount {
                let phiIndex = column % phiDegrees.count
                let phi = column == phiDegrees.count ? 360.0 : phiDegrees[phiIndex]

                let level = ((valueDb(thetaIndex, phiIndex) - floorDb) / (peakDb - floorDb)).clamped01
                let r = level * radius
                let t = theta * toRadians
                let p = phi * toRadians
                vertices.append(
                    Vertex(
                        position: Vec3(
                            x: r * sin(t) * cos(p),
                            y: r * sin(t) * sin(p),
                            z: r * cos(t)
                        ),
                        level: level
                    )
                )
            }
        }

        var indices: [Int] = []
        indices.reserveCapacity((thetaDegrees.count - 1) * phiDegrees.count * 6)
        for thetaIndex in 0..<(thetaDegrees.count - 1) {
            for column in 0..<phiDegrees.count {
                let a = thetaIndex * columnCount + column
                let b = a + 1
                let c = a + columnCount
                let d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }

        return FarFieldMesh(
            vertices: vertices,
            indices: indices,
            floorDb: floorDb,
            peakDb: peakDb,
            radius: radius
        )
    }
}

private extension Double {
    var clamped01: Double { Swift.min(Swift.max(self, 0), 1) }
}

/// The colour ramp a radiation pattern is drawn with.
///
/// Lives in Core so the 3D surface and the legend beside it read from one
/// definition — a legend that disagrees with the surface it explains is worse
/// than no legend.
public enum FarFieldColorRamp {

    /// Cold blue at the display floor, through cyan and green, into a long
    /// warm run that ends in deep blood red at the peak.
    ///
    /// The top third is deliberately all reds: on a radiation pattern the
    /// main lobe is the thing being looked for, so the eye should be able to
    /// find its hottest part and read how quickly it falls away, rather than
    /// having the whole upper range compressed into a single red step.
    public static let stops: [(level: Double, color: RGBAColor)] = [
        (0.00, RGBAColor(red: 0.08, green: 0.10, blue: 0.42)),
        (0.18, RGBAColor(red: 0.09, green: 0.45, blue: 0.82)),
        (0.34, RGBAColor(red: 0.13, green: 0.71, blue: 0.72)),
        (0.48, RGBAColor(red: 0.24, green: 0.76, blue: 0.33)),
        (0.60, RGBAColor(red: 0.85, green: 0.86, blue: 0.20)),
        (0.70, RGBAColor(red: 0.96, green: 0.62, blue: 0.10)),
        (0.80, RGBAColor(red: 0.93, green: 0.33, blue: 0.09)),
        (0.90, RGBAColor(red: 0.80, green: 0.08, blue: 0.08)),
        (1.00, RGBAColor(red: 0.44, green: 0.01, blue: 0.04))
    ]

    /// The colour at `level`, 0 at the floor and 1 at the peak.
    public static func color(level: Double) -> RGBAColor {
        let t = min(max(level, 0), 1)
        guard let first = stops.first, let last = stops.last else {
            return RGBAColor.neutralGray
        }
        if t <= first.level { return first.color }

        for index in 1..<stops.count where t <= stops[index].level {
            let low = stops[index - 1]
            let high = stops[index]
            let span = high.level - low.level
            let f = span > 0 ? (t - low.level) / span : 0
            return RGBAColor(
                red: low.color.red + (high.color.red - low.color.red) * f,
                green: low.color.green + (high.color.green - low.color.green) * f,
                blue: low.color.blue + (high.color.blue - low.color.blue) * f
            )
        }
        return last.color
    }
}
