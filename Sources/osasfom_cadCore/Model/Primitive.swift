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
    /// Absolute coordinates of the box's two faces on every axis, in the
    /// same frame as a body's position. Like a cylinder's `begin`/`end`,
    /// these are authoritative — a box has no axis a circular cross-section
    /// would leave centred on the body's position, so unlike a cylinder
    /// (one axis) or a sheet (its normal), a box's Position is unused on
    /// *all three* axes.
    public var beginX: Expression
    public var endX: Expression
    public var beginY: Expression
    public var endY: Expression
    public var beginZ: Expression
    public var endZ: Expression

    public init(
        beginX: Expression, endX: Expression,
        beginY: Expression, endY: Expression,
        beginZ: Expression, endZ: Expression
    ) {
        self.beginX = beginX
        self.endX = endX
        self.beginY = beginY
        self.endY = endY
        self.beginZ = beginZ
        self.endZ = endZ
    }

    /// Convenience for a box centred at local zero with the given extents —
    /// what `width/height/depth` used to mean before Position stopped being
    /// consulted for a box.
    public init(width: Expression, height: Expression, depth: Expression) {
        func half(_ e: Expression) -> Expression { Expression(source: "(\(e.trimmed)) / 2") }
        func negativeHalf(_ e: Expression) -> Expression { Expression(source: "-(\(e.trimmed)) / 2") }
        self.init(
            beginX: negativeHalf(width), endX: half(width),
            beginY: negativeHalf(height), endY: half(height),
            beginZ: negativeHalf(depth), endZ: half(depth)
        )
    }

    public func begin(_ axis: Axis) -> Expression {
        switch axis {
        case .x: return beginX
        case .y: return beginY
        case .z: return beginZ
        }
    }

    public func end(_ axis: Axis) -> Expression {
        switch axis {
        case .x: return endX
        case .y: return endY
        case .z: return endZ
        }
    }

    public mutating func setBegin(_ axis: Axis, _ value: Expression) {
        switch axis {
        case .x: beginX = value
        case .y: beginY = value
        case .z: beginZ = value
        }
    }

    public mutating func setEnd(_ axis: Axis, _ value: Expression) {
        switch axis {
        case .x: endX = value
        case .y: endY = value
        case .z: endZ = value
        }
    }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        transform(&beginX)
        transform(&endX)
        transform(&beginY)
        transform(&endY)
        transform(&beginZ)
        transform(&endZ)
    }
}

public struct CylinderSpec: Codable, Hashable, Sendable, ExpressionWalkable {
    public var radius: Expression
    /// Coordinate of the first terminal along `axis`, in the same absolute
    /// frame as a body's position. Unlike a box or sheet, a cylinder is not
    /// centred on its body's position along this axis — `begin`/`end` are
    /// authoritative, so a monopole can start exactly at a ground plane
    /// instead of being centred on it.
    public var begin: Expression
    /// Coordinate of the second terminal along `axis`.
    public var end: Expression
    /// Which way the cylinder points. The old model hard-coded Y, which made
    /// coax probes and monopoles awkward.
    public var axis: Axis

    public init(radius: Expression, begin: Expression, end: Expression, axis: Axis = .y) {
        self.radius = radius
        self.begin = begin
        self.end = end
        self.axis = axis
    }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        transform(&radius)
        transform(&begin)
        transform(&end)
    }
}

public struct SheetSpec: Codable, Hashable, Sendable, ExpressionWalkable {
    /// Extent along the first in-plane axis (`normal.perpendicular.0`). Still
    /// centred on the body's Position, same as before — a sheet's in-plane
    /// extents have no natural "start/end" the way its thickness does.
    public var width: Expression
    /// Extent along the second in-plane axis (`normal.perpendicular.1`).
    public var depth: Expression
    /// Absolute coordinate of the first face along `normal`, in the same
    /// frame as a body's position — like a cylinder's `begin`, authoritative
    /// on this one axis, so Position is unused along `normal`.
    public var begin: Expression
    /// Coordinate of the second face along `normal`. `begin == end` is
    /// legal and means an infinitely thin sheet.
    public var end: Expression
    public var normal: Axis

    public init(
        width: Expression,
        depth: Expression,
        begin: Expression,
        end: Expression,
        normal: Axis = .y
    ) {
        self.width = width
        self.depth = depth
        self.begin = begin
        self.end = end
        self.normal = normal
    }

    /// Convenience for a sheet centred at local zero along `normal` with the
    /// given thickness — what `thickness` used to mean before Position
    /// stopped being consulted along that one axis.
    public init(width: Expression, depth: Expression, thickness: Expression, normal: Axis = .y) {
        self.init(
            width: width,
            depth: depth,
            begin: Expression(source: "-(\(thickness.trimmed)) / 2"),
            end: Expression(source: "(\(thickness.trimmed)) / 2"),
            normal: normal
        )
    }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        transform(&width)
        transform(&depth)
        transform(&begin)
        transform(&end)
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
    /// the caller must not offer the edit. `bounds` is in the same absolute
    /// frame as `begin`/`end` (world/local, pre-rotation) — a box writes it
    /// directly into begin/end on every axis; a sheet writes its normal axis
    /// the same way and keeps `width`/`depth` (still Position-centred) as a
    /// plain size on the other two.
    public mutating func applyLocalExtents(_ bounds: BodyBounds) {
        switch self {
        case .box:
            updateBox { spec in
                for axis in Axis.allCases {
                    spec.setBegin(axis, Expression(bounds.minimum[axis]))
                    spec.setEnd(axis, Expression(bounds.maximum[axis]))
                }
            }
        case .sheet(let existing):
            let (first, second) = existing.normal.perpendicular
            let size = bounds.size
            updateSheet { spec in
                spec.width = Expression(size[first])
                spec.depth = Expression(size[second])
                spec.begin = Expression(bounds.minimum[existing.normal])
                spec.end = Expression(bounds.maximum[existing.normal])
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
        CylinderSpec(radius: Expression(2.5), begin: Expression(-15), end: Expression(15), axis: .y)
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
            // The box's in-plane extents (X/Z, centred at local 0 by
            // convention — see `defaultBox`) carry over as width/depth;
            // its Y extent becomes the sheet's normal-axis begin/end
            // directly, since both are already absolute on that axis.
            return .sheet(
                SheetSpec(
                    width: Expression(source: "(\(spec.endX.trimmed)) - (\(spec.beginX.trimmed))"),
                    depth: Expression(source: "(\(spec.endZ.trimmed)) - (\(spec.beginZ.trimmed))"),
                    begin: spec.beginY,
                    end: spec.endY,
                    normal: .y
                )
            )
        case (.sheet(let spec), .box):
            // The sheet's normal-axis begin/end carry over unchanged (both
            // absolute); its in-plane width/depth become a box extent
            // centred at local 0, matching how a fresh box is defined.
            let (first, second) = spec.normal.perpendicular
            var box = BoxSpec(width: spec.width, height: spec.width, depth: spec.width)
            box.setBegin(spec.normal, spec.begin)
            box.setEnd(spec.normal, spec.end)
            box.setBegin(first, Expression(source: "-(\(spec.width.trimmed)) / 2"))
            box.setEnd(first, Expression(source: "(\(spec.width.trimmed)) / 2"))
            box.setBegin(second, Expression(source: "-(\(spec.depth.trimmed)) / 2"))
            box.setEnd(second, Expression(source: "(\(spec.depth.trimmed)) / 2"))
            return .box(box)
        case (.box(let spec), .cylinder):
            // The box's Y extent (already absolute) becomes the cylinder's
            // begin/end directly.
            return .cylinder(
                CylinderSpec(
                    radius: Expression(source: "((\(spec.endX.trimmed)) - (\(spec.beginX.trimmed))) / 2"),
                    begin: spec.beginY,
                    end: spec.endY,
                    axis: .y
                )
            )
        case (.sheet(let spec), .cylinder):
            return .cylinder(
                CylinderSpec(
                    radius: Expression(source: "(\(spec.width.trimmed)) / 2"),
                    begin: spec.begin,
                    end: spec.end,
                    axis: spec.normal
                )
            )
        case (.cylinder(let spec), .box):
            let diameter = Expression(source: "2 * (\(spec.radius.trimmed))")
            let (first, second) = spec.axis.perpendicular
            var box = BoxSpec(width: diameter, height: diameter, depth: diameter)
            box.setBegin(spec.axis, spec.begin)
            box.setEnd(spec.axis, spec.end)
            box.setBegin(first, Expression(source: "-(\(diameter.trimmed)) / 2"))
            box.setEnd(first, Expression(source: "(\(diameter.trimmed)) / 2"))
            box.setBegin(second, Expression(source: "-(\(diameter.trimmed)) / 2"))
            box.setEnd(second, Expression(source: "(\(diameter.trimmed)) / 2"))
            return .box(box)
        case (.cylinder(let spec), .sheet):
            let diameter = Expression(source: "2 * (\(spec.radius.trimmed))")
            return .sheet(
                SheetSpec(width: diameter, depth: diameter, begin: spec.begin, end: spec.end, normal: spec.axis)
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
    /// `begin`/`end` are absolute coordinates along `axis`, in the same frame
    /// as a body's position — not an extent centred on it.
    case cylinder(radius: Double, begin: Double, end: Double, axis: Axis)
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
        case .cylinder(let radius, let begin, let end, let axis):
            var size = Vec3(repeating: radius * 2)
            size[axis] = abs(end - begin)
            return size
        }
    }

    /// A zero-extent axis, if any. Legal only for sheets.
    public var degenerateAxis: Axis? {
        Axis.allCases.first { localSize[$0] == 0 }
    }
}
