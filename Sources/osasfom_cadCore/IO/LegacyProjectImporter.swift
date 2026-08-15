import Foundation

/// Reads the original prototype's JSON export.
///
/// That format had a flat `PrimitiveParameters` (size + radius + height for
/// every kind), name-based variable bindings, `units` as a free string, and no
/// simulation setup. Everything that maps cleanly is carried over; bindings
/// become expressions, which is a strict improvement, and anything absent gets
/// today's defaults.
public enum LegacyProjectImporter {
    // MARK: - v1 wire format

    private struct LegacyVec3: Decodable {
        let x: Double
        let y: Double
        let z: Double

        var value: Vec3 { Vec3(x: x, y: y, z: z) }
    }

    private struct LegacyParameters: Decodable {
        let size: LegacyVec3
        let radius: Double
        let height: Double
    }

    private struct LegacyTransform: Decodable {
        let position: LegacyVec3?
        let rotationDegrees: LegacyVec3?
        let scale: LegacyVec3?
    }

    private struct LegacyVariableBindings: Decodable {
        let width: String?
        let height: String?
        let depth: String?
        let radius: String?
    }

    private struct LegacyBody: Decodable {
        let id: UUID
        let name: String
        let primitive: String
        let parameters: LegacyParameters
        let transform: LegacyTransform?
        let variableBindings: LegacyVariableBindings?
        let materialID: UUID?
        let isVisible: Bool?
    }

    private struct LegacyVariable: Decodable {
        let id: UUID
        let name: String
        let value: Double
        let description: String?
    }

    private struct LegacyProject: Decodable {
        let units: String?
        let bodies: [LegacyBody]
        let materials: [MaterialDefinition]?
        let variables: [LegacyVariable]?
    }

    // MARK: - Import

    public static func importVersion1(_ data: Data) throws -> CADModelState {
        let legacy: LegacyProject
        do {
            legacy = try JSONDecoder().decode(LegacyProject.self, from: data)
        } catch {
            throw ProjectFileError.unreadable(underlying: error)
        }

        var state = CADModelState(
            lengthUnit: lengthUnit(fromLegacyUnits: legacy.units),
            variables: (legacy.variables ?? []).map { legacyVariable in
                CADVariable(
                    id: legacyVariable.id,
                    name: legacyVariable.name,
                    value: legacyVariable.value,
                    comment: legacyVariable.description ?? ""
                )
            },
            materials: mergedMaterials(legacy.materials),
            bodies: [],
            simulation: .makeDefault()
        )

        state.bodies = legacy.bodies.map(body(from:))
        return state
    }

    private static func lengthUnit(fromLegacyUnits units: String?) -> LengthUnit {
        guard let units = units?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return .millimeter
        }
        return LengthUnit.allCases.first { unit in
            unit.symbol.lowercased() == units || unit.rawValue == units
        } ?? .millimeter
    }

    /// Keeps any custom materials from the file and tops up with today's
    /// library, so the new PEC and laminate entries appear.
    private static func mergedMaterials(_ legacy: [MaterialDefinition]?) -> [MaterialDefinition] {
        guard let legacy, !legacy.isEmpty else { return MaterialLibrary.defaults() }
        var result = legacy
        let existingIDs = Set(legacy.map(\.id))
        for material in MaterialLibrary.defaults() where !existingIDs.contains(material.id) {
            result.append(material)
        }
        return result
    }

    private static func body(from legacy: LegacyBody) -> CADBody {
        let bindings = legacy.variableBindings
        let size = legacy.parameters.size.value

        /// A binding name becomes the expression outright — the whole point of
        /// the new model. Absent bindings fall back to the baked number.
        func extent(_ binding: String?, fallback: Double) -> Expression {
            guard let name = binding?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return Expression(fallback)
            }
            return Expression(source: name)
        }

        let primitive: Primitive
        switch legacy.primitive {
        case "cylinder":
            primitive = .cylinder(
                CylinderSpec(
                    radius: extent(bindings?.radius, fallback: legacy.parameters.radius),
                    length: extent(bindings?.height, fallback: legacy.parameters.height),
                    // v1 cylinders were always Y-aligned.
                    axis: .y
                )
            )
        case "sheet":
            primitive = .sheet(
                SheetSpec(
                    width: extent(bindings?.width, fallback: size.x),
                    depth: extent(bindings?.depth, fallback: size.z),
                    thickness: extent(bindings?.height, fallback: size.y),
                    normal: .y
                )
            )
        default:
            primitive = .box(
                BoxSpec(
                    width: extent(bindings?.width, fallback: size.x),
                    height: extent(bindings?.height, fallback: size.y),
                    depth: extent(bindings?.depth, fallback: size.z)
                )
            )
        }

        let transform = BodyTransform(
            position: Vector3Expression(legacy.transform?.position?.value ?? .zero),
            rotationDegrees: Vector3Expression(legacy.transform?.rotationDegrees?.value ?? .zero),
            scale: Vector3Expression(legacy.transform?.scale?.value ?? .one)
        )

        return CADBody(
            id: legacy.id,
            name: legacy.name,
            primitive: primitive,
            transform: transform,
            materialID: legacy.materialID,
            priority: 0,
            isVisible: legacy.isVisible ?? true
        )
    }
}
