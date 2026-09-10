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
    /// Boolean history applied to `primitive`, in order. Empty for a plain
    /// primitive, which is why it decodes as absent-means-empty: project
    /// files written before booleans existed stay readable.
    public var booleans: [BooleanOperation]

    public init(
        id: UUID = UUID(),
        name: String,
        primitive: Primitive,
        transform: BodyTransform = BodyTransform(),
        materialID: UUID? = nil,
        priority: Int = 0,
        isVisible: Bool = true,
        booleans: [BooleanOperation] = []
    ) {
        self.id = id
        self.name = name
        self.primitive = primitive
        self.transform = transform
        self.materialID = materialID
        self.priority = priority
        self.isVisible = isVisible
        self.booleans = booleans
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, primitive, transform, materialID, priority, isVisible, booleans
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.primitive = try container.decode(Primitive.self, forKey: .primitive)
        self.transform = try container.decode(BodyTransform.self, forKey: .transform)
        self.materialID = try container.decodeIfPresent(UUID.self, forKey: .materialID)
        self.priority = try container.decode(Int.self, forKey: .priority)
        self.isVisible = try container.decode(Bool.self, forKey: .isVisible)
        self.booleans = try container.decodeIfPresent([BooleanOperation].self, forKey: .booleans) ?? []
    }

    public var kind: PrimitiveKind { primitive.kind }

    public var effectiveMaterialID: UUID { materialID ?? MaterialLibrary.defaultMaterialID }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        primitive.walkExpressions(transform)
        self.transform.walkExpressions(transform)
        for index in booleans.indices { booleans[index].walkExpressions(transform) }
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
            isVisible: isVisible,
            booleans: booleans.map { step in
                BooleanOperation(
                    kind: step.kind,
                    primitive: step.primitive,
                    transform: step.transform,
                    isEnabled: step.isEnabled
                )
            }
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
            return "A \(kind.displayName.lowercased()) has no unique extent inverse, so the box below is read-only. Edit radius, begin, end and axis instead."
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
    /// The enabled steps of the body's boolean history, in application order.
    /// Disabled steps are dropped during resolution, so everything here counts.
    public let booleans: [ResolvedBooleanOperation]

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
        orderIndex: Int,
        booleans: [ResolvedBooleanOperation] = []
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
        self.booleans = booleans
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
        // An `add` step can put material outside the base primitive, so the
        // box has to grow to cover it or the mesher would bracket only part
        // of the body. `subtract` and `trim` can only ever shrink the result,
        // so leaving them out keeps this a safe superset.
        booleans
            .filter { $0.kind == .add }
            .reduce(baseAxisAlignedBounds) { $0.union($1.axisAlignedBounds) }
    }

    /// The base primitive's own box, before any boolean step widens it.
    public var baseAxisAlignedBounds: BodyBounds {
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

    /// Every box the mesher should put grid lines on for this body: the base
    /// primitive plus each boolean tool. A cut only lands where the numbers
    /// say if the grid actually has a line on the cut face, so a tool's edges
    /// are snap-worthy even when the tool itself removes material.
    public var snapBounds: [BodyBounds] {
        [baseAxisAlignedBounds] + booleans.map(\.axisAlignedBounds)
    }

    /// Whether `worldPoint` is inside this body once its boolean history has
    /// been applied.
    public func contains(worldPoint: Vec3) -> Bool {
        ShapeContainment.contains(self, worldPoint: worldPoint)
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

    /// The base primitive's volume. Boolean steps are *not* applied — a
    /// drilled plate reports as solid — because the analytic volume of a CSG
    /// result isn't a closed form. Use the mesh from `BodyMesh` if a true
    /// volume is ever needed.
    public var volume: Double {
        switch shape {
        case .box(let size):
            let scaled = size.scaled(by: scale)
            return abs(scaled.x * scaled.y * scaled.z)
        case .sheet(let size, _):
            let scaled = size.scaled(by: scale)
            return abs(scaled.x * scaled.y * scaled.z)
        case .cylinder(let radius, let begin, let end, let axis):
            let (first, second) = axis.perpendicular
            let radiusScale = (abs(scale[first]) + abs(scale[second])) / 2
            let scaledRadius = radius * radiusScale
            let length = abs(end - begin)
            return Double.pi * scaledRadius * scaledRadius * abs(length * scale[axis])
        case .mesh(let mesh):
            // Signed-tetrahedron sum over the closed surface (divergence
            // theorem). Meaningless for an open mesh, so that reports zero
            // rather than a number the winding happens to produce.
            guard mesh.isWatertight else { return 0 }
            let raw = mesh.triangles.reduce(0.0) { total, triangle in
                total + triangle.v0.dot(triangle.v1.cross(triangle.v2)) / 6
            }
            return abs(raw * scale.x * scale.y * scale.z)
        }
    }
}
