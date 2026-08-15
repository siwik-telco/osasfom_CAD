import XCTest

@testable import osasfom_cadCore

@MainActor
final class DocumentTests: XCTestCase {
    // MARK: - Undo

    func testUndoAndRedoRestoreState() {
        let document = CADDocument()
        XCTAssertFalse(document.canUndo)

        let id = document.addBody(.box, name: "First")
        XCTAssertEqual(document.state.bodies.count, 1)
        XCTAssertTrue(document.canUndo)
        XCTAssertEqual(document.undoActionName, "Add Box")

        document.undo()
        XCTAssertTrue(document.state.bodies.isEmpty)
        XCTAssertTrue(document.canRedo)

        document.redo()
        XCTAssertEqual(document.state.bodies.count, 1)
        XCTAssertEqual(document.state.bodies.first?.id, id)
    }

    /// Typing into a field must not produce one undo step per keystroke.
    func testCoalescedEditsCollapseIntoOneUndoStep() {
        let document = CADDocument()
        let id = document.addBody(.box, name: "Box")

        for text in ["1", "12", "125"] {
            document.updateBody(id, actionName: "Edit Dimension", coalescingKey: "body.width") { body in
                body.primitive.updateBox { $0.width = Expression(source: text) }
            }
        }
        XCTAssertEqual(document.state.body(id: id)?.primitive.boxSpec?.width.source, "125")

        document.undo()
        XCTAssertEqual(
            document.state.body(id: id)?.primitive.boxSpec?.width.source,
            Primitive.defaultBox.boxSpec?.width.source,
            "the whole typing run is a single undo step"
        )
    }

    func testEndingAnEditingSessionStartsANewUndoStep() {
        let document = CADDocument()
        let id = document.addBody(.box, name: "Box")

        document.updateBody(id, actionName: "Edit", coalescingKey: "body.width") { body in
            body.primitive.updateBox { $0.width = Expression(10) }
        }
        document.endEditingSession()
        document.updateBody(id, actionName: "Edit", coalescingKey: "body.width") { body in
            body.primitive.updateBox { $0.width = Expression(20) }
        }

        document.undo()
        XCTAssertEqual(document.state.body(id: id)?.primitive.boxSpec?.width.source, "10")
    }

    func testNoOpMutationDoesNotCreateAnUndoStep() {
        let document = CADDocument()
        let id = document.addBody(.box, name: "Box")
        let undoName = document.undoActionName

        document.updateBody(id, actionName: "Rename Body") { body in
            body.name = "Box"
        }
        XCTAssertEqual(document.undoActionName, undoName)
    }

    func testUndoRestoresDerivedGeometryToo() {
        let document = CADDocument()
        let id = document.addBody(.box, name: "Box")
        let originalWidth = document.resolved.body(id: id)?.shape.localSize.x

        document.updateBody(id, actionName: "Edit") { body in
            body.primitive.updateBox { $0.width = Expression(999) }
        }
        XCTAssertEqual(document.resolved.body(id: id)?.shape.localSize.x, 999)

        document.undo()
        XCTAssertEqual(document.resolved.body(id: id)?.shape.localSize.x, originalWidth)
    }

    // MARK: - Selection

    /// Deleting used to jump the selection to the end of the list.
    func testDeletingSelectsTheNeighbourNotTheLastBody() {
        let document = CADDocument()
        let first = document.addBody(.box, name: "A")
        let second = document.addBody(.box, name: "B")
        let third = document.addBody(.box, name: "C")

        document.selectedBodyID = second
        document.deleteSelectedBody()

        XCTAssertEqual(document.selectedBodyID, third, "selects the following body")
        XCTAssertEqual(document.state.bodies.map(\.id), [first, third])

        document.selectedBodyID = third
        document.deleteSelectedBody()
        XCTAssertEqual(document.selectedBodyID, first, "falls back to the preceding body")
    }

    func testSelectionClearsWhenTheSelectedBodyDisappears() {
        let document = CADDocument()
        let id = document.addBody(.box)
        document.selectedBodyID = id
        document.perform("Clear") { state in state.bodies.removeAll() }
        XCTAssertNil(document.selectedBodyID)
    }

    // MARK: - Bodies

    func testDuplicateProducesAUniqueNameAndFreshIdentity() {
        let document = CADDocument()
        let id = document.addBody(.box, name: "Patch")
        document.selectedBodyID = id
        document.duplicateSelectedBody()

        XCTAssertEqual(document.state.bodies.count, 2)
        XCTAssertNotEqual(document.state.bodies[0].id, document.state.bodies[1].id)
        XCTAssertEqual(document.state.bodies.map(\.name), ["Patch", "Patch 2"])
    }

    /// A whole-value copy, so adding a property cannot silently fail to duplicate.
    func testDuplicateCarriesEveryProperty() {
        let original = CADBody(
            name: "Original",
            primitive: .cylinder(
                CylinderSpec(radius: Expression(source: "r"), length: Expression(9), axis: .z)
            ),
            transform: BodyTransform(rotationDegrees: Vector3Expression(Vec3(x: 1, y: 2, z: 3))),
            materialID: MaterialLibrary.copperID,
            priority: 42,
            isVisible: false
        )
        let copy = original.duplicated(named: "Copy")

        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.name, "Copy")
        XCTAssertEqual(copy.primitive, original.primitive)
        XCTAssertEqual(copy.transform, original.transform)
        XCTAssertEqual(copy.materialID, original.materialID)
        XCTAssertEqual(copy.priority, 42)
        XCTAssertFalse(copy.isVisible)
    }

    func testDuplicateOffsetKeepsExpressionsParametric() {
        let body = CADBody(
            name: "P",
            primitive: .defaultBox,
            transform: BodyTransform(
                position: Vector3Expression(
                    x: Expression(source: "patch_w"),
                    y: Expression(2),
                    z: Expression(0)
                )
            )
        )
        let copy = body.duplicated(named: "P 2", offsetBy: Vec3(x: 5, y: 5, z: 0))
        XCTAssertEqual(copy.transform.position.x.source, "patch_w + 5")
        XCTAssertEqual(copy.transform.position.y.source, "7", "a pure literal is folded")
        XCTAssertEqual(copy.transform.position.z.source, "0", "a zero offset is left alone")
    }

    func testReorderingBodies() {
        let document = CADDocument()
        document.addBody(.box, name: "A")
        document.addBody(.box, name: "B")
        document.addBody(.box, name: "C")

        document.moveBodies(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(document.state.bodies.map(\.name), ["B", "C", "A"])

        document.undo()
        XCTAssertEqual(document.state.bodies.map(\.name), ["A", "B", "C"])
    }

    // MARK: - Variables

    func testRenamingAVariableThroughTheDocumentIsOneUndoStep() {
        let document = CADDocument()
        let variableID = document.addVariable()
        document.updateVariable(variableID, actionName: "Set") { $0.expression = Expression(7) }
        document.endEditingSession()

        let bodyID = document.addBody(.box)
        let name = try? XCTUnwrap(document.state.variable(id: variableID)?.trimmedName)
        document.updateBody(bodyID, actionName: "Bind") { body in
            body.primitive.updateBox { $0.width = Expression(source: name ?? "") }
        }
        document.endEditingSession()

        document.renameVariable(variableID, to: "renamed")

        XCTAssertEqual(document.state.body(id: bodyID)?.primitive.boxSpec?.width.source, "renamed")
        XCTAssertEqual(document.resolved.body(id: bodyID)?.shape.localSize.x, 7)
        XCTAssertFalse(document.resolved.diagnostics.hasErrors)

        document.undo()
        XCTAssertEqual(document.state.body(id: bodyID)?.primitive.boxSpec?.width.source, name)
    }

    func testReferenceCountingWarnsBeforeDeletingAUsedVariable() {
        let document = CADDocument()
        let variableID = document.addVariable()
        let name = document.state.variable(id: variableID)?.trimmedName ?? ""

        let bodyID = document.addBody(.box)
        document.updateBody(bodyID, actionName: "Bind") { body in
            body.primitive.updateBox {
                $0.width = Expression(source: name)
                $0.height = Expression(source: "\(name) * 2")
            }
        }

        XCTAssertEqual(document.referencesToVariable(named: name), 2)
        XCTAssertEqual(document.referencesToVariable(named: "unused"), 0)
    }

    // MARK: - Materials

    func testDeletingAMaterialUnassignsTheBodiesUsingIt() {
        let document = CADDocument()
        let bodyID = document.addBody(.box)
        document.updateBody(bodyID, actionName: "Assign") { body in
            body.materialID = MaterialLibrary.fr4ID
        }
        XCTAssertEqual(document.bodyCount(usingMaterial: MaterialLibrary.fr4ID), 1)

        document.deleteMaterial(MaterialLibrary.fr4ID)

        XCTAssertNil(document.state.body(id: bodyID)?.materialID)
        XCTAssertNil(document.state.material(id: MaterialLibrary.fr4ID))
        XCTAssertFalse(
            document.resolved.diagnostics.hasErrors,
            "no body may be left holding a dangling material ID"
        )
    }

    func testUnassignedBodyResolvesToVacuum() {
        let document = CADDocument()
        let id = document.addBody(.box)
        XCTAssertEqual(document.resolved.body(id: id)?.materialID, MaterialLibrary.vacuumID)
    }

    // MARK: - Files

    func testSaveAndLoadRoundTripThroughDisk() throws {
        let document = CADDocument.makeStarterDocument()
        let original = document.state

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("roundtrip-\(UUID().uuidString).osasfomcad")
        defer { try? FileManager.default.removeItem(at: url) }

        try document.save(to: url)
        XCTAssertFalse(document.hasUnsavedChanges)

        let reopened = CADDocument()
        try reopened.load(from: url)

        XCTAssertEqual(reopened.state, original)
        XCTAssertFalse(reopened.hasUnsavedChanges)
        XCTAssertFalse(reopened.canUndo, "loading clears the undo history")
        XCTAssertEqual(reopened.fileURL, url)
    }

    func testStarterDocumentIsValidAndParametric() {
        let document = CADDocument.makeStarterDocument()
        let resolved = document.resolved

        XCTAssertFalse(resolved.diagnostics.hasErrors, "\(resolved.diagnostics.errors)")
        XCTAssertEqual(resolved.bodies.count, 3)
        XCTAssertNotNil(resolved.simulation.domain)
        XCTAssertEqual(resolved.simulation.ports.count, 1)

        // Changing the design frequency must move the geometry.
        let frequency = try? XCTUnwrap(
            document.state.variables.first { $0.trimmedName == "f0_GHz" }
        )
        let widthBefore = resolved.bodies.first { $0.name == "Patch" }?.shape.localSize.x

        if let frequency {
            document.updateVariable(frequency.id, actionName: "Retune") {
                $0.expression = Expression(5.8)
            }
        }
        let widthAfter = document.resolved.bodies.first { $0.name == "Patch" }?.shape.localSize.x

        XCTAssertNotNil(widthBefore)
        XCTAssertNotNil(widthAfter)
        XCTAssertLessThan(
            try XCTUnwrap(widthAfter),
            try XCTUnwrap(widthBefore),
            "a higher frequency must shrink the patch"
        )
    }

    func testSolverExportFromTheStarterDocument() throws {
        let document = CADDocument.makeStarterDocument()
        let data = try document.solverExportData()
        XCTAssertGreaterThan(data.count, 0)
    }
}
