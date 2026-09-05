import SwiftUI
import osasfom_cadCore

/// The boolean history for one body: an ordered list of tool shapes added to,
/// subtracted from or intersected with the body's own primitive.
struct BooleanOperationsSection: View {
    @ObservedObject var document: CADDocument
    let bodyID: UUID
    let model: CADBody
    let variables: [String: Double]
    let unitSymbol: String

    var body: some View {
        Section {
            if model.booleans.isEmpty {
                Text("No boolean steps. This body is just its primitive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.booleans.enumerated()), id: \.element.id) { index, operation in
                    BooleanOperationEditor(
                        document: document,
                        bodyID: bodyID,
                        operation: operation,
                        index: index,
                        stepCount: model.booleans.count,
                        variables: variables,
                        unitSymbol: unitSymbol
                    )
                }
            }

            addMenu
        } header: {
            Text("Boolean Operations")
        } footer: {
            Text(
                model.booleans.isEmpty
                    ? "Cut, join or intersect this body with another shape. Steps apply in order."
                    : "Steps apply top to bottom, so a later Add can refill a hole an earlier Subtract made. Drag is not available here — use the arrows to reorder."
            )
            .font(.caption)
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(BooleanKind.allCases) { kind in
                Menu(kind.displayName) {
                    ForEach(PrimitiveKind.allCases) { primitiveKind in
                        Button {
                            document.addBooleanOperation(to: bodyID, kind: kind, primitiveKind: primitiveKind)
                        } label: {
                            Label(primitiveKind.displayName, systemImage: primitiveKind.symbolName)
                        }
                    }
                }
            }
        } label: {
            Label("Add Boolean Step", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// One step, collapsed to a summary until opened.
private struct BooleanOperationEditor: View {
    @ObservedObject var document: CADDocument
    let bodyID: UUID
    let operation: BooleanOperation
    let index: Int
    let stepCount: Int
    let variables: [String: Double]
    let unitSymbol: String

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
        } label: {
            header
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: operation.kind.symbolName)
                .foregroundStyle(operation.isEnabled ? tint : Color.secondary)
                .frame(width: 16)

            Text("\(operation.kind.displayName) \(operation.primitiveKind.displayName)")
                .foregroundStyle(operation.isEnabled ? .primary : .secondary)
                .strikethrough(!operation.isEnabled)

            Spacer(minLength: 4)

            Button {
                move(by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help("Apply this step earlier")

            Button {
                move(by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == stepCount - 1)
            .help("Apply this step later")
        }
        .font(.callout)
    }

    private var tint: Color {
        switch operation.kind {
        case .add: return .green
        case .subtract: return .red
        case .trim: return .orange
        }
    }

    @ViewBuilder
    private var content: some View {
        Picker(
            "Operation",
            selection: Binding(
                get: { operation.kind },
                set: { newKind in
                    update(actionName: "Change Boolean Operation") { $0.kind = newKind }
                }
            )
        ) {
            ForEach(BooleanKind.allCases) { kind in
                Text(kind.displayName).tag(kind)
            }
        }
        .pickerStyle(.segmented)

        Text(operation.kind.summary)
            .font(.caption)
            .foregroundStyle(.secondary)

        Picker(
            "Tool Shape",
            selection: Binding(
                get: { operation.primitiveKind },
                set: { newKind in
                    guard newKind != operation.primitiveKind else { return }
                    update(actionName: "Change Tool Shape") { $0.primitive = $0.primitive.converted(to: newKind) }
                }
            )
        ) {
            ForEach(PrimitiveKind.allCases) { kind in
                Text(kind.displayName).tag(kind)
            }
        }

        PrimitiveFieldsView(
            primitive: operation.primitive,
            variables: variables,
            unitSymbol: unitSymbol,
            showsPositionNotes: false,
            edit: { field, actionName, mutation in
                document.updateBooleanOperation(
                    operation.id,
                    on: bodyID,
                    actionName: actionName,
                    coalescingKey: "boolean.\(operation.id.uuidString).\(field)"
                ) { step in
                    mutation(&step.primitive)
                }
            }
        )

        Text("The tool is placed in model coordinates, the same way the body's own shape is — it does not follow the body's rotation.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Divider()

        LabeledContent("Rotation") { Text("degrees").font(.caption).foregroundStyle(.secondary) }
        ForEach(Axis.allCases) { axis in
            ExpressionRow(
                label: "R\(axis.rawValue)",
                expression: transformBinding(rotation: axis),
                variables: variables,
                unitSymbol: "°"
            )
        }

        Toggle(
            "Enabled",
            isOn: Binding(
                get: { operation.isEnabled },
                set: { newValue in
                    update(actionName: newValue ? "Enable Boolean Step" : "Disable Boolean Step") {
                        $0.isEnabled = newValue
                    }
                }
            )
        )

        Button("Delete Step", role: .destructive) {
            document.deleteBooleanOperation(operation.id, from: bodyID)
        }
    }

    // MARK: - Editing

    private func update(actionName: String, _ mutation: @escaping (inout BooleanOperation) -> Void) {
        document.updateBooleanOperation(operation.id, on: bodyID, actionName: actionName, mutation)
    }

    private func move(by delta: Int) {
        let destination = index + delta
        guard destination >= 0, destination < stepCount else { return }
        // SwiftUI's move offsets count the position *before* removal, so a
        // downward move needs one extra.
        document.moveBooleanOperations(
            on: bodyID,
            fromOffsets: IndexSet(integer: index),
            toOffset: delta > 0 ? destination + 1 : destination
        )
    }

    private func transformBinding(rotation axis: Axis) -> Binding<Expression> {
        Binding(
            get: {
                switch axis {
                case .x: return operation.transform.rotationDegrees.x
                case .y: return operation.transform.rotationDegrees.y
                case .z: return operation.transform.rotationDegrees.z
                }
            },
            set: { newValue in
                document.updateBooleanOperation(
                    operation.id,
                    on: bodyID,
                    actionName: "Edit Tool Rotation",
                    coalescingKey: "boolean.\(operation.id.uuidString).rotation.\(axis.rawValue)"
                ) { step in
                    switch axis {
                    case .x: step.transform.rotationDegrees.x = newValue
                    case .y: step.transform.rotationDegrees.y = newValue
                    case .z: step.transform.rotationDegrees.z = newValue
                    }
                }
            }
        )
    }
}
