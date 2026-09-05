import XCTest

@testable import osasfom_cadCore

/// A boolean history is part of the model, so it has to survive a save/load
/// cycle — and adding it must not have made every project file written before
/// it existed unreadable.
final class BooleanSerializationTests: XCTestCase {

    private func makeBodyWithHistory() -> CADBody {
        CADBody(
            name: "Plate",
            primitive: .box(BoxSpec(width: Expression(20), height: Expression(2), depth: Expression(20))),
            booleans: [
                BooleanOperation(
                    kind: .subtract,
                    primitive: .cylinder(
                        CylinderSpec(radius: Expression(source: "hole_r"), begin: Expression(-5), end: Expression(5), axis: .y)
                    )
                ),
                BooleanOperation(
                    kind: .add,
                    primitive: .box(BoxSpec(width: Expression(4), height: Expression(4), depth: Expression(4))),
                    transform: BodyTransform(rotationDegrees: Vector3Expression(Vec3(x: 0, y: 45, z: 0))),
                    isEnabled: false
                )
            ]
        )
    }

    func testBooleanHistoryRoundTripsExactly() throws {
        var state = CADModelState(name: "Booleans")
        state.variables = [CADVariable(name: "hole_r", expression: Expression(3))]
        state.bodies = [makeBodyWithHistory()]

        let restored = try ProjectSerializer.decode(ProjectSerializer.encode(state))

        XCTAssertEqual(restored, state)
        let steps = try XCTUnwrap(restored.bodies.first).booleans
        XCTAssertEqual(steps.map(\.kind), [.subtract, .add])
        XCTAssertEqual(steps[0].primitive.cylinderSpec?.radius.trimmed, "hole_r")
        XCTAssertFalse(steps[1].isEnabled, "a disabled step stays disabled")
    }

    /// The exact shape of a body written before booleans existed: no
    /// `booleans` key at all. It must decode as a plain primitive rather than
    /// failing the whole project load.
    func testABodyWithoutABooleansKeyStillDecodes() throws {
        let json = """
        {
          "id": "5040AD5C-CD6D-4A5E-83FB-F268FC51D7A6",
          "isVisible": true,
          "name": "fr-4",
          "primitive": { "type": "box",
            "beginX": "-1", "endX": "1",
            "beginY": "-1", "endY": "1",
            "beginZ": "0", "endZ": "2" },
          "priority": 0,
          "transform": {
            "position": { "x": "0", "y": "0", "z": "0" },
            "rotationDegrees": { "x": "0", "y": "0", "z": "0" },
            "scale": { "x": "1", "y": "1", "z": "1" }
          }
        }
        """
        let body = try JSONDecoder().decode(CADBody.self, from: Data(json.utf8))
        XCTAssertTrue(body.booleans.isEmpty)
        XCTAssertEqual(body.name, "fr-4")
    }

    /// Renaming a variable rewrites every expression that referenced it. A
    /// tool's expressions are expressions too — missing them would leave a
    /// dangling reference that only shows up as a broken body later.
    func testRenamingAVariableRewritesToolExpressions() {
        var state = CADModelState(name: "Booleans")
        let radius = CADVariable(name: "hole_r", expression: Expression(3))
        state.variables = [radius]
        state.bodies = [makeBodyWithHistory()]

        state.renameVariable(id: radius.id, to: "drill_r")

        let tool = state.bodies[0].booleans[0].primitive.cylinderSpec
        XCTAssertEqual(tool?.radius.trimmed, "drill_r")
    }

    /// Duplicating a body has to deep-copy its history, and give each step a
    /// new identity — otherwise editing the copy's steps would edit the
    /// original's, since the inspector addresses steps by id.
    func testDuplicatingABodyGivesItsStepsFreshIdentities() {
        let original = makeBodyWithHistory()
        let copy = original.duplicated(named: "Plate 2")

        XCTAssertEqual(copy.booleans.count, original.booleans.count)
        XCTAssertEqual(copy.booleans.map(\.kind), original.booleans.map(\.kind))
        XCTAssertTrue(
            Set(copy.booleans.map(\.id)).isDisjoint(with: Set(original.booleans.map(\.id))),
            "a duplicated step must not share an id with the one it came from"
        )
    }
}
