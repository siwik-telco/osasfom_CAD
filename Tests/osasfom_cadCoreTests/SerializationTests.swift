import XCTest

@testable import osasfom_cadCore

final class SerializationTests: XCTestCase {
    private func makeRichState() -> CADModelState {
        var state = CADModelState(name: "Patch", lengthUnit: .millimeter)
        state.variables = [
            CADVariable(name: "w", value: 40, comment: "width"),
            CADVariable(name: "half", expression: Expression(source: "w / 2"))
        ]
        state.bodies = [
            CADBody(
                name: "Substrate",
                primitive: .box(
                    BoxSpec(
                        width: Expression(source: "w"),
                        height: Expression(1.6),
                        depth: Expression(source: "w * 0.9")
                    )
                ),
                transform: BodyTransform(
                    position: Vector3Expression(
                        x: Expression(source: "half"),
                        y: Expression(0),
                        z: Expression(0)
                    ),
                    rotationDegrees: Vector3Expression(Vec3(x: 0, y: 30, z: 0))
                ),
                materialID: MaterialLibrary.fr4ID,
                priority: 10
            ),
            CADBody(
                name: "Probe",
                primitive: .cylinder(
                    CylinderSpec(radius: Expression(0.6), length: Expression(4), axis: .x)
                ),
                materialID: MaterialLibrary.copperID,
                priority: 20
            ),
            CADBody(
                name: "Ground",
                primitive: .sheet(
                    SheetSpec(
                        width: Expression(60),
                        depth: Expression(60),
                        thickness: Expression(0),
                        normal: .y
                    )
                ),
                materialID: MaterialLibrary.pecID,
                priority: 30
            )
        ]
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
        state.simulation.mesh.refinements = [
            MeshRefinement(
                name: "Feed region",
                region: BoundsExpression(BodyBounds(center: .zero, size: Vec3(repeating: 4))),
                targetCellSize: Expression(source: "w / 100")
            )
        ]
        return state
    }

    // MARK: - Project round trip

    func testProjectRoundTripsExactly() throws {
        let original = makeRichState()
        let data = try ProjectSerializer.encode(original)
        let decoded = try ProjectSerializer.decode(data)
        XCTAssertEqual(decoded, original)
    }

    /// Expressions must survive as source text, not as baked-in numbers.
    func testExpressionsArePersistedAsSource() throws {
        let data = try ProjectSerializer.encode(makeRichState())
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"w * 0.9\""))
        XCTAssertTrue(json.contains("\"half\""))
        XCTAssertFalse(json.contains("\"36\""), "the resolved value must not be persisted")
    }

    func testPrimitiveJSONIsFlatAndDiscriminated() throws {
        let primitive = Primitive.cylinder(
            CylinderSpec(radius: Expression(2), length: Expression(10), axis: .z)
        )
        let data = try JSONEncoder().encode(primitive)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, "cylinder")
        XCTAssertEqual(object["radius"] as? String, "2")
        XCTAssertEqual(object["axis"] as? String, "z")
        XCTAssertNil(object["_0"], "the payload must not be nested under a synthesised key")

        let decoded = try JSONDecoder().decode(Primitive.self, from: data)
        XCTAssertEqual(decoded, primitive)
    }

    func testRejectsAFutureFormatVersion() throws {
        let data = try XCTUnwrap(#"{"formatVersion": 99, "generator": "x", "state": {}}"#.data(using: .utf8))
        XCTAssertThrowsError(try ProjectSerializer.decode(data)) { error in
            guard case ProjectFileError.unsupportedVersion = error else {
                return XCTFail("expected an unsupported-version error, got \(error)")
            }
        }
    }

    // MARK: - Legacy import

    func testLegacyVersionOneProjectImports() throws {
        // The shape the original prototype wrote: flat parameters, name-based
        // variable bindings, `units` as a string, no simulation.
        let legacy = """
        {
          "units": "mm",
          "variables": [
            {"id": "\(UUID().uuidString)", "name": "patch_w", "value": 40, "description": "width"}
          ],
          "materials": [],
          "bodies": [
            {
              "id": "\(UUID().uuidString)",
              "name": "Patch",
              "primitive": "box",
              "parameters": {"size": {"x": 40, "y": 1.6, "z": 30}, "radius": 5, "height": 20},
              "transform": {
                "position": {"x": 1, "y": 2, "z": 3},
                "rotationDegrees": {"x": 0, "y": 0, "z": 0},
                "scale": {"x": 1, "y": 1, "z": 1}
              },
              "variableBindings": {"width": "patch_w"},
              "isVisible": true
            },
            {
              "id": "\(UUID().uuidString)",
              "name": "Probe",
              "primitive": "cylinder",
              "parameters": {"size": {"x": 5, "y": 5, "z": 5}, "radius": 2.5, "height": 30},
              "variableBindings": {}
            }
          ]
        }
        """
        let state = try ProjectSerializer.decode(try XCTUnwrap(legacy.data(using: .utf8)))

        XCTAssertEqual(state.lengthUnit, .millimeter)
        XCTAssertEqual(state.bodies.count, 2)

        // A binding becomes a real expression; unbound dimensions keep their number.
        let patch = try XCTUnwrap(state.bodies.first?.primitive.boxSpec)
        XCTAssertEqual(patch.width.source, "patch_w")
        XCTAssertEqual(patch.height.source, "1.6")
        XCTAssertEqual(state.bodies[0].transform.position.x.source, "1")

        let probe = try XCTUnwrap(state.bodies[1].primitive.cylinderSpec)
        XCTAssertEqual(probe.radius.source, "2.5")
        XCTAssertEqual(probe.length.source, "30")
        XCTAssertEqual(probe.axis, .y, "v1 cylinders were always Y-aligned")

        // The new library entries are topped up, and the whole thing resolves.
        XCTAssertTrue(state.materials.contains { $0.id == MaterialLibrary.pecID })
        XCTAssertFalse(ModelResolver.resolve(state).diagnostics.hasErrors)
    }

    // MARK: - Solver export

    func testSolverExportIsSIAndPriorityOrdered() throws {
        var state = makeRichState()
        state.simulation.domain.mode = .manual
        state.simulation.domain.manualBounds = BoundsExpression(
            BodyBounds(center: .zero, size: Vec3(repeating: 400))
        )

        let resolved = ModelResolver.resolve(state)
        XCTAssertFalse(resolved.diagnostics.hasErrors, "\(resolved.diagnostics.errors)")

        let export = try SolverExportEncoder.makeExport(state: state, resolved: resolved)

        XCTAssertEqual(export.meta.metersPerDisplayUnit, 1e-3)
        XCTAssertEqual(export.bodies.map(\.name), ["Ground", "Probe", "Substrate"])

        // 60 mm sheet → 0.06 m.
        let ground = try XCTUnwrap(export.bodies.first)
        XCTAssertEqual(try XCTUnwrap(ground.shape.size).x, 0.06, accuracy: 1e-12)
        XCTAssertEqual(ground.shape.isZeroThickness, true)

        // The substrate is rotated 30°, so its exported AABB must be the true one.
        let substrate = try XCTUnwrap(export.bodies.first { $0.name == "Substrate" })
        XCTAssertGreaterThan(
            substrate.axisAlignedBoundsMeters.xMax - substrate.axisAlignedBoundsMeters.xMin,
            0.040,
            "a 30° rotation must widen the exported bounding box beyond the 40 mm width"
        )

        // Only materials in use are emitted.
        XCTAssertEqual(Set(export.materials.map(\.name)), ["FR-4", "Copper", "PEC"])
        let pec = try XCTUnwrap(export.materials.first { $0.name == "PEC" })
        XCTAssertEqual(pec.kind, "perfectElectricConductor")
        XCTAssertNil(pec.epsilonR, "ε is meaningless for a PEC boundary")

        XCTAssertEqual(export.ports.count, 1)
        XCTAssertEqual(try XCTUnwrap(export.ports.first).gapLengthMeters, 0.0016, accuracy: 1e-12)
    }

    /// A deck that silently omits a broken body is worse than no deck.
    func testSolverExportRefusesWhileTheModelHasErrors() {
        var state = makeRichState()
        state.bodies.append(
            CADBody(
                name: "Broken",
                primitive: .box(
                    BoxSpec(
                        width: Expression(source: "does_not_exist"),
                        height: Expression(1),
                        depth: Expression(1)
                    )
                )
            )
        )
        let resolved = ModelResolver.resolve(state)
        XCTAssertThrowsError(
            try SolverExportEncoder.makeExport(state: state, resolved: resolved)
        ) { error in
            guard case SolverExportError.modelHasErrors = error else {
                return XCTFail("expected modelHasErrors, got \(error)")
            }
        }
    }

    func testSolverExportEncodesToJSON() throws {
        var state = makeRichState()
        state.simulation.domain.mode = .manual
        state.simulation.domain.manualBounds = BoundsExpression(
            BodyBounds(center: .zero, size: Vec3(repeating: 400))
        )
        let data = try SolverExportEncoder.encode(
            state: state,
            resolved: ModelResolver.resolve(state)
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["meta"])
        XCTAssertNotNil(object["domainMeters"])
        XCTAssertNotNil(object["boundaries"])
        XCTAssertNotNil(object["mesh"])
        XCTAssertNotNil(object["ports"])
    }
}
