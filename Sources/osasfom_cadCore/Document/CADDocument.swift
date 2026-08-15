import Combine
import Foundation

/// The editable document.
///
/// Every mutation goes through `perform`, which is the one place that snapshots
/// for undo, re-resolves the model, and marks the file dirty. Views never mutate
/// `state` directly, so those three things cannot drift apart.
@MainActor
public final class CADDocument: ObservableObject {
    @Published public private(set) var state: CADModelState
    /// Derived geometry and diagnostics. Recomputed on every accepted mutation.
    @Published public private(set) var resolved: ResolvedModel
    @Published public var selectedBodyID: UUID?
    @Published public var selectedPortID: UUID?
    @Published public private(set) var fileURL: URL?
    @Published public private(set) var hasUnsavedChanges: Bool = false
    @Published public private(set) var canUndo: Bool = false
    @Published public private(set) var canRedo: Bool = false
    @Published public private(set) var undoActionName: String?
    @Published public private(set) var redoActionName: String?

    private var undoStack = UndoStack()

    public init(state: CADModelState = CADModelState()) {
        self.state = state
        self.resolved = ModelResolver.resolve(state)
    }

    /// A project with a small patch-antenna-shaped starting point, so the
    /// parametric workflow is visible immediately.
    public static func makeStarterDocument() -> CADDocument {
        var state = CADModelState(name: "Untitled")

        let frequency = CADVariable(name: "f0_GHz", value: 2.45, comment: "Design frequency")
        let lambda = CADVariable(
            name: "lambda",
            expression: Expression(source: "c0 / (f0_GHz * 1e9) * 1000"),
            comment: "Free-space wavelength in mm"
        )
        let substrateHeight = CADVariable(name: "h_sub", value: 1.6, comment: "Substrate thickness")
        let patchWidth = CADVariable(
            name: "patch_w",
            expression: Expression(source: "0.49 * lambda / sqrt(4.3)"),
            comment: "Approximate half-wave patch width in FR-4"
        )
        let patchLength = CADVariable(
            name: "patch_l",
            expression: Expression(source: "patch_w * 0.95"),
            comment: "Patch length"
        )
        let groundMargin = CADVariable(
            name: "gnd_margin",
            expression: Expression(source: "lambda / 6"),
            comment: "Ground plane margin around the patch"
        )
        state.variables = [frequency, lambda, substrateHeight, patchWidth, patchLength, groundMargin]

        let groundSizeWidth = Expression(source: "patch_w + 2 * gnd_margin")
        let groundSizeDepth = Expression(source: "patch_l + 2 * gnd_margin")

        let ground = CADBody(
            name: "Ground",
            primitive: .sheet(
                SheetSpec(
                    width: groundSizeWidth,
                    depth: groundSizeDepth,
                    thickness: Expression(0),
                    normal: .y
                )
            ),
            transform: BodyTransform(position: Vector3Expression(Vec3.zero)),
            materialID: MaterialLibrary.pecID,
            priority: 20
        )

        let substrate = CADBody(
            name: "Substrate",
            primitive: .box(
                BoxSpec(width: groundSizeWidth, height: Expression(source: "h_sub"), depth: groundSizeDepth)
            ),
            transform: BodyTransform(
                position: Vector3Expression(
                    x: Expression(0),
                    y: Expression(source: "h_sub / 2"),
                    z: Expression(0)
                )
            ),
            materialID: MaterialLibrary.fr4ID,
            priority: 10
        )

        let patch = CADBody(
            name: "Patch",
            primitive: .sheet(
                SheetSpec(
                    width: Expression(source: "patch_w"),
                    depth: Expression(source: "patch_l"),
                    thickness: Expression(0),
                    normal: .y
                )
            ),
            transform: BodyTransform(
                position: Vector3Expression(
                    x: Expression(0),
                    y: Expression(source: "h_sub"),
                    z: Expression(0)
                )
            ),
            materialID: MaterialLibrary.pecID,
            priority: 30
        )

        state.bodies = [ground, substrate, patch]
        state.simulation.frequency = FrequencyRange(minimumHertz: 1.5e9, maximumHertz: 3.5e9)
        state.simulation.domain.padding = Vector3Expression(
            x: Expression(source: "lambda / 4"),
            y: Expression(source: "lambda / 4"),
            z: Expression(source: "lambda / 4")
        )
        state.simulation.ports = [
            Port(
                name: "Feed",
                kind: .lumped,
                region: BoundsExpression(
                    xMin: Expression(source: "patch_w / 6"),
                    xMax: Expression(source: "patch_w / 6"),
                    yMin: Expression(0),
                    yMax: Expression(source: "h_sub"),
                    zMin: Expression(0),
                    zMax: Expression(0)
                ),
                direction: .y,
                impedanceOhm: 50
            )
        ]
        state.simulation.monitors = [
            FieldMonitor(
                name: "Far field @ f0",
                quantity: .farField,
                region: .wholeDomain,
                frequenciesHertz: [2.45e9]
            )
        ]

        let document = CADDocument(state: state)
        document.selectedBodyID = patch.id
        return document
    }

    // MARK: - Mutation

    /// The single mutation entry point.
    ///
    /// - Parameters:
    ///   - actionName: shown in the Undo menu item.
    ///   - coalescingKey: consecutive mutations with the same key form one undo
    ///     step. Use a per-field key such as `"body.<uuid>.width"` for text
    ///     fields, and `nil` for discrete commands.
    public func perform(
        _ actionName: String,
        coalescingKey: String? = nil,
        _ mutation: (inout CADModelState) -> Void
    ) {
        var draft = state
        mutation(&draft)
        guard draft != state else { return }

        undoStack.record(
            previousState: state,
            actionName: actionName,
            coalescingKey: coalescingKey
        )
        apply(draft, markDirty: true)
    }

    /// Ends the current coalescing run — call when focus leaves a field.
    public func endEditingSession() {
        undoStack.breakCoalescing()
    }

    private func apply(_ newState: CADModelState, markDirty: Bool) {
        state = newState
        resolved = ModelResolver.resolve(newState)
        if markDirty { hasUnsavedChanges = true }
        refreshSelection()
        refreshUndoState()
    }

    private func refreshSelection() {
        if let selectedBodyID, state.bodyIndex(id: selectedBodyID) == nil {
            self.selectedBodyID = nil
        }
        if let selectedPortID, !state.simulation.ports.contains(where: { $0.id == selectedPortID }) {
            self.selectedPortID = nil
        }
    }

    private func refreshUndoState() {
        canUndo = undoStack.canUndo
        canRedo = undoStack.canRedo
        undoActionName = undoStack.undoActionName
        redoActionName = undoStack.redoActionName
    }

    public func undo() {
        guard let result = undoStack.undo(current: state) else { return }
        apply(result.state, markDirty: true)
    }

    public func redo() {
        guard let result = undoStack.redo(current: state) else { return }
        apply(result.state, markDirty: true)
    }

    // MARK: - Selection helpers

    public var selectedBody: CADBody? {
        guard let selectedBodyID else { return nil }
        return state.body(id: selectedBodyID)
    }

    public var selectedResolvedBody: ResolvedBody? {
        resolved.body(id: selectedBodyID)
    }

    public var selectedPort: Port? {
        guard let selectedPortID else { return nil }
        return state.simulation.ports.first { $0.id == selectedPortID }
    }

    // MARK: - Bodies

    @discardableResult
    public func addBody(_ kind: PrimitiveKind, name: String? = nil) -> UUID {
        let resolvedName = state.uniqueBodyName(base: name ?? kind.displayName)
        let body = CADBody.make(kind: kind, name: resolvedName)
        perform("Add \(kind.displayName)") { state in
            state.bodies.append(body)
        }
        selectedBodyID = body.id
        return body.id
    }

    @discardableResult
    public func addBody(_ body: CADBody) -> UUID {
        var inserted = body
        inserted = CADBody(
            id: body.id,
            name: state.uniqueBodyName(base: body.name),
            primitive: body.primitive,
            transform: body.transform,
            materialID: body.materialID,
            priority: body.priority,
            isVisible: body.isVisible
        )
        perform("Add \(inserted.kind.displayName)") { state in
            state.bodies.append(inserted)
        }
        selectedBodyID = inserted.id
        return inserted.id
    }

    /// Mutates one body. `coalescingKey` should identify the specific field.
    public func updateBody(
        _ id: UUID,
        actionName: String,
        coalescingKey: String? = nil,
        _ mutation: (inout CADBody) -> Void
    ) {
        perform(actionName, coalescingKey: coalescingKey) { state in
            guard let index = state.bodyIndex(id: id) else { return }
            mutation(&state.bodies[index])
        }
    }

    public func deleteBody(_ id: UUID) {
        guard let index = state.bodyIndex(id: id) else { return }
        let name = state.bodies[index].name

        // Select the neighbour rather than jumping to the end of the list.
        let nextSelection: UUID? = {
            if state.bodies.count <= 1 { return nil }
            let neighbourIndex = index < state.bodies.count - 1 ? index + 1 : index - 1
            return state.bodies[neighbourIndex].id
        }()

        perform("Delete \(name)") { state in
            state.bodies.remove(at: index)
        }
        if selectedBodyID == id {
            selectedBodyID = nextSelection
        }
    }

    public func deleteSelectedBody() {
        guard let selectedBodyID else { return }
        deleteBody(selectedBodyID)
    }

    public func duplicateSelectedBody() {
        guard let body = selectedBody else { return }
        let copy = body.duplicated(
            named: state.uniqueBodyName(base: body.name),
            offsetBy: Vec3(x: 0, y: 0, z: 0)
        )
        perform("Duplicate \(body.name)") { state in
            let insertionIndex = (state.bodyIndex(id: body.id).map { $0 + 1 }) ?? state.bodies.count
            state.bodies.insert(copy, at: insertionIndex)
        }
        selectedBodyID = copy.id
    }

    public func moveBodies(fromOffsets source: IndexSet, toOffset destination: Int) {
        perform("Reorder Bodies") { state in
            state.bodies.moveElements(fromOffsets: source, toOffset: destination)
        }
    }

    // MARK: - Variables

    @discardableResult
    public func addVariable() -> UUID {
        let variable = CADVariable(
            name: nextVariableName(),
            value: 10
        )
        perform("Add Variable") { state in
            state.variables.append(variable)
        }
        return variable.id
    }

    private func nextVariableName() -> String {
        let taken = Set(state.variables.map(\.trimmedName))
        var index = state.variables.count + 1
        while taken.contains("var\(index)") { index += 1 }
        return "var\(index)"
    }

    /// Renames and rewrites every expression that referenced the old name.
    public func renameVariable(_ id: UUID, to newName: String) {
        guard let current = state.variable(id: id) else { return }
        guard current.trimmedName != newName.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return
        }
        perform("Rename Variable", coalescingKey: "variable.\(id.uuidString).name") { state in
            state.renameVariable(id: id, to: newName)
        }
    }

    public func updateVariable(
        _ id: UUID,
        actionName: String,
        coalescingKey: String? = nil,
        _ mutation: (inout CADVariable) -> Void
    ) {
        perform(actionName, coalescingKey: coalescingKey) { state in
            guard let index = state.variables.firstIndex(where: { $0.id == id }) else { return }
            mutation(&state.variables[index])
        }
    }

    public func deleteVariables(at offsets: IndexSet) {
        perform("Delete Variable") { state in
            state.variables.removeAt(offsets: offsets)
        }
    }

    public func deleteVariable(_ id: UUID) {
        guard let index = state.variables.firstIndex(where: { $0.id == id }) else { return }
        deleteVariables(at: IndexSet(integer: index))
    }

    /// Which bodies, ports and settings would break if this variable went away.
    public func referencesToVariable(named name: String) -> Int {
        guard !name.isEmpty else { return 0 }
        var count = 0
        var probe = state
        probe.walkExpressions { expression in
            if expression.referencedVariableNames.contains(name) { count += 1 }
        }
        return count
    }

    // MARK: - Materials

    @discardableResult
    public func addMaterial() -> UUID {
        let material = MaterialDefinition(
            name: state.uniqueMaterialName(base: "Material"),
            color: .neutralGray,
            epsilonR: 1
        )
        perform("Add Material") { state in
            state.materials.append(material)
        }
        return material.id
    }

    public func updateMaterial(
        _ id: UUID,
        actionName: String,
        coalescingKey: String? = nil,
        _ mutation: (inout MaterialDefinition) -> Void
    ) {
        perform(actionName, coalescingKey: coalescingKey) { state in
            guard let index = state.materials.firstIndex(where: { $0.id == id }) else { return }
            mutation(&state.materials[index])
        }
    }

    /// Deleting a material clears the assignments that pointed at it, so no body
    /// is left holding a dangling ID.
    public func deleteMaterial(_ id: UUID) {
        guard let material = state.material(id: id) else { return }
        perform("Delete \(material.name)") { state in
            state.materials.removeAll { $0.id == id }
            for index in state.bodies.indices where state.bodies[index].materialID == id {
                state.bodies[index].materialID = nil
            }
        }
    }

    public func bodyCount(usingMaterial id: UUID) -> Int {
        state.bodies.filter { $0.materialID == id }.count
    }

    // MARK: - Simulation

    public func updateSimulation(
        actionName: String,
        coalescingKey: String? = nil,
        _ mutation: (inout SimulationSetup) -> Void
    ) {
        perform(actionName, coalescingKey: coalescingKey) { state in
            mutation(&state.simulation)
        }
    }

    @discardableResult
    public func addPort() -> UUID {
        // Default to a small gap at the origin along Y; the user positions it.
        let port = Port(
            name: state.uniquePortName(base: "Port"),
            kind: .lumped,
            region: BoundsExpression(
                xMin: Expression(0),
                xMax: Expression(0),
                yMin: Expression(0),
                yMax: Expression(1),
                zMin: Expression(0),
                zMax: Expression(0)
            ),
            direction: .y
        )
        perform("Add Port") { state in
            state.simulation.ports.append(port)
        }
        selectedPortID = port.id
        return port.id
    }

    public func updatePort(
        _ id: UUID,
        actionName: String,
        coalescingKey: String? = nil,
        _ mutation: (inout Port) -> Void
    ) {
        perform(actionName, coalescingKey: coalescingKey) { state in
            guard let index = state.simulation.ports.firstIndex(where: { $0.id == id }) else { return }
            mutation(&state.simulation.ports[index])
        }
    }

    public func deletePort(_ id: UUID) {
        guard let port = state.simulation.ports.first(where: { $0.id == id }) else { return }
        perform("Delete \(port.name)") { state in
            state.simulation.ports.removeAll { $0.id == id }
        }
    }

    @discardableResult
    public func addMonitor() -> UUID {
        let monitor = FieldMonitor(
            name: state.uniqueMonitorName(base: "Monitor"),
            quantity: .electricField,
            region: .wholeDomain,
            frequenciesHertz: [state.simulation.frequency.centerHertz]
        )
        perform("Add Monitor") { state in
            state.simulation.monitors.append(monitor)
        }
        return monitor.id
    }

    public func updateMonitor(
        _ id: UUID,
        actionName: String,
        coalescingKey: String? = nil,
        _ mutation: (inout FieldMonitor) -> Void
    ) {
        perform(actionName, coalescingKey: coalescingKey) { state in
            guard let index = state.simulation.monitors.firstIndex(where: { $0.id == id }) else { return }
            mutation(&state.simulation.monitors[index])
        }
    }

    public func deleteMonitor(_ id: UUID) {
        guard let monitor = state.simulation.monitors.first(where: { $0.id == id }) else { return }
        perform("Delete \(monitor.name)") { state in
            state.simulation.monitors.removeAll { $0.id == id }
        }
    }

    @discardableResult
    public func addMeshRefinement() -> UUID {
        let bounds = resolved.modelBounds ?? BodyBounds(center: .zero, size: Vec3(repeating: 10))
        let refinement = MeshRefinement(
            name: "Refinement",
            region: BoundsExpression(bounds),
            targetCellSize: Expression(
                resolved.simulation.mesh.effectiveMaxCellSize.map { $0 / 4 } ?? 1
            )
        )
        perform("Add Mesh Refinement") { state in
            state.simulation.mesh.refinements.append(refinement)
        }
        return refinement.id
    }

    public func deleteMeshRefinement(_ id: UUID) {
        perform("Delete Mesh Refinement") { state in
            state.simulation.mesh.refinements.removeAll { $0.id == id }
        }
    }

    // MARK: - Units

    /// Changing the unit *reinterprets* existing numbers rather than rescaling
    /// them; expressions such as `patch_w / 2` have no meaningful rescale. The
    /// UI says so at the point of change.
    public func setLengthUnit(_ unit: LengthUnit) {
        guard unit != state.lengthUnit else { return }
        perform("Change Units") { state in
            state.lengthUnit = unit
        }
    }

    public func setProjectName(_ name: String) {
        perform("Rename Project", coalescingKey: "project.name") { state in
            state.name = name
        }
    }

    // MARK: - Files

    public var displayName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? state.name
    }

    public func projectData() throws -> Data {
        try ProjectSerializer.encode(state)
    }

    public func solverExportData() throws -> Data {
        try SolverExportEncoder.encode(state: state, resolved: resolved)
    }

    public func save(to url: URL) throws {
        try ProjectSerializer.write(state, to: url)
        fileURL = url
        hasUnsavedChanges = false
    }

    public func save() throws -> Bool {
        guard let fileURL else { return false }
        try save(to: fileURL)
        return true
    }

    public func load(from url: URL) throws {
        let loaded = try ProjectSerializer.read(from: url)
        undoStack.removeAll()
        selectedBodyID = loaded.bodies.first?.id
        selectedPortID = nil
        apply(loaded, markDirty: false)
        fileURL = url
        hasUnsavedChanges = false
    }

    public func replaceState(_ newState: CADModelState, actionName: String) {
        perform(actionName) { state in
            state = newState
        }
    }
}
