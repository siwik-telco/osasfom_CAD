import Foundation

/// Anything that holds `Expression`s somewhere inside it.
///
/// The single required operation is an in-place walk, which is what variable
/// renaming needs. Validation does not use it — the resolver visits fields
/// explicitly so it can attach a meaningful field name to each diagnostic.
public protocol ExpressionWalkable {
    mutating func walkExpressions(_ transform: (inout Expression) -> Void)
}

/// A parametric 3-vector.
public struct Vector3Expression: Codable, Hashable, Sendable, ExpressionWalkable {
    public var x: Expression
    public var y: Expression
    public var z: Expression

    public init(x: Expression, y: Expression, z: Expression) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(_ value: Vec3) {
        self.init(x: Expression(value.x), y: Expression(value.y), z: Expression(value.z))
    }

    public static let zero = Vector3Expression(Vec3.zero)
    public static let one = Vector3Expression(Vec3.one)

    public subscript(axis: Axis) -> Expression {
        get {
            switch axis {
            case .x: return x
            case .y: return y
            case .z: return z
            }
        }
        set {
            switch axis {
            case .x: x = newValue
            case .y: y = newValue
            case .z: z = newValue
            }
        }
    }

    public func value(variables: [String: Double]) throws -> Vec3 {
        Vec3(
            x: try x.value(variables: variables),
            y: try y.value(variables: variables),
            z: try z.value(variables: variables)
        )
    }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        transform(&x)
        transform(&y)
        transform(&z)
    }
}

/// A parametric axis-aligned box: six independent expressions.
///
/// Used for the computational domain, lumped ports, box monitors and mesh
/// refinement regions, so `y_min = -substrate_h` stays live.
public struct BoundsExpression: Codable, Hashable, Sendable, ExpressionWalkable {
    public var xMin: Expression
    public var xMax: Expression
    public var yMin: Expression
    public var yMax: Expression
    public var zMin: Expression
    public var zMax: Expression

    public init(
        xMin: Expression,
        xMax: Expression,
        yMin: Expression,
        yMax: Expression,
        zMin: Expression,
        zMax: Expression
    ) {
        self.xMin = xMin
        self.xMax = xMax
        self.yMin = yMin
        self.yMax = yMax
        self.zMin = zMin
        self.zMax = zMax
    }

    public init(_ bounds: BodyBounds) {
        self.init(
            xMin: Expression(bounds.xMin),
            xMax: Expression(bounds.xMax),
            yMin: Expression(bounds.yMin),
            yMax: Expression(bounds.yMax),
            zMin: Expression(bounds.zMin),
            zMax: Expression(bounds.zMax)
        )
    }

    public static let zero = BoundsExpression(BodyBounds(center: .zero, size: .zero))

    public func lower(on axis: Axis) -> Expression {
        switch axis {
        case .x: return xMin
        case .y: return yMin
        case .z: return zMin
        }
    }

    public func upper(on axis: Axis) -> Expression {
        switch axis {
        case .x: return xMax
        case .y: return yMax
        case .z: return zMax
        }
    }

    public func value(variables: [String: Double]) throws -> BodyBounds {
        BodyBounds(
            xMin: try xMin.value(variables: variables),
            xMax: try xMax.value(variables: variables),
            yMin: try yMin.value(variables: variables),
            yMax: try yMax.value(variables: variables),
            zMin: try zMin.value(variables: variables),
            zMax: try zMax.value(variables: variables)
        )
    }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        transform(&xMin)
        transform(&xMax)
        transform(&yMin)
        transform(&yMax)
        transform(&zMin)
        transform(&zMax)
    }
}
