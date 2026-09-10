import AppKit
import osasfom_cadCore

extension NSColor {
    convenience init(_ color: RGBAColor) {
        self.init(
            srgbRed: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.alpha)
        )
    }
}

/// Viewport palette, in one place so the scene reads as a single design.
public enum SceneStyle {
    public static let background = NSColor(calibratedWhite: 0.08, alpha: 1.0)
    public static let selection = NSColor.systemYellow
    public static let grid = NSColor(calibratedWhite: 0.30, alpha: 1.0)
    public static let gridMajor = NSColor(calibratedWhite: 0.42, alpha: 1.0)
    public static let axisX = NSColor.systemRed
    public static let axisY = NSColor.systemGreen
    public static let axisZ = NSColor.systemBlue
    public static let domain = NSColor.systemTeal
    /// The Yee grid. A cool steel blue, deliberately unlike the teal domain
    /// box it sits inside and the neutral grey reference grid it crosses —
    /// three sets of lines in one viewport need to stay tellable apart.
    public static let simulationMesh = NSColor(calibratedRed: 0.45, green: 0.66, blue: 0.85, alpha: 1.0)
    public static let port = NSColor.systemPink
    /// A lumped port's first terminal (`begin`) — voltage is measured from
    /// here toward `end`, so begin/end get visually distinct colors.
    public static let portBegin = NSColor.systemRed
    public static let portEnd = NSColor.systemBlue
    public static let errorTint = NSColor.systemRed
}
