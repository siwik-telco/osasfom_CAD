import Combine
import Foundation

@MainActor
public final class CADDocument: ObservableObject {
    @Published public var units: String
    @Published public var bodies: [CADBody]
    @Published public var materials: [MaterialDefinition]
    @Published public var selectedBodyID: UUID?

    public init(
        units: String = "mm",
        bodies: [CADBody] = [],
        materials: [MaterialDefinition] = MaterialLibrary.defaults(),
        selectedBodyID: UUID? = nil
    ) {
        self.units = units
        self.bodies = bodies
        self.materials = materials
        self.selectedBodyID = selectedBodyID
    }

    public var selectedBodyIndex: Int? {
        guard let selectedBodyID else { return nil }
        return bodies.firstIndex(where: { $0.id == selectedBodyID })
    }

    public func addBody(_ kind: PrimitiveKind) {
        let nextIndex = bodies.filter { $0.primitive == kind }.count + 1
        let body = CADBody.make(kind: kind, index: nextIndex)
        bodies.append(body)
        selectedBodyID = body.id
    }

    public func duplicateSelectedBody() {
        guard let selectedBodyIndex else { return }
        var duplicated = bodies[selectedBodyIndex]
        duplicated = CADBody(
            name: duplicated.name + " Copy",
            primitive: duplicated.primitive,
            parameters: duplicated.parameters,
            transform: BodyTransform(
                position: Vec3(
                    x: duplicated.transform.position.x + 5,
                    y: duplicated.transform.position.y + 5,
                    z: duplicated.transform.position.z + 5
                ),
                rotationDegrees: duplicated.transform.rotationDegrees,
                scale: duplicated.transform.scale
            ),
            materialID: duplicated.materialID,
            isVisible: duplicated.isVisible
        )
        bodies.append(duplicated)
        selectedBodyID = duplicated.id
    }

    public func deleteSelectedBody() {
        guard let selectedBodyIndex else { return }
        bodies.remove(at: selectedBodyIndex)
        selectedBodyID = bodies.last?.id
    }

    public func selectedMaterial(for body: CADBody) -> MaterialDefinition? {
        guard let materialID = body.materialID else { return nil }
        return materials.first(where: { $0.id == materialID })
    }

    public func serializeProjectData() throws -> Data {
        let project = CADProject(units: units, bodies: bodies, materials: materials)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(project)
    }
}
