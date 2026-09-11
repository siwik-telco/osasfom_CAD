import Foundation

/// A CAD transform applied to existing bodies — translate, rotate or mirror —
/// optionally leaving the originals and adding copies, the way FEKO's and
/// CST's transform dialogs do.
///
/// Two things make this more than arithmetic on a `BodyTransform`.
///
/// **Expressions.** A body's placement is expressions, not numbers, and
/// flattening `s_dip` into `117` to move something 10 mm would quietly destroy
/// the parametric model. Translation therefore composes *symbolically*:
/// `s_dip` becomes `s_dip + 3 * (spacing)`, which still follows its variables
/// and still reads like something a person wrote. That is also the case that
/// matters most — an array of elements down a boom is a translation with
/// copies. Rotation and mirroring cannot be composed that way (both need the
/// body's current orientation as a matrix), so they resolve to literals, and
/// `wouldFlattenExpressions` says so before anything is applied.
///
/// **Existing placement.** Bodies already carry a rotation, so a new rotation
/// composes with it: to a matrix, multiply, back to Euler angles. Mirroring a
/// rotated body is `M·R·M` with a negated scale on the mirror axis — the
/// reflection is carried by the scale, which is what keeps the result a
/// rotation rather than an impossible left-handed orientation.
public struct BodyTransformOperation: Hashable, Sendable {

    public enum Kind: Hashable, Sendable {
        /// Shift by an offset. Composed into the existing expressions.
        case translate(Vector3Expression)
        /// Turn about `axis`, through `centre`, by `degrees`.
        case rotate(axis: Axis, degrees: Expression, centre: Vector3Expression)
        /// Reflect through the plane normal to `axis` at `offset` along it.
        case mirror(axis: Axis, offset: Expression)
    }

    public var kind: Kind
    /// `0` transforms the bodies in place. `n > 0` keeps the originals and adds
    /// `n` copies, the k-th with the operation applied k times — so three
    /// copies of a 20 mm translation land at 20, 40 and 60 mm.
    public var copyCount: Int

    public init(kind: Kind, copyCount: Int = 0) {
        self.kind = kind
        self.copyCount = copyCount
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case unresolved(field: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .unresolved(let field, let reason):
                return "\(field) could not be evaluated: \(reason)"
            }
        }
    }

    /// Mirroring twice is the identity, so more than one copy would stack
    /// duplicates on top of the original.
    public var maximumCopies: Int {
        if case .mirror = kind { return 1 }
        return 64
    }

    /// True when applying this would replace a variable-driven placement with
    /// a plain number. Only rotation and mirroring can: translation composes.
    public func wouldFlattenExpressions(of bodies: [CADBody]) -> Bool {
        if case .translate = kind { return false }
        return bodies.contains { body in
            let transform = body.transform
            return [transform.position, transform.rotationDegrees, transform.scale].contains { vector in
                Axis.allCases.contains { !vector[$0].referencedVariableNames.isEmpty }
            }
        }
    }

    /// Undo-menu wording: "Translate 3 Bodies", "Mirror Patch", "Array 12 Copies".
    public func actionName(copies: Int, bodyCount: Int) -> String {
        let verb: String
        switch kind {
        case .translate: verb = "Translate"
        case .rotate: verb = "Rotate"
        case .mirror: verb = "Mirror"
        }
        guard copies > 0 else {
            return bodyCount == 1 ? verb : "\(verb) \(bodyCount) Bodies"
        }
        let total = copies * bodyCount
        return "\(verb) — \(total) \(total == 1 ? "Copy" : "Copies")"
    }

    // MARK: - Application

    /// The transform a body should end up with after `repetition` applications.
    ///
    /// `repetition` is 1 for an in-place transform and 1...n for the n-th copy.
    public func applied(
        to transform: BodyTransform,
        repetition: Int,
        variables: [String: Double]
    ) throws -> BodyTransform {
        switch kind {
        case .translate(let offset):
            return translated(transform, by: offset, times: repetition)

        case .rotate(let axis, let degrees, let centre):
            let angle = try scalar(degrees, field: "Angle", variables: variables)
            let pivot = try vector(centre, field: "Centre", variables: variables)
            return try rotated(
                transform,
                axis: axis,
                // Rotating k times by θ is one rotation of kθ.
                degrees: angle * Double(repetition),
                centre: pivot,
                variables: variables
            )

        case .mirror(let axis, let offset):
            let plane = try scalar(offset, field: "Plane offset", variables: variables)
            guard repetition % 2 == 1 else { return transform } // mirroring twice is the identity
            return try mirrored(transform, axis: axis, planeOffset: plane, variables: variables)
        }
    }

    // MARK: - Translate

    /// Symbolic: the offset is appended to whatever expression is already
    /// there, so `-gap/2` becomes `-gap/2 + 2 * (spacing)` rather than a
    /// number that has forgotten where it came from.
    private func translated(_ transform: BodyTransform, by offset: Vector3Expression, times k: Int) -> BodyTransform {
        var result = transform
        for axis in Axis.allCases {
            result.position[axis] = Self.sum(transform.position[axis], offset[axis], times: k)
        }
        return result
    }

    /// `base + k * (delta)`, skipping the parts that would only add noise.
    static func sum(_ base: Expression, _ delta: Expression, times k: Int) -> Expression {
        let deltaSource = delta.trimmed
        guard !deltaSource.isEmpty, Double(deltaSource) != 0, k != 0 else { return base }

        let term = k == 1 ? "(\(deltaSource))" : "\(k) * (\(deltaSource))"
        let baseSource = base.trimmed
        guard !baseSource.isEmpty, Double(baseSource) != 0 else { return Expression(source: term) }
        return Expression(source: "\(baseSource) + \(term)")
    }

    // MARK: - Rotate

    private func rotated(
        _ transform: BodyTransform,
        axis: Axis,
        degrees: Double,
        centre: Vec3,
        variables: [String: Double]
    ) throws -> BodyTransform {
        let position = try vector(transform.position, field: "Position", variables: variables)
        let rotation = try vector(transform.rotationDegrees, field: "Rotation", variables: variables)

        let radians = degrees * .pi / 180
        let turn: Matrix3
        switch axis {
        case .x: turn = .rotationX(radians: radians)
        case .y: turn = .rotationY(radians: radians)
        case .z: turn = .rotationZ(radians: radians)
        }

        // The body orbits the centre, and spins about its own origin by the
        // same amount — the two halves of a rigid rotation about a point.
        let orbited = turn.apply(to: position - centre) + centre
        let spun = (turn * Matrix3.euler(degrees: rotation)).eulerDegrees

        var result = transform
        result.position = Vector3Expression(orbited)
        result.rotationDegrees = Vector3Expression(spun)
        return result
    }

    // MARK: - Mirror

    private func mirrored(
        _ transform: BodyTransform,
        axis: Axis,
        planeOffset: Double,
        variables: [String: Double]
    ) throws -> BodyTransform {
        let position = try vector(transform.position, field: "Position", variables: variables)
        let rotation = try vector(transform.rotationDegrees, field: "Rotation", variables: variables)
        let scale = try vector(transform.scale, field: "Scale", variables: variables)

        var reflectedPosition = position
        reflectedPosition[axis] = 2 * planeOffset - position[axis]

        // A reflection is not a rotation, so it cannot live in the Euler
        // angles. Split it: the handedness flip goes into the scale, and what
        // is left — M·R·M — is a genuine rotation again.
        let mirror = Matrix3.reflection(normalTo: axis)
        let orientation = (mirror * Matrix3.euler(degrees: rotation) * mirror).eulerDegrees

        var reflectedScale = scale
        reflectedScale[axis] = -scale[axis]

        var result = transform
        result.position = Vector3Expression(reflectedPosition)
        result.rotationDegrees = Vector3Expression(orientation)
        result.scale = Vector3Expression(reflectedScale)
        return result
    }

    // MARK: - Evaluation

    private func scalar(_ expression: Expression, field: String, variables: [String: Double]) throws -> Double {
        do {
            return try expression.value(variables: variables)
        } catch {
            throw Failure.unresolved(
                field: field,
                reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
            )
        }
    }

    private func vector(_ expression: Vector3Expression, field: String, variables: [String: Double]) throws -> Vec3 {
        Vec3(
            x: try scalar(expression.x, field: "\(field) X", variables: variables),
            y: try scalar(expression.y, field: "\(field) Y", variables: variables),
            z: try scalar(expression.z, field: "\(field) Z", variables: variables)
        )
    }
}
