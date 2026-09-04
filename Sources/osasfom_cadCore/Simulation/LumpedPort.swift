import Foundation

/// Geometry of a lumped-element FDTD port, fully resolved in project units.
///
/// A lumped port is a two-terminal device: a series voltage source and a
/// resistance `R` occupying the Yee edges that lie on the axis-aligned
/// segment from `begin` to `end`.
///
/// The solver uses that segment as follows:
/// - **Voltage** \(V = \int_{\mathrm{begin}}^{\mathrm{end}} \mathbf{E}\cdot d\mathbf{l}\)
///   along the gap (sum of edge voltages).
/// - **Current** \(I\) is the net current through a dual surface that cuts
///   those edges (sum of the dual-face currents).
/// - **Reference impedance** is `R` (typically 50 Ω). Incident and reflected
///   waves are \(a,b = (V \pm R I)/(2\sqrt{R})\); \(S_{11}=b/a\).
/// - **Resonance** is read from \(S_{11}(f)\) or \(Z_{\mathrm{in}}(f)=V/I\)
///   after a broadband pulse and a DFT — a dip in \(|S_{11}|\) (or a peak in
///   \(\mathrm{Re}\,Z_{\mathrm{in}}\)) marks the antenna resonance.
///
/// The segment **must be axis-aligned**. A Yee grid has no diagonal edges, so
/// a skewed feed cannot be stamped as a lumped element.
public struct LumpedPortGeometry: Hashable, Sendable {
    /// First terminal. Positive voltage is measured from here toward `end`.
    public let begin: Vec3
    /// Second terminal.
    public let end: Vec3
    /// Grid axis the gap lies on.
    public let direction: Axis
    /// True when `end[direction] < begin[direction]` — the reference direction
    /// is then −axis. The solver still integrates begin → end.
    public let polarityFlipped: Bool
    /// |end − begin| along `direction`.
    public let gapLength: Double
    /// Axis-aligned box of the two terminals (degenerate in the two
    /// perpendicular axes). A mesher snaps grid lines to these coordinates.
    public let bounds: BodyBounds

    public enum Failure: Equatable, Sendable {
        /// Begin and end evaluate to the same point.
        case coincidentTerminals
        /// The feed has a component on more than one axis.
        case notAxisAligned
    }

    /// Builds geometry from two resolved terminals, or explains why the feed
    /// cannot sit on a Yee edge.
    public static func from(
        begin: Vec3,
        end: Vec3,
        alignmentToleranceFraction: Double = 1e-6
    ) -> Result<LumpedPortGeometry, Failure> {
        guard begin.isFinite, end.isFinite else {
            return .failure(.coincidentTerminals)
        }

        let delta = end - begin
        let absX = abs(delta.x)
        let absY = abs(delta.y)
        let absZ = abs(delta.z)
        let gap = max(absX, max(absY, absZ))
        guard gap > 0 else { return .failure(.coincidentTerminals) }

        let tolerance = max(gap * alignmentToleranceFraction, 1e-15)
        var axes: [Axis] = []
        if absX > tolerance { axes.append(.x) }
        if absY > tolerance { axes.append(.y) }
        if absZ > tolerance { axes.append(.z) }
        guard axes.count == 1, let direction = axes.first else {
            return .failure(.notAxisAligned)
        }

        guard let bounds = BodyBounds.enclosing(points: [begin, end]) else {
            return .failure(.coincidentTerminals)
        }

        return .success(
            LumpedPortGeometry(
                begin: begin,
                end: end,
                direction: direction,
                polarityFlipped: delta[direction] < 0,
                gapLength: gap,
                bounds: bounds
            )
        )
    }
}
