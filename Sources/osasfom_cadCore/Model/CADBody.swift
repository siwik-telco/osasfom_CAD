import Foundation

/// Placement of a body. Every component is parametric, so a patch can sit at
/// `x = -patch_w / 2` and follow its variable.
public struct BodyTransform: Codable, Hashable, Sendable, ExpressionWalkable {
    public var position: Vector3Expression
    public var rotationDegrees: Vector3Expression
    public var scale: Vector3Expression

    public init(
        position: Vector3Expression = .zero,
        rotationDegrees: Vector3Expression = .zero,
        scale: Vector3Expression = .one
    ) {
        self.position = position
        self.rotationDegrees = rotationDegrees
        self.scale = scale
    }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        position.walkExpressions(transform)
        rotationDegrees.walkExpressions(transform)
        scale.walkExpressions(transform)
    }
}

public struct CADBody: Identifiable, Codable, Hashable, Sendable, ExpressionWalkable {
    public let id: UUID
    public var name: String
    public var primitive: Primitive
    public var transform: BodyTransform
    /// `nil` resolves to `MaterialLibrary.defaultMaterialID` (vacuum).
    public var materialID: UUID?
    /// Overlap resolution for voxelisation: when two bodies claim the same cell,
    /// the higher priority wins. Ties break by later position in the body list.
    /// Making this explicit removes the old reliance on undocumented array order.
    public var priority: Int
    public var isVisible: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        primitive: Primitive,
        transform: BodyTransform = BodyTransform(),
        materialID: UUID? = nil,
        priority: Int = 0,
        isVisible: Bool = true
    ) {
        self.id = id
        self.name = name
        self.primitive = primitive
        self.transform = transform
        self.materialID = materialID
        self.priority = priority
        self.isVisible = isVisible
    }

    public var kind: PrimitiveKind { primitive.kind }

    public var effectiveMaterialID: UUID { materialID ?? MaterialLibrary.defaultMaterialID }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        primitive.walkExpressions(transform)
        self.transform.walkExpressions(transform)
    }

    /// A copy with a fresh identity.
    ///
    /// Written as a whole-value copy rather than field-by-field so adding a
    /// property can never silently fail to be duplicated.
    public func duplicated(named newName: String, offsetBy offset: Vec3 = .zero) -> CADBody {
        var copy = CADBody(
            id: UUID(),
            name: newName,
            primitive: primitive,
            transform: transform,
            materialID: materialID,
            priority: priority,
            isVisible: isVisible
        )
        guard offset != .zero else { return copy }
        copy.transform.position = Vector3Expression(
            x: Self.offsetting(transform.position.x, by: offset.x),
            y: Self.offsetting(transform.position.y, by: offset.y),
            z: Self.offsetting(transform.position.z, by: offset.z)
        )
        return copy
    }

    /// Adds a numeric offset without flattening the parametric source.
    private static func offsetting(_ expression: Expression, by delta: Double) -> Expression {
        guard delta != 0 else { return expression }
        if expression.isEmpty { return Expression(delta) }
        if let literal = try? expression.value(), expression.referencedVariableNames.isEmpty {
            return Expression(literal + delta)
        }
        let sign = delta < 0 ? "-" : "+"
        return Expression(source: "\(expression.trimmed) \(sign) \(Expression.literalSource(abs(delta)))")
    }

    public static func make(kind: PrimitiveKind, name: String) -> CADBody {
        CADBody(name: name, primitive: .makeDefault(kind))
    }
}

/// Whether the axis-aligned extent editor can write back to this body.
public enum BoundsEditability: Hashable, Sendable {
    case editable
    /// The displayed box is the true rotated bounding box, so writing to it has
    /// no well-defined inverse.
    case rotated
    /// A cylinder's radius cannot be recovered from two independent perpendicular
    /// spans without discarding one of them. The old code silently took the
    /// minimum; now the editor simply is not offered.
    case lossyForKind(PrimitiveKind)

    public var isEditable: Bool { self == .editable }

    public var explanation: String? {
        switch self {
        case .editable:
            return nil
        case .rotated:
            return "This body is rotated, so the box below is its true axis-aligned bounding box and is read-only. Clear the rotation to edit extents directly."
        case .lossyForKind(let kind):
            return "A \(kind.displayName.lowercased()) has no unique extent inverse, so the box below is read-only. Edit radius, length and axis instead."
        }
    }
}

/// A body with every expression evaluated. Derived state, never persisted.
public struct ResolvedBody: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let shape: ResolvedShape
    public let position: Vec3
    public let rotationDegrees: Vec3
    public let scale: Vec3
    public let materialID: UUID
    public let priority: Int
    public let isVisible: Bool
    /// Index in the document's body list, used as the tie-break for equal
    /// priorities.
    public let orderIndex: Int

    public init(
        id: UUID,
        name: String,
        shape: ResolvedShape,
        position: Vec3,
        rotationDegrees: Vec3,
        scale: Vec3,
        materialID: UUID,
        priority: Int,
        isVisible: Bool,
        orderIndex: Int
    ) {
        self.id = id
        self.name = name
        self.shape = shape
        self.position = position
        self.rotationDegrees = rotationDegrees
        self.scale = scale
        self.materialID = materialID
        self.priority = priority
        self.isVisible = isVisible
        self.orderIndex = orderIndex
    }

    /// True when the rotation is (numerically) a no-op.
    public var isAxisAligned: Bool {
        rotationDegrees.components.allSatisfy { abs($0.truncatingRemainder(dividingBy: 360)) < 1e-9 }
    }

    /// World-space extents after scale, ignoring rotation.
    public var scaledSize: Vec3 {
        shape.localSize.scaled(
            by: Vec3(x: abs(scale.x), y: abs(scale.y), z: abs(scale.z))
        )
    }

    public var rotationMatrix: Matrix3 { Matrix3.euler(degrees: rotationDegrees) }

    /// The *true* axis-aligned bounding box, computed from the rotated corners.
    ///
    /// The old implementation ignored rotation entirely, so a rotated body
    /// reported a box that did not contain it — and the extent editor then wrote
    /// back into that wrong box. This is what an FDTD mesher needs to bracket a
    /// body's cells.
    public var axisAlignedBounds: BodyBounds {
        let halfExtent = scaledSize / 2
        guard !isAxisAligned else {
            return BodyBounds(center: position, size: scaledSize)
        }
        let matrix = rotationMatrix
        let corners = BodyBounds.corners(halfExtent: halfExtent).map { corner in
            matrix.apply(to: corner) + position
        }
        return BodyBounds.enclosing(points: corners) ?? BodyBounds(center: position, size: .zero)
    }

    /// The unrotated local extent box centred on `position`. Meaningful as an
    /// editing surface only when `isAxisAligned`.
    public var localBounds: BodyBounds {
        BodyBounds(center: position, size: scaledSize)
    }

    public var boundsEditability: BoundsEditability {
        if !isAxisAligned { return .rotated }
        if shape.kind == .cylinder { return .lossyForKind(.cylinder) }
        return .editable
    }

    public var volume: Double {
        switch shape {
        case .box(let size):
            let scaled = size.scaled(by: scale)
            return abs(scaled.x * scaled.y * scaled.z)
        case .sheet(let size, _):
            let scaled = size.scaled(by: scale)
            return abs(scaled.x * scaled.y * scaled.z)
        case .cylinder(let radius, let length, let axis):
            let (first, second) = axis.perpendicular
            let radiusScale = (abs(scale[first]) + abs(scale[second])) / 2
            let scaledRadius = radius * radiusScale
            return Double.pi * scaledRadius * scaledRadius * abs(length * scale[axis])
        }
    }
}
