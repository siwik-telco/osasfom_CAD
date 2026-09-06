import SwiftUI
import osasfom_cadCore

/// Shown in place of the body inspector when more than one body is selected:
/// the only thing that acts on a multi-selection is a boolean combine, so the
/// panel is that operation and nothing else.
struct CombineSelectionView: View {
    @ObservedObject var document: CADDocument

    private var selection: [CADBody] { document.orderedSelectedBodies }
    private var target: CADBody? { selection.first }
    private var toolCount: Int { max(selection.count - 1, 0) }

    var body: some View {
        Form {
            if selection.count < 2 {
                Section {
                    Text("Select two or more bodies to combine them.")
                        .foregroundStyle(.secondary)
                }
            } else {
                selectionSection
                combineSection
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Selection

    private var selectionSection: some View {
        Section {
            ForEach(Array(selection.enumerated()), id: \.element.id) { index, item in
                selectionRow(item, isTarget: index == 0)
            }
        } header: {
            Text("Selection")
        } footer: {
            Text("Picked in this order. Click a body to keep that one instead.")
                .font(.caption)
        }
    }

    /// A tool row is a button that promotes it to the kept body — otherwise a
    /// selection made in the wrong order can only be fixed by starting over.
    @ViewBuilder
    private func selectionRow(_ item: CADBody, isTarget: Bool) -> some View {
        if isTarget {
            LabeledContent {
                Text("kept")
                    .font(.caption.bold())
                    .foregroundStyle(Color.accentColor)
            } label: {
                Label(item.name, systemImage: item.kind.symbolName)
            }
        } else {
            Button {
                document.makeCombineTarget(item.id)
            } label: {
                LabeledContent {
                    Text("consumed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } label: {
                    Label(item.name, systemImage: item.kind.symbolName)
                        .foregroundStyle(.primary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Keep “\(item.name)” instead, and consume the others")
        }
    }

    // MARK: - Combine

    private var combineSection: some View {
        Section {
            ForEach(BooleanKind.allCases) { kind in
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        document.combineSelectedBodies(kind)
                    } label: {
                        Label(actionTitle(for: kind), systemImage: kind.symbolName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)

                    Text(kind.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Combine")
        } footer: {
            Text(consequence)
                .font(.caption)
        }
    }

    /// Names the surviving body in the action itself. The result is one body
    /// and several fewer rows in the model list, which is too destructive to
    /// leave the reader to infer from a paragraph elsewhere.
    private func actionTitle(for kind: BooleanKind) -> String {
        guard let target else { return kind.displayName }
        switch kind {
        case .add: return "Add into “\(target.name)”"
        case .subtract: return "Subtract from “\(target.name)”"
        case .trim: return "Trim “\(target.name)”"
        }
    }

    private var consequence: String {
        guard let target else { return "" }
        let bodyWord = toolCount == 1 ? "body leaves" : "bodies leave"
        return """
        \(toolCount) \(bodyWord) the model list and become editable steps inside “\(target.name)”, \
        which keeps its own material. Nothing is flattened — the shapes stay parametric — and Undo restores them.
        """
    }
}
