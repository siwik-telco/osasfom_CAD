import Foundation

/// The complete editable state of a project.
///
/// One `Equatable` value holding everything makes snapshot undo trivial and
/// exactly correct, and gives serialisation a single root.
public struct CADModelState: Codable, Hashable, Sendable, ExpressionWalkable {
    public var name: String
    public var lengthUnit: LengthUnit
    public var variables: [CADVariable]
    public var materials: [MaterialDefinition]
    public var bodies: [CADBody]
    public var simulation: SimulationSetup

    public init(
        name: String = "Untitled",
        lengthUnit: LengthUnit = .millimeter,
        variables: [CADVariable] = [],
        materials: [MaterialDefinition] = MaterialLibrary.defaults(),
        bodies: [CADBody] = [],
        simulation: SimulationSetup = .makeDefault()
    ) {
        self.name = name
        self.lengthUnit = lengthUnit
        self.variables = variables
        self.materials = materials
        self.bodies = bodies
        self.simulation = simulation
    }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        for index in variables.indices { variables[index].walkExpressions(transform) }
        for index in bodies.indices { bodies[index].walkExpressions(transform) }
        simulation.walkExpressions(transform)
    }

    // MARK: - Lookups

    public func body(id: UUID) -> CADBody? {
        bodies.first { $0.id == id }
    }

    public func bodyIndex(id: UUID) -> Int? {
        bodies.firstIndex { $0.id == id }
    }

    public func material(id: UUID?) -> MaterialDefinition? {
        guard let id else { return nil }
        return materials.first { $0.id == id }
    }

    /// The material a body actually gets, falling back to the documented
    /// default rather than leaving it undefined.
    public func effectiveMaterial(for body: CADBody) -> MaterialDefinition {
        material(id: body.materialID)
            ?? material(id: MaterialLibrary.defaultMaterialID)
            ?? MaterialLibrary.vacuum
    }

    public func variable(id: UUID) -> CADVariable? {
        variables.first { $0.id == id }
    }

    // MARK: - Naming

    /// A name not already taken, by appending or bumping a numeric suffix.
    ///
    /// Replaces the old "count bodies of this kind + 1", which produced
    /// duplicates as soon as anything was deleted.
    public func uniqueBodyName(base: String) -> String {
        uniqueName(base: base, taken: Set(bodies.map(\.name)))
    }

    public func uniqueVariableName(base: String) -> String {
        uniqueName(base: base, taken: Set(variables.map(\.trimmedName)))
    }

    public func uniquePortName(base: String) -> String {
        uniqueName(base: base, taken: Set(simulation.ports.map(\.name)))
    }

    public func uniqueMonitorName(base: String) -> String {
        uniqueName(base: base, taken: Set(simulation.monitors.map(\.name)))
    }

    public func uniqueMaterialName(base: String) -> String {
        uniqueName(base: base, taken: Set(materials.map(\.name)))
    }

    private func uniqueName(base: String, taken: Set<String>) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = trimmed.isEmpty ? "Item" : trimmed
        guard taken.contains(root) else { return root }

        // Strip an existing trailing number so "Box 2" grows to "Box 3", not
        // "Box 2 2".
        var stem = root
        if let range = root.range(of: #" \d+$"#, options: .regularExpression) {
            stem = String(root[root.startIndex..<range.lowerBound])
        }

        var index = 2
        while taken.contains("\(stem) \(index)") {
            index += 1
        }
        return "\(stem) \(index)"
    }

    /// Renames a variable and rewrites every expression that referenced it, so
    /// the rename cannot leave dangling references behind.
    public mutating func renameVariable(id: UUID, to newName: String) {
        guard let index = variables.firstIndex(where: { $0.id == id }) else { return }
        let oldName = variables[index].trimmedName
        let trimmedNewName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        variables[index].name = trimmedNewName

        guard !oldName.isEmpty, !trimmedNewName.isEmpty, oldName != trimmedNewName else { return }
        walkExpressions { expression in
            expression = expression.renamingVariable(oldName, to: trimmedNewName)
        }
    }

    /// Bodies in the order a voxeliser should apply them: highest priority first,
    /// later bodies winning ties.
    public var materialAssignmentOrder: [CADBody] {
        bodies.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.priority != rhs.element.priority {
                    return lhs.element.priority > rhs.element.priority
                }
                return lhs.offset > rhs.offset
            }
            .map(\.element)
    }
}
