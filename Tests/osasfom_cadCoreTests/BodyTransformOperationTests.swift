import XCTest
@testable import osasfom_cadCore

/// Translate / rotate / mirror on existing bodies, with copies — the FEKO and
/// CST transform dialog.
///
/// The load-bearing parts are composition and expressions: a transform lands on
/// a body that already has a placement, and that placement is expressions
/// rather than numbers.
final class BodyTransformOperationTests: XCTestCase {

    private let noVariables: [String: Double] = [:]

    private func transform(
        position: Vec3 = .zero,
        rotation: Vec3 = .zero,
        scale: Vec3 = .one
    ) -> BodyTransform {
        BodyTransform(
            position: Vector3Expression(position),
            rotationDegrees: Vector3Expression(rotation),
            scale: Vector3Expression(scale)
        )
    }

    private func resolved(_ t: BodyTransform, _ variables: [String: Double] = [:]) throws -> Vec3 {
        Vec3(
            x: try t.position.x.value(variables: variables),
            y: try t.position.y.value(variables: variables),
            z: try t.position.z.value(variables: variables)
        )
    }

    // MARK: - Translate

    /// The whole reason translation is handled symbolically: an array down a
    /// boom must keep following its variables. Flattening `s_dip` to a number
    /// to move something would quietly sever the parametric model.
    func testTranslateComposesExpressionsInsteadOfFlatteningThem() throws {
        let start = BodyTransform(
            position: Vector3Expression(
                x: Expression(source: "s_dip"), y: Expression(0), z: Expression(0)
            )
        )
        let op = BodyTransformOperation(
            kind: .translate(Vector3Expression(
                x: Expression(source: "spacing"), y: Expression(0), z: Expression(0)
            )),
            copyCount: 3
        )

        let third = try op.applied(to: start, repetition: 3, variables: ["s_dip": 100, "spacing": 20])
        XCTAssertTrue(third.position.x.trimmed.contains("s_dip"), "must still reference the variable")
        XCTAssertTrue(third.position.x.trimmed.contains("spacing"))
        XCTAssertEqual(try third.position.x.value(variables: ["s_dip": 100, "spacing": 20]), 160)

        // And it follows a change to either variable.
        XCTAssertEqual(try third.position.x.value(variables: ["s_dip": 0, "spacing": 10]), 30)
        XCTAssertFalse(op.wouldFlattenExpressions(of: [CADBody(name: "b", primitive: .defaultBox, transform: start)]))
    }

    /// Copies step by k, so three copies of 20 mm land at 20, 40 and 60 — not
    /// all at 20, and not at 20, 40, 60 measured from each other.
    func testCopiesStepCumulatively() throws {
        let op = BodyTransformOperation(
            kind: .translate(Vector3Expression(Vec3(x: 20, y: 0, z: 0))),
            copyCount: 3
        )
        let start = transform(position: Vec3(x: 5, y: 0, z: 0))
        let landed = try (1...3).map { try resolved(op.applied(to: start, repetition: $0, variables: noVariables)).x }
        XCTAssertEqual(landed, [25, 45, 65])
    }

    func testZeroOffsetLeavesTheExpressionAlone() {
        let base = Expression(source: "patch_l / 2")
        XCTAssertEqual(BodyTransformOperation.sum(base, Expression(0), times: 4).trimmed, "patch_l / 2")
    }

    // MARK: - Rotate

    /// A rotation about a centre is an orbit plus a spin. Getting only the
    /// orbit right leaves every copy of a circular array facing the same way.
    func testRotationOrbitsTheCentreAndSpinsTheBody() throws {
        let op = BodyTransformOperation(
            kind: .rotate(axis: .z, degrees: Expression(90), centre: .zero)
        )
        let start = transform(position: Vec3(x: 10, y: 0, z: 0))
        let turned = try op.applied(to: start, repetition: 1, variables: noVariables)

        let p = try resolved(turned)
        XCTAssertEqual(p.x, 0, accuracy: 1e-9, "orbited onto +Y")
        XCTAssertEqual(p.y, 10, accuracy: 1e-9)
        XCTAssertEqual(try turned.rotationDegrees.z.value(), 90, accuracy: 1e-9, "and spun with it")
    }

    /// Rotating k times by θ must equal one rotation of kθ — what makes a
    /// circular array come out evenly spaced.
    ///
    /// Tolerance is 1e-6, not 1e-9, because a rotated placement is written
    /// back as literal expression text and `Expression.literalSource` formats
    /// with `%.6f`. Numeric transforms therefore quantise to a micrometre in a
    /// millimetre project — irrelevant for geometry, but real, and it is why
    /// translation composes symbolically instead of resolving.
    func testRepeatedRotationAccumulates() throws {
        let op = BodyTransformOperation(
            kind: .rotate(axis: .z, degrees: Expression(30), centre: .zero),
            copyCount: 3
        )
        let start = transform(position: Vec3(x: 10, y: 0, z: 0))
        for k in 1...3 {
            let p = try resolved(op.applied(to: start, repetition: k, variables: noVariables))
            let expected = Double(k) * 30 * .pi / 180
            XCTAssertEqual(p.x, 10 * cos(expected), accuracy: 1e-6)
            XCTAssertEqual(p.y, 10 * sin(expected), accuracy: 1e-6)
        }
    }

    /// Composing onto a body that is already rotated is matrix work, and the
    /// Euler angles that come back must rebuild the same orientation — the
    /// numbers themselves are not unique, so the matrix is what is compared.
    func testRotationComposesWithAnExistingRotation() throws {
        let start = transform(rotation: Vec3(x: 0, y: 0, z: 40))
        let op = BodyTransformOperation(
            kind: .rotate(axis: .z, degrees: Expression(50), centre: .zero)
        )
        let turned = try op.applied(to: start, repetition: 1, variables: noVariables)

        let got = Matrix3.euler(degrees: Vec3(
            x: try turned.rotationDegrees.x.value(),
            y: try turned.rotationDegrees.y.value(),
            z: try turned.rotationDegrees.z.value()
        ))
        let expected = Matrix3.euler(degrees: Vec3(x: 0, y: 0, z: 90))
        assertMatrix(got, expected)
    }

    /// A rotation about a *different* axis than the body already uses is where
    /// naive angle-addition breaks down completely.
    func testRotationAboutADifferentAxisThanTheBodyAlreadyUses() throws {
        let existing = Vec3(x: 0, y: 0, z: 90)
        let start = transform(rotation: existing)
        let op = BodyTransformOperation(
            kind: .rotate(axis: .x, degrees: Expression(90), centre: .zero)
        )
        let turned = try op.applied(to: start, repetition: 1, variables: noVariables)

        let got = Matrix3.euler(degrees: Vec3(
            x: try turned.rotationDegrees.x.value(),
            y: try turned.rotationDegrees.y.value(),
            z: try turned.rotationDegrees.z.value()
        ))
        let expected = Matrix3.rotationX(radians: .pi / 2) * Matrix3.euler(degrees: existing)
        assertMatrix(got, expected)
    }

    // MARK: - Mirror

    func testMirrorReflectsPositionAcrossThePlane() throws {
        let op = BodyTransformOperation(kind: .mirror(axis: .x, offset: Expression(10)))
        let start = transform(position: Vec3(x: 4, y: 7, z: -2))
        let flipped = try op.applied(to: start, repetition: 1, variables: noVariables)

        let p = try resolved(flipped)
        XCTAssertEqual(p.x, 16, accuracy: 1e-9, "4 is 6 short of the plane, so it lands 6 past it")
        XCTAssertEqual(p.y, 7, accuracy: 1e-9, "the other axes are untouched")
        XCTAssertEqual(p.z, -2, accuracy: 1e-9)
    }

    /// A reflection is not a rotation — its determinant is −1 — so it cannot
    /// live in the Euler angles. The handedness flip has to go into the scale,
    /// or the body comes back as an impossible left-handed orientation.
    func testMirrorPutsTheHandednessFlipInTheScale() throws {
        let op = BodyTransformOperation(kind: .mirror(axis: .x, offset: Expression(0)))
        let start = transform(rotation: Vec3(x: 0, y: 0, z: 30), scale: Vec3(x: 2, y: 3, z: 4))
        let flipped = try op.applied(to: start, repetition: 1, variables: noVariables)

        XCTAssertEqual(try flipped.scale.x.value(), -2, accuracy: 1e-9)
        XCTAssertEqual(try flipped.scale.y.value(), 3, accuracy: 1e-9)
        XCTAssertEqual(try flipped.scale.z.value(), 4, accuracy: 1e-9)

        // What remains in the rotation must still be a rotation: M·R·M.
        let got = Matrix3.euler(degrees: Vec3(
            x: try flipped.rotationDegrees.x.value(),
            y: try flipped.rotationDegrees.y.value(),
            z: try flipped.rotationDegrees.z.value()
        ))
        let mirror = Matrix3.reflection(normalTo: .x)
        assertMatrix(got, mirror * Matrix3.euler(degrees: Vec3(x: 0, y: 0, z: 30)) * mirror)
    }

    func testMirroringTwiceIsTheIdentity() throws {
        let op = BodyTransformOperation(kind: .mirror(axis: .y, offset: Expression(3)))
        let start = transform(position: Vec3(x: 1, y: 2, z: 3))
        let twice = try op.applied(to: start, repetition: 2, variables: noVariables)
        XCTAssertEqual(try resolved(twice).y, 2, accuracy: 1e-9)
    }

    func testMirrorOffersOnlyOneCopy() {
        XCTAssertEqual(BodyTransformOperation(kind: .mirror(axis: .y, offset: Expression(0))).maximumCopies, 1)
        XCTAssertGreaterThan(BodyTransformOperation(kind: .translate(.zero)).maximumCopies, 1)
    }

    // MARK: - Failure and warning

    /// Nothing is applied on a bad expression — a half-transformed model is
    /// worse than a refused one.
    func testUnresolvableExpressionThrowsRatherThanGuessing() {
        let op = BodyTransformOperation(
            kind: .rotate(axis: .z, degrees: Expression(source: "missing_variable"), centre: .zero)
        )
        XCTAssertThrowsError(try op.applied(to: transform(), repetition: 1, variables: noVariables)) { error in
            guard case BodyTransformOperation.Failure.unresolved(let field, _) = error else {
                return XCTFail("expected .unresolved, got \(error)")
            }
            XCTAssertEqual(field, "Angle")
        }
    }

    func testRotationWarnsThatItWillFlattenAParametricPlacement() {
        let body = CADBody(
            name: "Dipole",
            primitive: .defaultCylinder,
            transform: BodyTransform(position: Vector3Expression(
                x: Expression(source: "s_dip"), y: Expression(0), z: Expression(0)
            ))
        )
        let rotate = BodyTransformOperation(kind: .rotate(axis: .z, degrees: Expression(10), centre: .zero))
        let translate = BodyTransformOperation(kind: .translate(Vector3Expression(Vec3(x: 1, y: 0, z: 0))))

        XCTAssertTrue(rotate.wouldFlattenExpressions(of: [body]))
        XCTAssertFalse(translate.wouldFlattenExpressions(of: [body]), "translation composes instead")
    }

    // MARK: - Helper

    private func assertMatrix(
        _ got: Matrix3,
        _ expected: Matrix3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (a, b) in [(got.columns.0, expected.columns.0),
                       (got.columns.1, expected.columns.1),
                       (got.columns.2, expected.columns.2)] {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(a.z, b.z, accuracy: 1e-9, file: file, line: line)
        }
    }
}
