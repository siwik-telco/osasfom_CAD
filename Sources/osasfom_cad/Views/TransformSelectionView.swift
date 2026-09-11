import SwiftUI
import osasfom_cadCore

/// Translate / rotate / mirror the selected bodies, in place or as copies —
/// FEKO's and CST's transform dialog.
///
/// Every numeric field takes an expression, so an array can be built on a
/// variable and stay tied to it: set the spacing to `s_dip` and the whole array
/// follows when the variable changes.
struct TransformSelectionView: View {
    @ObservedObject var document: CADDocument

    enum Mode: String, CaseIterable, Identifiable {
        case translate = "Translate"
        case rotate = "Rotate"
        case mirror = "Mirror"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .translate: return "arrow.up.left.and.arrow.down.right"
            case .rotate: return "rotate.3d"
            case .mirror: return "flip.horizontal"
            }
        }
    }

    @State private var mode: Mode = .translate
    @State private var offset = Vector3Expression(x: Expression(0), y: Expression(0), z: Expression(0))
    @State private var angle = Expression(90)
    @State private var rotationAxis: Axis = .z
    @State private var centre = Vector3Expression(x: Expression(0), y: Expression(0), z: Expression(0))
    @State private var mirrorAxis: Axis = .x
    @State private var mirrorOffset = Expression(0)
    @State private var makeCopies = false
    @State private var copyCount = 1
    @State private var failure: String?

    private var targets: [CADBody] { document.transformTargets }
    private var unit: String { document.state.lengthUnit.symbol }
    private var variables: [String: Double] { document.resolved.variables.values }

    var body: some View {
        Form {
            if targets.isEmpty {
                Section {
                    Text("Select one or more bodies to transform them.")
                        .foregroundStyle(.secondary)
                }
            } else {
                modeSection
                parameterSection
                copySection
                applySection
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Sections

    private var modeSection: some View {
        Section {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } header: {
            Text(targets.count == 1 ? "Transform \(targets[0].name)" : "Transform \(targets.count) bodies")
        }
    }

    @ViewBuilder
    private var parameterSection: some View {
        switch mode {
        case .translate:
            Section {
                ForEach(Axis.allCases) { axis in
                    ExpressionRow(
                        label: axis.displayName,
                        expression: binding(for: axis, in: $offset),
                        variables: variables,
                        unitSymbol: unit
                    )
                }
            } header: {
                Text("Offset")
            } footer: {
                Text("Added to each body's Position. Expressions are kept, so `s_dip` becomes `s_dip + (offset)` and still follows its variable.")
                    .font(.caption)
            }

        case .rotate:
            Section {
                Picker("About", selection: $rotationAxis) {
                    ForEach(Axis.allCases) { axis in Text(axis.displayName).tag(axis) }
                }
                .pickerStyle(.segmented)

                ExpressionRow(label: "Angle", expression: $angle, variables: variables, unitSymbol: "°")

                ForEach(Axis.allCases) { axis in
                    ExpressionRow(
                        label: "Centre \(axis.displayName)",
                        expression: binding(for: axis, in: $centre),
                        variables: variables,
                        unitSymbol: unit
                    )
                }
            } header: {
                Text("Rotation")
            } footer: {
                Text("Bodies orbit the centre and spin by the same angle, composing with any rotation they already have.")
                    .font(.caption)
            }

        case .mirror:
            Section {
                Picker("Plane normal", selection: $mirrorAxis) {
                    ForEach(Axis.allCases) { axis in Text(axis.displayName).tag(axis) }
                }
                .pickerStyle(.segmented)

                ExpressionRow(
                    label: "Plane at \(mirrorAxis.displayName)",
                    expression: $mirrorOffset,
                    variables: variables,
                    unitSymbol: unit
                )
            } header: {
                Text("Mirror")
            } footer: {
                Text("Reflection flips handedness, which is carried by a negative Scale on the mirror axis — the body stays a valid orientation rather than an impossible one.")
                    .font(.caption)
            }
        }
    }

    private var copySection: some View {
        Section {
            Toggle("Keep originals and copy", isOn: $makeCopies)

            if makeCopies, operation.maximumCopies > 1 {
                Stepper(value: $copyCount, in: 1...operation.maximumCopies) {
                    LabeledContent("Copies", value: "\(copyCount)")
                }
            }
        } footer: {
            if makeCopies {
                if operation.maximumCopies == 1 {
                    Text("Mirroring twice returns a body to where it started, so a mirror makes one copy.")
                        .font(.caption)
                } else {
                    Text("Copy *k* gets the transform applied *k* times, so a 20 \(unit) offset lands them at 20, 40, 60…")
                        .font(.caption)
                }
            } else {
                Text("The selected bodies are moved where they stand.")
                    .font(.caption)
            }
        }
    }

    private var applySection: some View {
        Section {
            if operation.wouldFlattenExpressions(of: targets) {
                // Rotation and mirroring need the body's current placement as
                // numbers, so any expression driving it is replaced by the
                // value it has right now. Worth saying before the fact, not
                // after: it is not visible in the viewport and undo is the
                // only way back.
                Label(
                    "This replaces the selected bodies' parametric Position/Rotation with plain numbers. "
                        + "Translation would keep them; rotation and mirroring cannot.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if let failure {
                Label(failure, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                apply()
            } label: {
                Label(
                    makeCopies ? "Apply and Copy" : "Apply",
                    systemImage: makeCopies ? "plus.square.on.square" : "checkmark"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Plumbing

    private var operation: BodyTransformOperation {
        let kind: BodyTransformOperation.Kind
        switch mode {
        case .translate: kind = .translate(offset)
        case .rotate: kind = .rotate(axis: rotationAxis, degrees: angle, centre: centre)
        case .mirror: kind = .mirror(axis: mirrorAxis, offset: mirrorOffset)
        }
        return BodyTransformOperation(kind: kind, copyCount: makeCopies ? copyCount : 0)
    }

    private func apply() {
        do {
            try document.applyTransform(operation)
            failure = nil
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private func binding(for axis: Axis, in vector: Binding<Vector3Expression>) -> Binding<Expression> {
        Binding(
            get: { vector.wrappedValue[axis] },
            set: { vector.wrappedValue[axis] = $0 }
        )
    }
}
