import SwiftUI
import osasfom_cadCore

/// Body list plus the variables panel.
struct ModelSidebarView: View {
    @ObservedObject var document: CADDocument

    var body: some View {
        VSplitView {
            bodyList
                .frame(minHeight: 180)
            VariablesPanelView(document: document)
                .frame(minHeight: 160)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var bodyList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Model")
                    .font(.headline)
                Spacer()
                Menu {
                    ForEach(PrimitiveKind.allCases) { kind in
                        Button {
                            document.addBody(kind)
                        } label: {
                            Label(kind.displayName, systemImage: kind.symbolName)
                        }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            List(selection: $document.selectedBodyIDs) {
                ForEach(document.state.bodies) { body in
                    BodyRow(
                        model: body,
                        severity: severity(for: body.id),
                        isResolved: !document.resolved.failedBodyIDs.contains(body.id),
                        toggleVisibility: {
                            document.updateBody(body.id, actionName: "Toggle Visibility") { body in
                                body.isVisible.toggle()
                            }
                        }
                    )
                    .tag(body.id)
                    .contextMenu {
                        if document.canCombineSelectedBodies, document.selectedBodyIDs.contains(body.id) {
                            Section(combineHeader) {
                                ForEach(BooleanKind.allCases) { kind in
                                    Button(kind.displayName) {
                                        document.combineSelectedBodies(kind)
                                    }
                                }
                            }
                            Divider()
                        }
                        Button("Duplicate") {
                            document.selectedBodyID = body.id
                            document.duplicateSelectedBody()
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            document.deleteBody(body.id)
                        }
                    }
                }
                .onMove { source, destination in
                    document.moveBodies(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.inset)

            if document.canCombineSelectedBodies {
                combineBar
            }

            HStack {
                Text("\(document.state.bodies.count) bodies")
                Spacer()
                Text(document.state.lengthUnit.symbol)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// Named so it is never a guess which body survives the combine.
    private var combineHeader: String {
        guard let target = document.combineTargetBody else { return "Combine" }
        let others = document.orderedSelectedBodies.count - 1
        return "Combine into “\(target.name)” (\(others) tool\(others == 1 ? "" : "s"))"
    }

    /// Appears only with two or more bodies selected — the gesture is
    /// meaningless otherwise, and a permanently disabled row is just noise.
    private var combineBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(combineHeader)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                ForEach(BooleanKind.allCases) { kind in
                    Button {
                        document.combineSelectedBodies(kind)
                    } label: {
                        Label(kind.displayName, systemImage: kind.symbolName)
                            .frame(maxWidth: .infinity)
                    }
                    .help(kind.summary)
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private func severity(for id: UUID) -> Diagnostic.Severity? {
        document.resolved.diagnostics(for: .body(id)).map(\.severity).max()
    }
}

private struct BodyRow: View {
    let model: CADBody
    let severity: Diagnostic.Severity?
    let isResolved: Bool
    let toggleVisibility: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.kind.symbolName)
                .foregroundStyle(isResolved ? Color.primary : Color.red)
                .frame(width: 16)

            Text(model.name.isEmpty ? "Untitled" : model.name)
                .lineLimit(1)
                .foregroundStyle(model.isVisible ? .primary : .secondary)

            if !model.booleans.isEmpty {
                Image(systemName: "square.on.square.dashed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("\(model.booleans.count) boolean step(s)")
            }

            Spacer(minLength: 4)

            if let severity {
                Image(
                    systemName: severity == .error
                        ? "exclamationmark.octagon.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(severity == .error ? .red : .orange)
            }

            Button(action: toggleVisibility) {
                Image(systemName: model.isVisible ? "eye" : "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}
