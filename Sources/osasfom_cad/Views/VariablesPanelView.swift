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
    /// Non-nil only while the "still in use" alert is up; holds the count
    /// measured at the moment deletion was attempted.
    @State private var blockedUseCount: Int?
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
                        // Shrinkable rather than fixed: the panel lives in a
                        // resizable split view, and a fixed 130pt name field
                        // pushed the delete button off the edge once the
                        // sidebar was dragged narrow.
                        .frame(minWidth: 56, idealWidth: 130, maxWidth: 130)
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
                    .frame(minWidth: 52)

                    Button(role: .destructive) {
                        delete()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    // Sized to its content and given priority over the two
                    // text fields, so it is the last thing to give up space
                    // instead of the first.
                    .fixedSize()
                    .layoutPriority(1)
                    .help("Delete this variable")
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
                Button("Delete", role: .destructive) { delete() }
            }
            // A variable something still refers to cannot be deleted at all:
            // removing it would turn every one of those expressions into an
            // "unknown name" error.
            .alert(
                "“\(variable.trimmedName)” is still in use",
                isPresented: Binding(
                    get: { blockedUseCount != nil },
                    set: { if !$0 { blockedUseCount = nil } }
                )
            ) {
                Button("OK", role: .cancel) { blockedUseCount = nil }
            } message: {
                Text(blockedMessage)
            }
        }
    }

    /// Deletes only if nothing refers to the variable.
    ///
    /// The reference scan walks every expression in the document, so it runs
    /// here — once, on the click — and never during layout. Counting it in a
    /// tooltip or a menu label instead meant re-walking the whole model for
    /// every visible row on every redraw.
    private func delete() {
        let blocking = document.deleteVariableIfUnused(variableID)
        if blocking > 0 { blockedUseCount = blocking }
    }

    private var blockedMessage: String {
        let count = blockedUseCount ?? 0
        let plural = count == 1 ? "expression" : "expressions"
        return "\(count) \(plural) still refer to it. Change or remove those first, then delete the variable."
    }

    private func commitName() {
        guard let variable, nameDraft != variable.name else { return }
        // Goes through the document so every expression referencing the old
        // name is rewritten in the same undo step.
        document.renameVariable(variableID, to: nameDraft)
    }
}
