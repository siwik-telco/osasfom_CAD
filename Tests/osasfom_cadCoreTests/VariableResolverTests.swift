import XCTest

@testable import osasfom_cadCore

final class VariableResolverTests: XCTestCase {
    func testChainedVariablesResolveInDependencyOrder() {
        let resolved = VariableResolver.resolve([
            CADVariable(name: "c", expression: Expression(source: "a + b")),
            CADVariable(name: "a", value: 2),
            CADVariable(name: "b", expression: Expression(source: "a * 3"))
        ])

        XCTAssertEqual(resolved.values["a"], 2)
        XCTAssertEqual(resolved.values["b"], 6)
        XCTAssertEqual(resolved.values["c"], 8)
        XCTAssertTrue(resolved.diagnostics.isEmpty)
    }

    func testDirectCycleIsReportedNotHung() {
        let resolved = VariableResolver.resolve([
            CADVariable(name: "a", expression: Expression(source: "b + 1")),
            CADVariable(name: "b", expression: Expression(source: "a + 1"))
        ])

        XCTAssertNil(resolved.values["a"])
        XCTAssertNil(resolved.values["b"])
        XCTAssertTrue(resolved.diagnostics.hasErrors)
        XCTAssertTrue(
            resolved.diagnostics.contains { $0.message.contains("Circular reference") }
        )
    }

    func testSelfReferenceIsACycle() {
        let resolved = VariableResolver.resolve([
            CADVariable(name: "a", expression: Expression(source: "a"))
        ])
        XCTAssertNil(resolved.values["a"])
        XCTAssertTrue(resolved.diagnostics.hasErrors)
    }

    /// A broken variable must not leave a stale value behind for dependents.
    func testDependentsOfABrokenVariableAlsoFail() {
        let resolved = VariableResolver.resolve([
            CADVariable(name: "a", expression: Expression(source: "1 / 0")),
            CADVariable(name: "b", expression: Expression(source: "a * 2"))
        ])
        XCTAssertNil(resolved.values["a"])
        XCTAssertNil(resolved.values["b"])
    }

    func testDuplicateNamesAreReported() {
        let resolved = VariableResolver.resolve([
            CADVariable(name: "w", value: 1),
            CADVariable(name: "w", value: 2)
        ])
        XCTAssertEqual(resolved.values["w"], 1, "first definition wins")
        XCTAssertTrue(
            resolved.diagnostics.contains { $0.message.contains("already uses that name") }
        )
    }

    func testReservedAndMalformedNamesAreRejected() {
        XCTAssertEqual(CADVariable.nameProblem(for: "pi"), .reserved)
        XCTAssertEqual(CADVariable.nameProblem(for: "sqrt"), .reserved)
        XCTAssertEqual(CADVariable.nameProblem(for: "2w"), .leadingDigit)
        XCTAssertEqual(CADVariable.nameProblem(for: "a-b"), .invalidCharacters)
        XCTAssertEqual(CADVariable.nameProblem(for: "   "), .empty)
        XCTAssertNil(CADVariable.nameProblem(for: "patch_w2"))

        let resolved = VariableResolver.resolve([CADVariable(name: "pi", value: 3)])
        XCTAssertNil(resolved.values["pi"], "a reserved name must not shadow the constant")
        XCTAssertTrue(resolved.diagnostics.hasErrors)
    }

    func testRenamingAVariableRewritesEveryReference() {
        var state = CADModelState()
        let width = CADVariable(name: "w", value: 10)
        state.variables = [width, CADVariable(name: "half", expression: Expression(source: "w / 2"))]
        state.bodies = [
            CADBody(
                name: "Box",
                primitive: .box(
                    BoxSpec(
                        width: Expression(source: "w"),
                        height: Expression(source: "w * 2"),
                        depth: Expression(1)
                    )
                ),
                transform: BodyTransform(
                    position: Vector3Expression(
                        x: Expression(source: "w / 4"),
                        y: Expression(0),
                        z: Expression(0)
                    )
                )
            )
        ]
        state.simulation.domain.padding = Vector3Expression(
            x: Expression(source: "w"),
            y: Expression(0),
            z: Expression(0)
        )

        state.renameVariable(id: width.id, to: "patch_w")

        XCTAssertEqual(state.variables[0].name, "patch_w")
        XCTAssertEqual(state.variables[1].expression.source, "patch_w / 2")
        XCTAssertEqual(state.bodies[0].primitive.boxSpec?.width.source, "patch_w")
        XCTAssertEqual(state.bodies[0].primitive.boxSpec?.height.source, "patch_w * 2")
        XCTAssertEqual(state.bodies[0].transform.position.x.source, "patch_w / 4")
        XCTAssertEqual(state.simulation.domain.padding.x.source, "patch_w")

        // And the whole thing still resolves, i.e. no dangling references.
        let resolved = ModelResolver.resolve(state)
        XCTAssertFalse(resolved.diagnostics.hasErrors)
        XCTAssertEqual(resolved.bodies.first?.shape.localSize.x, 10)
    }
}
