import Foundation

public enum PrimitiveKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case box
    case cylinder
    case sheet

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .box: return "Box"
        case .cylinder: return "Cylinder"
        case .sheet: return "Sheet"
        }
    }

    public var symbolName: String {
        switch self {
        case .box: return "cube"
        case .cylinder: return "cylinder"
        case .sheet: return "square"
        }
    }
}

public struct BoxSpec: Codable, Hashable, Sendable, ExpressionWalkable {
    /// Extent along X.
    public var width: Expression
    /// Extent along Y.
    public var height: Expression
    /// Extent along Z.
    public var depth: Expression

    public init(width: Expression, height: Expression, depth: Expression) {
        self.width = width
        self.height = height
        self.depth = depth
    }

    public subscript(axis: Axis) -> Expression {
        get {
            switch axis {
            case .x: return width
            case .y: return height
            case .z: return depth
            }
        }
        set {
            switch axis {
            case .x: width = newValue
            case .y: height = newValue
            case .z: depth = newValue
            }
        }
    }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        transform(&width)
        transform(&height)
        transform(&depth)
    }
}

public struct CylinderSpec: Codable, Hashable, Sendable, ExpressionWalkable {
    public var radius: Expression
    /// Extent along `axis`.
    public var length: Expression
    /// Which way the cylinder points. The old model hard-coded Y, which made
    /// coax probes and monopoles awkward.
    public var axis: Axis

    public init(radius: Expression, length: Expression, axis: Axis = .y) {
        self.radius = radius
        self.length = length
        self.axis = axis
    }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        transform(&radius)
        transform(&length)
    }
}

public struct SheetSpec: Codable, Hashable, Sendable, ExpressionWalkable {
    /// Extent along the first in-plane axis (`normal.perpendicular.0`).
    public var width: Expression
    /// Extent along the second in-plane axis (`normal.perpendicular.1`).
    public var depth: Expression
    /// Extent along `normal`. Zero is legal and means an infinitely thin sheet.
    public var thickness: Expression
    public var normal: Axis

    public init(
        width: Expression,
        depth: Expression,
        thickness: Expression,
        normal: Axis = .y
    ) {
        self.width = width
        self.depth = depth
        self.thickness = thickness
        self.normal = normal
    }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        transform(&width)
        transform(&depth)
        transform(&thickness)
    }
}

/// A parametric primitive.
///
/// Modelled as an enum with associated values so a box cannot carry a
/// meaningless radius and switching kinds cannot reinterpret unrelated fields.
/// That removes the invalid states the old flat `PrimitiveParameters` allowed.
public enum Primitive: Hashable, Sendable, ExpressionWalkable {
    case box(BoxSpec)
    case cylinder(CylinderSpec)
    case sheet(SheetSpec)

    public var kind: PrimitiveKind {
        switch self {
        case .box: return .box
        case .cylinder: return .cylinder
        case .sheet: return .sheet
        }
    }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        switch self {
        case .box(var spec):
            spec.walkExpressions(transform)
            self = .box(spec)
        case .cylinder(var spec):
            spec.walkExpressions(transform)
            self = .cylinder(spec)
        case .sheet(var spec):
            spec.walkExpressions(transform)
            self = .sheet(spec)
        }
    }

    // MARK: - Case access
    //
    // Typed accessors so the inspector can build key-path bindings into a spec
    // without pattern-matching at every call site.

    public var boxSpec: BoxSpec? {
        if case .box(let spec) = self { return spec }
        return nil
    }

    public var cylinderSpec: CylinderSpec? {
        if case .cylinder(let spec) = self { return spec }
        return nil
    }

    public var sheetSpec: SheetSpec? {
        if case .sheet(let spec) = self { return spec }
        return nil
    }

    public mutating func updateBox(_ mutation: (inout BoxSpec) -> Void) {
        guard case .box(var spec) = self else { return }
        mutation(&spec)
        self = .box(spec)
    }

    public mutating func updateCylinder(_ mutation: (inout CylinderSpec) -> Void) {
        guard case .cylinder(var spec) = self else { return }
        mutation(&spec)
        self = .cylinder(spec)
    }

    public mutating func updateSheet(_ mutation: (inout SheetSpec) -> Void) {
        guard case .sheet(var spec) = self else { return }
        mutation(&spec)
        self = .sheet(spec)
    }

    /// Rewrites the primitive so its axis-aligned extents match `bounds`,
    /// replacing the affected expressions with literals.
    ///
    /// Only defined for boxes and sheets — a cylinder has no unique inverse, so
    /// the caller must not offer the edit. Returns the extents actually applied.
    public mutating func applyLocalExtents(_ size: Vec3) {
        switch self {
        case .box:
            updateBox { spec in
                spec.width = Expression(size.x)
                spec.height = Expression(size.y)
                spec.depth = Expression(size.z)
            }
        case .sheet(let existing):
            let (first, second) = existing.normal.perpendicular
            updateSheet { spec in
                spec.width = Expression(size[first])
                spec.depth = Expression(size[second])
                spec.thickness = Expression(size[existing.normal])
            }
        case .cylinder:
            break
        }
    }

    /// True when any extent is driven by a variable, so the UI can warn before
    /// an extent edit flattens it to a number.
    public var hasParametricExtents: Bool {
        var found = false
        var copy = self
        copy.walkExpressions { expression in
            if !expression.referencedVariableNames.isEmpty { found = true }
        }
        return found
    }

    // MARK: - Defaults

    public static let defaultBox = Primitive.box(
        BoxSpec(width: Expression(40), height: Expression(1.6), depth: Expression(30))
    )

    public static let defaultCylinder = Primitive.cylinder(
        CylinderSpec(radius: Expression(2.5), length: Expression(30), axis: .y)
    )

    public static let defaultSheet = Primitive.sheet(
        SheetSpec(
            width: Expression(60),
            depth: Expression(40),
            thickness: Expression(0),
            normal: .y
        )
    )

    public static func makeDefault(_ kind: PrimitiveKind) -> Primitive {
        switch kind {
        case .box: return defaultBox
        case .cylinder: return defaultCylinder
        case .sheet: return defaultSheet
        }
    }

    /// Converts between kinds, carrying over whatever is meaningful.
    ///
    /// Unlike the old `sanitize(for:)`, nothing is silently reinterpreted: the
    /// axis-aligned extents are preserved and the rest comes from defaults.
    public func converted(to kind: PrimitiveKind) -> Primitive {
        guard kind != self.kind else { return self }

        switch (self, kind) {
        case (.box(let spec), .sheet):
            return .sheet(
                SheetSpec(width: spec.width, depth: spec.depth, thickness: spec.height, normal: .y)
            )
        case (.sheet(let spec), .box):
            return .box(
                BoxSpec(width: spec.width, height: spec.thickness, depth: spec.depth)
            )
        case (.box(let spec), .cylinder):
            return .cylinder(
                CylinderSpec(radius: Expression(source: "(\(spec.width.trimmed)) / 2"), length: spec.height, axis: .y)
            )
        case (.sheet(let spec), .cylinder):
            return .cylinder(
                CylinderSpec(radius: Expression(source: "(\(spec.width.trimmed)) / 2"), length: spec.thickness, axis: spec.normal)
            )
        case (.cylinder(let spec), .box):
            let diameter = Expression(source: "2 * (\(spec.radius.trimmed))")
            let (first, second) = spec.axis.perpendicular
            var box = BoxSpec(width: diameter, height: diameter, depth: diameter)
            box[spec.axis] = spec.length
            box[first] = diameter
            box[second] = diameter
            return .box(box)
        case (.cylinder(let spec), .sheet):
            let diameter = Expression(source: "2 * (\(spec.radius.trimmed))")
            return .sheet(
                SheetSpec(width: diameter, depth: diameter, thickness: spec.length, normal: spec.axis)
            )
        default:
            return .makeDefault(kind)
        }
    }
}

// MARK: - Codable

/// Hand-written so the JSON is flat and stable:
/// `{"type": "box", "width": "patch_w", "height": "1.6", "depth": "patch_l"}`.
/// The synthesised form would emit `{"box": {"_0": …}}`, which is a poor
/// contract for a solver to read.
extension Primitive: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(PrimitiveKind.self, forKey: .type)
        switch kind {
        case .box:
            self = .box(try BoxSpec(from: decoder))
        case .cylinder:
            self = .cylinder(try CylinderSpec(from: decoder))
        case .sheet:
            self = .sheet(try SheetSpec(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
        switch self {
        case .box(let spec):
            try spec.encode(to: encoder)
        case .cylinder(let spec):
            try spec.encode(to: encoder)
        case .sheet(let spec):
            try spec.encode(to: encoder)
        }
    }
}

/// A primitive with every expression evaluated.
public enum ResolvedShape: Hashable, Sendable {
    case box(size: Vec3)
    case cylinder(radius: Double, length: Double, axis: Axis)
    case sheet(size: Vec3, normal: Axis)

    public var kind: PrimitiveKind {
        switch self {
        case .box: return .box
        case .cylinder: return .cylinder
        case .sheet: return .sheet
        }
    }

    /// Full local extents along X/Y/Z before scale and rotation. For a cylinder
    /// this is the enclosing box: diameter across, length along the axis.
    public var localSize: Vec3 {
        switch self {
        case .box(let size):
            return size
        case .sheet(let size, _):
            return size
        case .cylinder(let radius, let length, let axis):
            var size = Vec3(repeating: radius * 2)
            size[axis] = length
            return size
        }
    }

    /// A zero-extent axis, if any. Legal only for sheets.
    public var degenerateAxis: Axis? {
        Axis.allCases.first { localSize[$0] == 0 }
    }
}
