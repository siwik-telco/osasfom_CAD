import SwiftUI
import osasfom_cadCore

/// SwiftUI bindings that route every write through `CADDocument.perform`.
///
/// These live in the app target rather than Core so Core stays Foundation-only.
/// Each binding supplies an undo action name and a per-field coalescing key, so
/// typing into a field produces one undo step instead of one per keystroke.
extension CADDocument {
    func bodyBinding<Value: Equatable>(
        _ id: UUID,
        _ keyPath: WritableKeyPath<CADBody, Value>,
        actionName: String,
        field: String
    ) -> Binding<Value> {
        Binding(
            get: { self.state.body(id: id)?[keyPath: keyPath] ?? self.fallback(for: keyPath) },
            set: { newValue in
                self.updateBody(
                    id,
                    actionName: actionName,
                    coalescingKey: "body.\(id.uuidString).\(field)"
                ) { body in
                    body[keyPath: keyPath] = newValue
                }
            }
        )
    }

    /// A body binding without coalescing, for discrete controls such as pickers
    /// and toggles where each change should be its own undo step.
    func bodyStepBinding<Value: Equatable>(
        _ id: UUID,
        _ keyPath: WritableKeyPath<CADBody, Value>,
        actionName: String
    ) -> Binding<Value> {
        Binding(
            get: { self.state.body(id: id)?[keyPath: keyPath] ?? self.fallback(for: keyPath) },
            set: { newValue in
                self.updateBody(id, actionName: actionName) { body in
                    body[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func fallback<Value>(for keyPath: WritableKeyPath<CADBody, Value>) -> Value {
        // Only reached if the body vanishes between a view update and a write,
        // in which case the value is discarded anyway.
        let placeholder = CADBody(name: "", primitive: .defaultBox)
        return placeholder[keyPath: keyPath]
    }

    func variableBinding<Value: Equatable>(
        _ id: UUID,
        _ keyPath: WritableKeyPath<CADVariable, Value>,
        actionName: String,
        field: String
    ) -> Binding<Value> {
        Binding(
            get: {
                self.state.variable(id: id)?[keyPath: keyPath]
                    ?? CADVariable(name: "", value: 0)[keyPath: keyPath]
            },
            set: { newValue in
                self.updateVariable(
                    id,
                    actionName: actionName,
                    coalescingKey: "variable.\(id.uuidString).\(field)"
                ) { variable in
                    variable[keyPath: keyPath] = newValue
                }
            }
        )
    }

    func materialBinding<Value: Equatable>(
        _ id: UUID,
        _ keyPath: WritableKeyPath<MaterialDefinition, Value>,
        actionName: String,
        field: String
    ) -> Binding<Value> {
        Binding(
            get: {
                self.state.material(id: id)?[keyPath: keyPath]
                    ?? MaterialLibrary.vacuum[keyPath: keyPath]
            },
            set: { newValue in
                self.updateMaterial(
                    id,
                    actionName: actionName,
                    coalescingKey: "material.\(id.uuidString).\(field)"
                ) { material in
                    material[keyPath: keyPath] = newValue
                }
            }
        )
    }

    func simulationBinding<Value: Equatable>(
        _ keyPath: WritableKeyPath<SimulationSetup, Value>,
        actionName: String,
        field: String
    ) -> Binding<Value> {
        Binding(
            get: { self.state.simulation[keyPath: keyPath] },
            set: { newValue in
                self.updateSimulation(
                    actionName: actionName,
                    coalescingKey: "simulation.\(field)"
                ) { simulation in
                    simulation[keyPath: keyPath] = newValue
                }
            }
        )
    }

    func simulationStepBinding<Value: Equatable>(
        _ keyPath: WritableKeyPath<SimulationSetup, Value>,
        actionName: String
    ) -> Binding<Value> {
        Binding(
            get: { self.state.simulation[keyPath: keyPath] },
            set: { newValue in
                self.updateSimulation(actionName: actionName) { simulation in
                    simulation[keyPath: keyPath] = newValue
                }
            }
        )
    }

    func portBinding<Value: Equatable>(
        _ id: UUID,
        _ keyPath: WritableKeyPath<SimulationPort, Value>,
        actionName: String,
        field: String
    ) -> Binding<Value> {
        Binding(
            get: {
                self.state.simulation.ports.first { $0.id == id }?[keyPath: keyPath]
                    ?? SimulationPort(name: "", region: .zero)[keyPath: keyPath]
            },
            set: { newValue in
                self.updatePort(
                    id,
                    actionName: actionName,
                    coalescingKey: "port.\(id.uuidString).\(field)"
                ) { port in
                    port[keyPath: keyPath] = newValue
                }
            }
        )
    }

    func monitorBinding<Value: Equatable>(
        _ id: UUID,
        _ keyPath: WritableKeyPath<FieldMonitor, Value>,
        actionName: String,
        field: String
    ) -> Binding<Value> {
        Binding(
            get: {
                self.state.simulation.monitors.first { $0.id == id }?[keyPath: keyPath]
                    ?? FieldMonitor(name: "", quantity: .electricField)[keyPath: keyPath]
            },
            set: { newValue in
                self.updateMonitor(
                    id,
                    actionName: actionName,
                    coalescingKey: "monitor.\(id.uuidString).\(field)"
                ) { monitor in
                    monitor[keyPath: keyPath] = newValue
                }
            }
        )
    }
}

/// Shared numeric format for plain `Double` fields (frequencies, ε_r and so on).
enum FieldFormat {
    static let decimal = FloatingPointFormatStyle<Double>.number
        .precision(.fractionLength(0...6))
    static let scientific = FloatingPointFormatStyle<Double>.number
        .precision(.significantDigits(1...6))
}
