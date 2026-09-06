import XCTest

@testable import osasfom_cadCore

/// The two-object gesture: select two bodies, combine, get one body. The
/// consumed body has to end up cutting *exactly* where it stood, which is the
/// whole point — a hole that lands somewhere else is worse than no feature.
@MainActor
final class CombineBodiesTests: XCTestCase {

    private func makeDocument() -> (CADDocument, UUID, UUID) {
        var state = CADModelState(name: "Combine", lengthUnit: .millimeter)
        // A solid rod...
        let rod = CADBody(
            name: "Cylinder 1",
            primitive: .cylinder(
                CylinderSpec(radius: Expression(10), begin: Expression(0), end: Expression(20), axis: .z)
            ),
            materialID: MaterialLibrary.copperID
        )
        // ...and a narrower one through its middle, to become the bore.
        let bore = CADBody(
            name: "Cylinder 2",
            primitive: .cylinder(
                CylinderSpec(radius: Expression(4), begin: Expression(-5), end: Expression(25), axis: .z)
            ),
            materialID: MaterialLibrary.pecID
        )
        state.bodies = [rod, bore]
        return (CADDocument(state: state), rod.id, bore.id)
    }

    func testSubtractingASecondBodyLeavesOneBodyWithAHoleWhereItStood() throws {
        let (document, rodID, boreID) = makeDocument()
        document.selectedBodyIDs = [rodID]
        document.selectedBodyIDs.insert(boreID)

        document.combineSelectedBodies(.subtract)

        XCTAssertEqual(document.state.bodies.count, 1, "the tool body is consumed")
        let result = try XCTUnwrap(document.state.bodies.first)
        XCTAssertEqual(result.id, rodID, "the first-picked body survives")
        XCTAssertEqual(result.name, "Cylinder 1")
        XCTAssertEqual(result.booleans.count, 1)
        XCTAssertEqual(result.booleans[0].kind, .subtract)

        // The hole is where the consumed body was: on the axis, hollow;
        // out at r = 8mm, still solid.
        let resolved = try XCTUnwrap(document.resolved.body(id: rodID))
        XCTAssertFalse(resolved.contains(worldPoint: Vec3(x: 0, y: 0, z: 10)), "bore is open")
        XCTAssertTrue(resolved.contains(worldPoint: Vec3(x: 8, y: 0, z: 10)), "wall is still there")
        XCTAssertFalse(resolved.contains(worldPoint: Vec3(x: 12, y: 0, z: 10)), "outside the rod")
    }

    /// The consumed shape has to keep its own placement, not be re-centred on
    /// the body that swallowed it.
    func testAnOffsetToolCutsAtItsOriginalLocation() throws {
        var state = CADModelState(name: "Combine", lengthUnit: .millimeter)
        let plate = CADBody(
            name: "Plate",
            primitive: .box(BoxSpec(
                beginX: Expression(-10), endX: Expression(10),
                beginY: Expression(-10), endY: Expression(10),
                beginZ: Expression(0), endZ: Expression(2)
            ))
        )
        // Off-centre on purpose.
        let punch = CADBody(
            name: "Punch",
            primitive: .box(BoxSpec(
                beginX: Expression(5), endX: Expression(9),
                beginY: Expression(-2), endY: Expression(2),
                beginZ: Expression(-1), endZ: Expression(3)
            ))
        )
        state.bodies = [plate, punch]
        let document = CADDocument(state: state)

        document.selectedBodyIDs = [plate.id]
        document.selectedBodyIDs.insert(punch.id)
        document.combineSelectedBodies(.subtract)

        let resolved = try XCTUnwrap(document.resolved.body(id: plate.id))
        XCTAssertFalse(resolved.contains(worldPoint: Vec3(x: 7, y: 0, z: 1)), "cut at the punch's own place")
        XCTAssertTrue(resolved.contains(worldPoint: Vec3(x: -7, y: 0, z: 1)), "and nowhere else")
    }

    func testTheFirstBodyPickedIsTheOneKeptRegardlessOfListOrder() throws {
        let (document, rodID, boreID) = makeDocument()
        // Pick the *second* body in the list first.
        document.selectedBodyIDs = [boreID]
        document.selectedBodyIDs.insert(rodID)

        document.combineSelectedBodies(.subtract)

        let result = try XCTUnwrap(document.state.bodies.first)
        XCTAssertEqual(result.id, boreID, "pick order wins over list order")
        XCTAssertEqual(document.state.bodies.count, 1)
    }

    func testCombiningIsUndoable() throws {
        let (document, rodID, boreID) = makeDocument()
        document.selectedBodyIDs = [rodID]
        document.selectedBodyIDs.insert(boreID)

        document.combineSelectedBodies(.add)
        XCTAssertEqual(document.state.bodies.count, 1)

        document.undo()
        XCTAssertEqual(document.state.bodies.count, 2, "the consumed body comes back")
        XCTAssertTrue(document.state.bodies.allSatisfy { $0.booleans.isEmpty })
    }

    func testCombiningNeedsAtLeastTwoBodies() {
        let (document, rodID, _) = makeDocument()
        document.selectedBodyIDs = [rodID]

        XCTAssertFalse(document.canCombineSelectedBodies)
        XCTAssertNil(document.combineSelectedBodies(.subtract))
        XCTAssertEqual(document.state.bodies.count, 2, "nothing happened")
    }

    /// Consuming more than one tool at once, which is what a three-body
    /// selection means.
    func testAllToolsAfterTheFirstAreConsumed() throws {
        var state = CADModelState(name: "Combine", lengthUnit: .millimeter)
        let base = CADBody(name: "Base", primitive: .makeDefault(.box))
        let a = CADBody(name: "A", primitive: .makeDefault(.cylinder))
        let b = CADBody(name: "B", primitive: .makeDefault(.cylinder))
        state.bodies = [base, a, b]
        let document = CADDocument(state: state)

        document.selectedBodyIDs = [base.id]
        document.selectedBodyIDs.formUnion([a.id, b.id])
        document.combineSelectedBodies(.subtract)

        XCTAssertEqual(document.state.bodies.count, 1)
        XCTAssertEqual(try XCTUnwrap(document.state.bodies.first).booleans.count, 2)
    }

    /// A combined body is still parametric: the consumed shape keeps its
    /// expressions, so the hole follows the variable that drove it.
    func testAConsumedToolStaysParametric() throws {
        var state = CADModelState(name: "Combine", lengthUnit: .millimeter)
        let radius = CADVariable(name: "bore_r", expression: Expression(4))
        state.variables = [radius]
        let rod = CADBody(
            name: "Rod",
            primitive: .cylinder(
                CylinderSpec(radius: Expression(10), begin: Expression(0), end: Expression(20), axis: .z)
            )
        )
        let bore = CADBody(
            name: "Bore",
            primitive: .cylinder(
                CylinderSpec(
                    radius: Expression(source: "bore_r"),
                    begin: Expression(-1), end: Expression(21), axis: .z
                )
            )
        )
        state.bodies = [rod, bore]
        let document = CADDocument(state: state)

        document.selectedBodyIDs = [rod.id]
        document.selectedBodyIDs.insert(bore.id)
        document.combineSelectedBodies(.subtract)

        // 5mm out is solid with a 4mm bore...
        var resolved = try XCTUnwrap(document.resolved.body(id: rod.id))
        XCTAssertTrue(resolved.contains(worldPoint: Vec3(x: 5, y: 0, z: 10)))

        // ...and hollow once the variable widens it, with no re-combining.
        document.updateVariable(radius.id, actionName: "Widen") { $0.expression = Expression(8) }
        resolved = try XCTUnwrap(document.resolved.body(id: rod.id))
        XCTAssertFalse(resolved.contains(worldPoint: Vec3(x: 5, y: 0, z: 10)), "the hole followed its variable")
    }
}
