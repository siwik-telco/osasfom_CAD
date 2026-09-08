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
                body.primitive.updateBox { $0.endX = Expression(source: text) }
            }
        }
        XCTAssertEqual(document.state.body(id: id)?.primitive.boxSpec?.endX.source, "125")

        document.undo()
        XCTAssertEqual(
            document.state.body(id: id)?.primitive.boxSpec?.endX.source,
            Primitive.defaultBox.boxSpec?.endX.source,
            "the whole typing run is a single undo step"
        )
    }

    func testEndingAnEditingSessionStartsANewUndoStep() {
        let document = CADDocument()
        let id = document.addBody(.box, name: "Box")

        document.updateBody(id, actionName: "Edit", coalescingKey: "body.width") { body in
            body.primitive.updateBox { $0.endX = Expression(10) }
        }
        document.endEditingSession()
        document.updateBody(id, actionName: "Edit", coalescingKey: "body.width") { body in
            body.primitive.updateBox { $0.endX = Expression(20) }
        }

        document.undo()
        XCTAssertEqual(document.state.body(id: id)?.primitive.boxSpec?.endX.source, "10")
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
            body.primitive.updateBox { spec in
                spec.setBegin(.x, Expression(0))
                spec.setEnd(.x, Expression(999))
            }
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
                CylinderSpec(radius: Expression(source: "r"), begin: Expression(0), end: Expression(9), axis: .z)
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
            body.primitive.updateBox { spec in
                spec.setBegin(.x, Expression(0))
                spec.setEnd(.x, Expression(source: name ?? ""))
            }
        }
        document.endEditingSession()

        document.renameVariable(variableID, to: "renamed")

        XCTAssertEqual(document.state.body(id: bodyID)?.primitive.boxSpec?.endX.source, "renamed")
        XCTAssertEqual(document.resolved.body(id: bodyID)?.shape.localSize.x, 7)
        XCTAssertFalse(document.resolved.diagnostics.hasErrors)

        document.undo()
        XCTAssertEqual(document.state.body(id: bodyID)?.primitive.boxSpec?.endX.source, name)
    }

    func testReferenceCountingWarnsBeforeDeletingAUsedVariable() {
        let document = CADDocument()
        let variableID = document.addVariable()
        let name = document.state.variable(id: variableID)?.trimmedName ?? ""

        let bodyID = document.addBody(.box)
        document.updateBody(bodyID, actionName: "Bind") { body in
            body.primitive.updateBox {
                $0.endX = Expression(source: name)
                $0.endY = Expression(source: "\(name) * 2")
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
        let document = CADDocument()
        _ = document.addBody(.box)
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

    func testFreshDocumentLaunchesEmpty() {
        let document = CADDocument(state: CADModelState(name: "Untitled"))
        XCTAssertTrue(document.state.bodies.isEmpty)
        XCTAssertTrue(document.state.variables.isEmpty)
        XCTAssertTrue(document.state.simulation.ports.isEmpty)
    }

    func testSolverExportFromADocumentWithABody() throws {
        let document = CADDocument()
        _ = document.addBody(.box)
        let data = try document.solverExportData()
        XCTAssertGreaterThan(data.count, 0)
    }

    func testResetToNewDocumentClearsEverything() throws {
        let document = CADDocument()
        let bodyID = document.addBody(.box)
        document.selectedBodyID = bodyID
        document.selectedPortID = document.addPort()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reset-\(UUID().uuidString).osasfomcad")
        defer { try? FileManager.default.removeItem(at: url) }
        try document.save(to: url)
        XCTAssertEqual(document.fileURL, url)

        _ = document.addBody(.cylinder) // make it dirty again after saving
        XCTAssertTrue(document.hasUnsavedChanges)
        XCTAssertTrue(document.canUndo)

        document.resetToNewDocument(name: "Fresh")

        XCTAssertTrue(document.state.bodies.isEmpty)
        XCTAssertTrue(document.state.simulation.ports.isEmpty)
        XCTAssertEqual(document.state.name, "Fresh")
        XCTAssertNil(document.selectedBodyID)
        XCTAssertNil(document.selectedPortID)
        XCTAssertNil(document.fileURL, "a new document is not tied to the previously saved file")
        XCTAssertFalse(document.hasUnsavedChanges)
        XCTAssertFalse(document.canUndo, "resetting starts a clean undo history")
        XCTAssertFalse(document.canRedo)
    }

    // MARK: - Deleting variables

    /// Deleting a variable nothing uses is unremarkable; the point of the test
    /// is that it is a normal, undoable edit rather than a special case.
    @MainActor
    func testDeletingAnUnusedVariableRemovesItAndIsUndoable() {
        let document = CADDocument(state: CADModelState(name: "Vars"))
        let id = document.addVariable()
        document.updateVariable(id, actionName: "Name") { $0.name = "spare" }

        XCTAssertEqual(document.referencesToVariable(named: "spare"), 0)
        XCTAssertEqual(document.deleteVariableIfUnused(id), 0, "nothing blocks it")
        XCTAssertNil(document.state.variable(id: id))

        document.undo()
        XCTAssertNotNil(document.state.variable(id: id), "undo brings the variable back")
    }

    /// The rule the panel enforces: a variable something still refers to
    /// cannot be removed, because removing it would turn every one of those
    /// expressions into an "unknown name" error.
    @MainActor
    func testAReferencedVariableCannotBeDeleted() {
        var state = CADModelState(name: "Vars")
        let width = CADVariable(name: "w", expression: Expression(40))
        state.variables = [width]
        state.bodies = [
            CADBody(
                name: "Patch",
                primitive: .box(BoxSpec(
                    beginX: Expression(source: "-w/2"), endX: Expression(source: "w/2"),
                    beginY: Expression(-5), endY: Expression(5),
                    beginZ: Expression(0), endZ: Expression(1)
                ))
            )
        ]
        let document = CADDocument(state: state)

        let blocking = document.deleteVariableIfUnused(width.id)

        XCTAssertEqual(blocking, 2, "both begin and end use it")
        XCTAssertNotNil(document.state.variable(id: width.id), "the variable survives")
        XCTAssertEqual(document.resolved.errorCount, 0, "and nothing broke")
    }

    /// Once the last user is gone the same variable deletes cleanly, so the
    /// rule releases rather than trapping a variable forever.
    @MainActor
    func testAVariableBecomesDeletableOnceItsLastUserIsGone() {
        var state = CADModelState(name: "Vars")
        let width = CADVariable(name: "w", expression: Expression(40))
        state.variables = [width]
        let body = CADBody(
            name: "Patch",
            primitive: .box(BoxSpec(
                beginX: Expression(source: "-w/2"), endX: Expression(source: "w/2"),
                beginY: Expression(-5), endY: Expression(5),
                beginZ: Expression(0), endZ: Expression(1)
            ))
        )
        state.bodies = [body]
        let document = CADDocument(state: state)

        XCTAssertGreaterThan(document.deleteVariableIfUnused(width.id), 0)

        document.deleteBody(body.id)
        XCTAssertEqual(document.deleteVariableIfUnused(width.id), 0, "now unused")
        XCTAssertNil(document.state.variable(id: width.id))
    }

    /// A variable used only by another variable is still in use.
    @MainActor
    func testAVariableUsedOnlyByAnotherVariableIsProtected() {
        var state = CADModelState(name: "Vars")
        let base = CADVariable(name: "base", expression: Expression(10))
        state.variables = [base, CADVariable(name: "derived", expression: Expression(source: "base * 2"))]
        let document = CADDocument(state: state)

        XCTAssertEqual(document.deleteVariableIfUnused(base.id), 1)
        XCTAssertNotNil(document.state.variable(id: base.id))
    }

    @MainActor
    func testDeletingAnAlreadyGoneVariableIsHarmless() {
        let document = CADDocument(state: CADModelState(name: "Vars"))
        XCTAssertEqual(document.deleteVariableIfUnused(UUID()), 0)
    }

    /// Deleting one variable must not disturb the others' order or values.
    @MainActor
    func testDeletingLeavesTheRemainingVariablesIntact() {
        var state = CADModelState(name: "Vars")
        state.variables = [
            CADVariable(name: "a", expression: Expression(1)),
            CADVariable(name: "b", expression: Expression(2)),
            CADVariable(name: "c", expression: Expression(3))
        ]
        let document = CADDocument(state: state)

        document.deleteVariable(state.variables[1].id)

        XCTAssertEqual(document.state.variables.map(\.trimmedName), ["a", "c"])
        XCTAssertEqual(document.resolved.variables.values["c"], 3)
    }

    /// A variable defined in terms of another counts as a reference, so the
    /// warning fires for a dependent variable and not only for bodies.
    @MainActor
    func testAVariableReferencingAnotherCountsAsAUse() {
        var state = CADModelState(name: "Vars")
        state.variables = [
            CADVariable(name: "base", expression: Expression(10)),
            CADVariable(name: "derived", expression: Expression(source: "base * 2"))
        ]
        let document = CADDocument(state: state)

        XCTAssertEqual(document.referencesToVariable(named: "base"), 1)
        XCTAssertEqual(document.referencesToVariable(named: "derived"), 0)
    }

}
