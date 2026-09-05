import Foundation

/// How a boolean tool combines with the body it belongs to.
public enum BooleanKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Union: the tool's volume becomes part of the body.
    case add
    /// Difference: the tool's volume is removed from the body.
    case subtract
    /// Intersection: only the volume the body and the tool share survives.
    case trim

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .add: return "Add"
        case .subtract: return "Subtract"
        case .trim: return "Trim"
        }
    }

    /// Spelled out in the UI because these words mean different things in
    /// different CAD packages — here "trim" is an intersection, not a
    /// surface cut.
    public var summary: String {
        switch self {
        case .add: return "Union — adds the tool's volume to this body."
        case .subtract: return "Difference — removes the tool's volume from this body."
        case .trim: return "Intersection — keeps only the volume both share."
        }
    }

    public var symbolName: String {
        switch self {
        case .add: return "plus.square"
        case .subtract: return "minus.square"
        case .trim: return "square.righthalf.filled"
        }
    }
}

/// One step of a body's boolean history: a *tool* shape combined into the
/// body with `kind`.
///
/// The tool is a full parametric primitive in its own right, specified in the
/// same absolute model frame as the body's own primitive — a box's begin/end
/// are already absolute coordinates, so a cut lands where the numbers say
/// rather than relative to the body's origin. That also means a tool does not
/// follow the parent body's rotation; it is placed, and rotated, on its own.
///
/// Steps apply strictly in list order, so a `subtract` followed by an `add`
/// can put material back inside a hole. There is deliberately no nesting: a
/// flat, ordered history covers the same ground and stays readable in the
/// inspector.
public struct BooleanOperation: Identifiable, Codable, Hashable, Sendable, ExpressionWalkable {
    public let id: UUID
    public var kind: BooleanKind
    public var primitive: Primitive
    public var transform: BodyTransform
    /// Kept in the list but skipped when evaluating — the CAD equivalent of
    /// commenting a step out, so trying something doesn't cost the numbers
    /// already typed into it.
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        kind: BooleanKind,
        primitive: Primitive,
        transform: BodyTransform = BodyTransform(),
        isEnabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.primitive = primitive
        self.transform = transform
        self.isEnabled = isEnabled
    }

    public var primitiveKind: PrimitiveKind { primitive.kind }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        primitive.walkExpressions(transform)
        self.transform.walkExpressions(transform)
    }

    public static func make(kind: BooleanKind, primitiveKind: PrimitiveKind) -> BooleanOperation {
        BooleanOperation(kind: kind, primitive: .makeDefault(primitiveKind))
    }

    // MARK: - Codable
    //
    // Hand-written on the decode side only, so `transform` and `isEnabled`
    // may be absent from a hand-edited file without failing the whole load.

    private enum CodingKeys: String, CodingKey {
        case id, kind, primitive, transform, isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.kind = try container.decode(BooleanKind.self, forKey: .kind)
        self.primitive = try container.decode(Primitive.self, forKey: .primitive)
        self.transform = try container.decodeIfPresent(BodyTransform.self, forKey: .transform) ?? BodyTransform()
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

/// A boolean step with every expression evaluated.
public struct ResolvedBooleanOperation: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let kind: BooleanKind
    public let shape: ResolvedShape
    public let position: Vec3
    public let rotationDegrees: Vec3
    public let scale: Vec3

    public init(
        id: UUID,
        kind: BooleanKind,
        shape: ResolvedShape,
        position: Vec3,
        rotationDegrees: Vec3,
        scale: Vec3
    ) {
        self.id = id
        self.kind = kind
        self.shape = shape
        self.position = position
        self.rotationDegrees = rotationDegrees
        self.scale = scale
    }

    public var rotationMatrix: Matrix3 { Matrix3.euler(degrees: rotationDegrees) }

    public var scaledSize: Vec3 {
        shape.localSize.scaled(by: Vec3(x: abs(scale.x), y: abs(scale.y), z: abs(scale.z)))
    }

    public var isAxisAligned: Bool {
        rotationDegrees.components.allSatisfy { abs($0.truncatingRemainder(dividingBy: 360)) < 1e-9 }
    }

    /// Same true-rotated-corners box a body computes, so a tool's edges can
    /// be snapped to by the mesher.
    public var axisAlignedBounds: BodyBounds {
        let halfExtent = scaledSize / 2
        guard !isAxisAligned else {
            return BodyBounds(center: position, size: scaledSize)
        }
        let matrix = rotationMatrix
        let corners = BodyBounds.corners(halfExtent: halfExtent).map { matrix.apply(to: $0) + position }
        return BodyBounds.enclosing(points: corners) ?? BodyBounds(center: position, size: .zero)
    }
}
