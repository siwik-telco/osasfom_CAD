import XCTest

@testable import osasfom_cadCore

final class ModelResolverTests: XCTestCase {
    private func makeState(bodies: [CADBody], variables: [CADVariable] = []) -> CADModelState {
        var state = CADModelState()
        state.variables = variables
        state.bodies = bodies
        // Manual domain keeps these tests independent of automatic padding.
        state.simulation.domain.mode = .manual
        state.simulation.domain.manualBounds = BoundsExpression(
            BodyBounds(center: .zero, size: Vec3(repeating: 1000))
        )
        return state
    }

    func testParametricBodyResolvesFromVariables() {
        let state = makeState(
            bodies: [
                CADBody(
                    name: "Patch",
                    primitive: .box(
                        BoxSpec(
                            width: Expression(source: "w"),
                            height: Expression(source: "h"),
                            depth: Expression(source: "w * 0.95")
                        )
                    )
                )
            ],
            variables: [
                CADVariable(name: "w", value: 40),
                CADVariable(name: "h", value: 1.6)
            ]
        )

        let resolved = ModelResolver.resolve(state)
        let body = try? XCTUnwrap(resolved.bodies.first)
        XCTAssertEqual(body?.shape.localSize.x, 40)
        XCTAssertEqual(body?.shape.localSize.y, 1.6)
        XCTAssertEqual(body?.shape.localSize.z, 38)
        XCTAssertFalse(resolved.diagnostics.hasErrors)
    }

    /// The model stores source text, so a resolve must never write numbers back.
    func testResolvingIsPureAndRepeatable() {
        let state = makeState(
            bodies: [
                CADBody(
                    name: "Box",
                    primitive: .box(
                        BoxSpec(
                            width: Expression(source: "w"),
                            height: Expression(1),
                            depth: Expression(1)
                        )
                    )
                )
            ],
            variables: [CADVariable(name: "w", value: 5)]
        )

        let first = ModelResolver.resolve(state)
        let second = ModelResolver.resolve(state)

        XCTAssertEqual(state.bodies[0].primitive.boxSpec?.width.source, "w")
        XCTAssertEqual(first.bodies.first?.shape, second.bodies.first?.shape)
        XCTAssertEqual(first.diagnostics.map(\.id), second.diagnostics.map(\.id))
    }

    /// A broken body drops out with an error rather than rendering stale numbers.
    func testUnresolvableBodyIsExcludedAndReported() {
        let body = CADBody(
            name: "Broken",
            primitive: .box(
                BoxSpec(
                    width: Expression(source: "missing_variable"),
                    height: Expression(1),
                    depth: Expression(1)
                )
            )
        )
        let resolved = ModelResolver.resolve(makeState(bodies: [body]))

        XCTAssertTrue(resolved.bodies.isEmpty)
        XCTAssertTrue(resolved.failedBodyIDs.contains(body.id))
        XCTAssertTrue(resolved.diagnostics(for: .body(body.id)).hasErrors)
    }

    func testNegativeAndZeroExtentsAreErrorsExceptSheetThickness() {
        let badBox = CADBody(
            name: "Bad",
            primitive: .box(
                BoxSpec(width: Expression(0), height: Expression(1), depth: Expression(1))
            )
        )
        let boxResult = ModelResolver.resolve(makeState(bodies: [badBox]))
        XCTAssertTrue(boxResult.diagnostics(for: .body(badBox.id)).hasErrors)
        XCTAssertTrue(boxResult.bodies.isEmpty)

        // A zero-thickness sheet is a legitimate FDTD construct and must survive.
        let sheet = CADBody(
            name: "Ground",
            primitive: .sheet(
                SheetSpec(
                    width: Expression(50),
                    depth: Expression(50),
                    thickness: Expression(0),
                    normal: .y
                )
            )
        )
        let sheetResult = ModelResolver.resolve(makeState(bodies: [sheet]))
        XCTAssertEqual(sheetResult.bodies.count, 1)
        XCTAssertFalse(sheetResult.diagnostics(for: .body(sheet.id)).hasErrors)
        XCTAssertEqual(sheetResult.bodies.first?.shape.localSize.y, 0)
    }

    func testCylinderRequiresPositiveRadiusAndLength() {
        let body = CADBody(
            name: "Probe",
            primitive: .cylinder(
                CylinderSpec(radius: Expression(0), length: Expression(-5), axis: .x)
            )
        )
        let resolved = ModelResolver.resolve(makeState(bodies: [body]))
        let messages = resolved.diagnostics(for: .body(body.id)).map(\.message)
        XCTAssertTrue(messages.contains { $0.contains("Radius") })
        XCTAssertTrue(messages.contains { $0.contains("Length") })
    }

    func testOverlappingBodiesAtEqualPriorityAreWarnedAbout() {
        let substrate = CADBody(
            name: "Substrate",
            primitive: .box(
                BoxSpec(width: Expression(10), height: Expression(10), depth: Expression(10))
            ),
            materialID: MaterialLibrary.fr4ID,
            priority: 0
        )
        let patch = CADBody(
            name: "Patch",
            primitive: .box(
                BoxSpec(width: Expression(4), height: Expression(4), depth: Expression(4))
            ),
            materialID: MaterialLibrary.copperID,
            priority: 0
        )

        let ambiguous = ModelResolver.resolve(makeState(bodies: [substrate, patch]))
        XCTAssertTrue(
            ambiguous.diagnostics.contains { $0.message.contains("same priority") },
            "overlap at equal priority is ambiguous for a voxeliser"
        )

        var distinct = patch
        distinct.priority = 10
        let unambiguous = ModelResolver.resolve(makeState(bodies: [substrate, distinct]))
        XCTAssertFalse(unambiguous.diagnostics.contains { $0.message.contains("same priority") })
    }

    func testMaterialAssignmentOrderPutsHighestPriorityFirst() {
        var state = makeState(bodies: [])
        state.bodies = [
            CADBody(name: "Low", primitive: .defaultBox, priority: 0),
            CADBody(name: "High", primitive: .defaultBox, priority: 30),
            CADBody(name: "Mid", primitive: .defaultBox, priority: 10)
        ]
        XCTAssertEqual(state.materialAssignmentOrder.map(\.name), ["High", "Mid", "Low"])
    }

    func testDuplicateBodyNamesAreWarnedAbout() {
        let state = makeState(bodies: [
            CADBody(name: "Patch", primitive: .defaultBox),
            CADBody(name: "Patch", primitive: .defaultBox)
        ])
        let resolved = ModelResolver.resolve(state)
        XCTAssertTrue(resolved.diagnostics.contains { $0.message.contains("also called") })
    }

    func testUniqueNamingSurvivesDeletion() {
        var state = CADModelState()
        state.bodies = [
            CADBody(name: "Box", primitive: .defaultBox),
            CADBody(name: "Box 2", primitive: .defaultBox),
            CADBody(name: "Box 3", primitive: .defaultBox)
        ]
        // Delete the middle one: the old "count + 1" scheme would now collide.
        state.bodies.remove(at: 1)
        XCTAssertEqual(state.uniqueBodyName(base: "Box"), "Box 2")
        state.bodies.append(CADBody(name: "Box 2", primitive: .defaultBox))
        XCTAssertEqual(state.uniqueBodyName(base: "Box"), "Box 4")
    }

    // MARK: - Simulation

    func testAutomaticDomainWrapsTheModelWithPadding() {
        var state = makeState(bodies: [
            CADBody(
                name: "Box",
                primitive: .box(
                    BoxSpec(width: Expression(10), height: Expression(10), depth: Expression(10))
                )
            )
        ])
        state.simulation.domain.mode = .automatic
        state.simulation.domain.padding = Vector3Expression(Vec3(repeating: 5))

        let domain = try? XCTUnwrap(ModelResolver.resolve(state).simulation.domain)
        XCTAssertEqual(domain?.xMin, -10)
        XCTAssertEqual(domain?.xMax, 10)
    }

    func testDegeneratePortIsRejected() {
        var state = makeState(bodies: [])
        state.simulation.ports = [
            SimulationPort(
                name: "Feed",
                region: BoundsExpression(BodyBounds(center: .zero, size: .zero)),
                direction: .y
            )
        ]
        let resolved = ModelResolver.resolve(state)
        XCTAssertTrue(resolved.simulation.ports.isEmpty)
        XCTAssertTrue(resolved.diagnostics.hasErrors)
    }

    func testValidLumpedPortResolves() {
        var state = makeState(bodies: [])
        state.simulation.ports = [
            SimulationPort(
                name: "Feed",
                region: BoundsExpression(
                    xMin: Expression(0), xMax: Expression(0),
                    yMin: Expression(0), yMax: Expression(1.6),
                    zMin: Expression(0), zMax: Expression(0)
                ),
                direction: .y
            )
        ]
        let resolved = ModelResolver.resolve(state)
        XCTAssertEqual(resolved.simulation.ports.count, 1)
        XCTAssertEqual(resolved.simulation.ports.first?.gapLength, 1.6)
    }

    func testMismatchedPeriodicBoundariesAreRejected() {
        var state = makeState(bodies: [])
        state.simulation.boundaries.setLower(.periodic, on: .x)
        let resolved = ModelResolver.resolve(state)
        XCTAssertTrue(resolved.diagnostics.contains { $0.message.contains("both X faces") })
    }

    func testMeshCellSizeFollowsTheWavelengthCriterion() {
        var state = makeState(bodies: [])
        state.lengthUnit = .millimeter
        state.simulation.frequency = FrequencyRange(minimumHertz: 1e9, maximumHertz: 10e9)
        state.simulation.mesh.cellsPerWavelength = 20
        // Only vacuum is in use, so n = 1 and λ = 29.98 mm at 10 GHz.
        state.materials = [MaterialLibrary.vacuum]

        let plan = ModelResolver.resolve(state).simulation.mesh
        XCTAssertEqual(try XCTUnwrap(plan.wavelengthLimitedCellSize), 1.4989, accuracy: 1e-3)
    }

    func testHighPermittivityShrinksTheCellSize() {
        var state = makeState(bodies: [])
        state.simulation.frequency = FrequencyRange(minimumHertz: 1e9, maximumHertz: 10e9)
        state.materials = [MaterialLibrary.vacuum]
        let vacuumOnly = try? XCTUnwrap(
            ModelResolver.resolve(state).simulation.mesh.wavelengthLimitedCellSize
        )

        state.materials.append(
            MaterialDefinition(name: "High-K", color: .neutralGray, epsilonR: 9)
        )
        let withDielectric = try? XCTUnwrap(
            ModelResolver.resolve(state).simulation.mesh.wavelengthLimitedCellSize
        )

        // n = 3, so cells must be three times smaller.
        XCTAssertEqual(
            try XCTUnwrap(withDielectric),
            try XCTUnwrap(vacuumOnly) / 3,
            accuracy: 1e-9
        )
    }

    func testCourantFactorAboveOneIsAnError() {
        var state = makeState(bodies: [])
        state.simulation.solver.courantFactor = 1.5
        XCTAssertTrue(
            ModelResolver.resolve(state).diagnostics.contains { $0.message.contains("unstable") }
        )
    }
}
