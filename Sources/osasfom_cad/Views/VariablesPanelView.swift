import SwiftUI
import osasfom_cadCore

/// The variable table.
///
/// Values are expressions, so variables can build on each other, and renaming
/// one rewrites every expression that referenced it.
struct VariablesPanelView: View {
    @ObservedObject var document: CADDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Variables", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Button {
                    document.addVariable()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if document.state.variables.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(document.state.variables) { variable in
                        VariableRow(document: document, variableID: variable.id)
                    }
                    .onDelete { offsets in
                        document.deleteVariables(at: offsets)
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No variables yet.")
                .foregroundStyle(.secondary)
            Text("Define one, then use its name in any dimension field. Built-ins such as `c0`, `pi` and `sqrt()` are always available.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct VariableRow: View {
    @ObservedObject var document: CADDocument
    let variableID: UUID

    @State private var nameDraft: String = ""
    @FocusState private var isNameFocused: Bool

    private var variable: CADVariable? { document.state.variable(id: variableID) }

    /// The scope a variable sees excludes itself, so a self-reference reads as
    /// an unknown name instead of resolving to a stale value.
    private var scope: [String: Double] {
        var values = document.resolved.variables.values
        if let name = variable?.trimmedName { values.removeValue(forKey: name) }
        return values
    }

    private var diagnostics: [Diagnostic] {
        document.resolved.diagnostics(for: .variable(variableID))
    }

    var body: some View {
        if let variable {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    TextField("name", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 130)
                        .focused($isNameFocused)
                        .onSubmit(commitName)
                        .onChange(of: isNameFocused) { focused in
                            if focused { nameDraft = variable.name } else { commitName() }
                        }
                        .onAppear { nameDraft = variable.name }

                    ExpressionField(
                        title: "value",
                        expression: document.variableBinding(
                            variableID,
                            \.expression,
                            actionName: "Edit Variable",
                            field: "expression"
                        ),
                        variables: scope
                    )
                    .frame(minWidth: 110)
                }

                TextField(
                    "comment",
                    text: document.variableBinding(
                        variableID,
                        \.comment,
                        actionName: "Edit Variable Comment",
                        field: "comment"
                    )
                )
                .textFieldStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(diagnostics) { diagnostic in
                    DiagnosticRow(diagnostic: diagnostic)
                }
            }
            .padding(.vertical, 4)
            .contextMenu {
                let references = document.referencesToVariable(named: variable.trimmedName)
                Button("Delete\(references > 0 ? " (used in \(references) place\(references == 1 ? "" : "s"))" : "")", role: .destructive) {
                    document.deleteVariable(variableID)
                }
            }
        }
    }

    private func commitName() {
        guard let variable, nameDraft != variable.name else { return }
        // Goes through the document so every expression referencing the old
        // name is rewritten in the same undo step.
        document.renameVariable(variableID, to: nameDraft)
    }
}
