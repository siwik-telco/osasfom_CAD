import Combine
import Foundation

@MainActor
public final class CADDocument: ObservableObject {
    @Published public var units: String
    @Published public var bodies: [CADBody]
    @Published public var materials: [MaterialDefinition]
    @Published public var variables: [CADVariable]
    @Published public var selectedBodyID: UUID?

    public init(
        units: String = "mm",
        bodies: [CADBody] = [],
        materials: [MaterialDefinition] = MaterialLibrary.defaults(),
        variables: [CADVariable] = [],
        selectedBodyID: UUID? = nil
    ) {
        self.units = units
        self.bodies = bodies
        self.materials = materials
        self.variables = variables
        self.selectedBodyID = selectedBodyID
        applyVariablesToBodies()
    }

    public var selectedBodyIndex: Int? {
        guard let selectedBodyID else { return nil }
        return bodies.firstIndex(where: { $0.id == selectedBodyID })
    }

    public func addBody(_ kind: PrimitiveKind) {
        let body = CADBody.make(kind: kind, index: nextIndex(for: kind))
        bodies.append(body)
        selectedBodyID = body.id
    }

    public func addBody(_ kind: PrimitiveKind, bounds: BodyBounds, name: String? = nil) {
        let body = CADBody.make(kind: kind, index: nextIndex(for: kind), bounds: bounds, name: name)
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
            variableBindings: duplicated.variableBindings,
            materialID: duplicated.materialID,
            isVisible: duplicated.isVisible
        )
        duplicated.applyVariables(variableValuesByName())
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

    public func applyVariablesToBodies() {
        let values = variableValuesByName()
        for index in bodies.indices {
            bodies[index].applyVariables(values)
        }
    }

    public func variableNames() -> [String] {
        variables
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    private func variableValuesByName() -> [String: Double] {
        variables.reduce(into: [String: Double]()) { partialResult, variable in
            let trimmedName = variable.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { return }
            partialResult[trimmedName] = variable.value
        }
    }

    private func nextIndex(for kind: PrimitiveKind) -> Int {
        bodies.filter { $0.primitive == kind }.count + 1
    }

    public func serializeProjectData() throws -> Data {
        let project = CADProject(units: units, bodies: bodies, materials: materials, variables: variables)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(project)
    }
}
