import XCTest
@testable import osasfom_cadCore

/// `CADDocument.applyTransform` — the selection-level behaviour: copies land in
/// the right place in the model list, the whole operation is one undo step, and
/// a bad expression changes nothing.
@MainActor
final class TransformDocumentTests: XCTestCase {

    private func makeDocument() -> CADDocument {
        var state = CADModelState(name: "Array", lengthUnit: .millimeter)
        state.variables = [CADVariable(name: "spacing", expression: Expression(20))]
        state.bodies = [
            CADBody(name: "Element", primitive: .defaultCylinder),
            CADBody(name: "Boom", primitive: .defaultBox)
        ]
        return CADDocument(state: state)
    }

    private func x(_ body: CADBody, _ variables: [String: Double]) throws -> Double {
        try body.transform.position.x.value(variables: variables)
    }

    /// The array case: four elements down a boom from one body, still driven by
    /// the `spacing` variable.
    func testCopiesAreCreatedAndFollowTheVariable() throws {
        let document = makeDocument()
        document.selectedBodyID = document.state.bodies[0].id

        let created = try document.applyTransform(
            BodyTransformOperation(
                kind: .translate(Vector3Expression(
                    x: Expression(source: "spacing"), y: Expression(0), z: Expression(0)
                )),
                copyCount: 3
            )
        )

        XCTAssertEqual(created.count, 3)
        XCTAssertEqual(document.state.bodies.count, 5, "originals kept, three added")

        let variables = document.resolved.variables.values
        let copies = created.compactMap { document.state.body(id: $0) }
        XCTAssertEqual(try copies.map { try x($0, variables) }, [20, 40, 60])

        // Every copy still references the variable rather than a baked number.
        XCTAssertTrue(copies.allSatisfy { $0.transform.position.x.trimmed.contains("spacing") })
        XCTAssertEqual(Set(copies.map(\.name)).count, 3, "names must be unique")
    }

    /// Copies sit directly after the body they came from, so an array reads in
    /// order instead of interleaving when several bodies are transformed.
    func testCopiesAreInsertedAfterTheirOriginal() throws {
        let document = makeDocument()
        document.selectedBodyID = document.state.bodies[0].id
        try document.applyTransform(
            BodyTransformOperation(
                kind: .translate(Vector3Expression(Vec3(x: 10, y: 0, z: 0))),
                copyCount: 2
            )
        )
        let names = document.state.bodies.map(\.name)
        XCTAssertEqual(names.first, "Element")
        XCTAssertEqual(names.last, "Boom", "the untouched body stays at the end")
        XCTAssertEqual(names.count, 4)
    }

    func testInPlaceTransformMovesRatherThanCopies() throws {
        let document = makeDocument()
        document.selectedBodyIDs = Set(document.state.bodies.map(\.id))

        try document.applyTransform(
            BodyTransformOperation(kind: .translate(Vector3Expression(Vec3(x: 5, y: 0, z: 0))))
        )

        XCTAssertEqual(document.state.bodies.count, 2, "nothing added")
        let variables = document.resolved.variables.values
        for body in document.state.bodies {
            XCTAssertEqual(try x(body, variables), 5, accuracy: 1e-9)
        }
    }

    /// One undo step for the whole operation: an array of twelve is one action
    /// to the user, so it must be one action to undo.
    func testWholeOperationIsASingleUndoStep() throws {
        let document = makeDocument()
        document.selectedBodyID = document.state.bodies[0].id
        try document.applyTransform(
            BodyTransformOperation(
                kind: .translate(Vector3Expression(Vec3(x: 10, y: 0, z: 0))),
                copyCount: 4
            )
        )
        XCTAssertEqual(document.state.bodies.count, 6)

        document.undo()
        XCTAssertEqual(document.state.bodies.count, 2, "one undo removes all four copies")
    }

    /// A bad expression must leave the model untouched rather than applying to
    /// the bodies it got to first.
    func testFailedTransformLeavesTheModelUnchanged() {
        let document = makeDocument()
        document.selectedBodyIDs = Set(document.state.bodies.map(\.id))
        let before = document.state.bodies

        XCTAssertThrowsError(
            try document.applyTransform(
                BodyTransformOperation(
                    kind: .rotate(axis: .z, degrees: Expression(source: "nope"), centre: .zero),
                    copyCount: 2
                )
            )
        )
        XCTAssertEqual(document.state.bodies, before)
    }

    func testNoSelectionIsANoOp() throws {
        let document = makeDocument()
        document.selectedBodyIDs = []
        let created = try document.applyTransform(
            BodyTransformOperation(kind: .translate(Vector3Expression(Vec3(x: 1, y: 0, z: 0))))
        )
        XCTAssertTrue(created.isEmpty)
        XCTAssertEqual(document.state.bodies.count, 2)
    }
}
