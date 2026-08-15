import SwiftUI
import osasfom_cadCore

/// Inspector for the selected body.
struct BodyInspectorView: View {
    @ObservedObject var document: CADDocument
    let bodyID: UUID

    private var body_: CADBody? { document.state.body(id: bodyID) }
    private var resolvedBody: ResolvedBody? { document.resolved.body(id: bodyID) }
    private var variables: [String: Double] { document.resolved.variables.values }
    private var unit: String { document.state.lengthUnit.symbol }
    private var diagnostics: [Diagnostic] {
        document.resolved.diagnostics(for: .body(bodyID)).sortedForDisplay()
    }

    var body: some View {
        if let model = body_ {
            Form {
                identitySection(model)
                dimensionsSection(model)
                transformSection
                extentsSection
                materialSection(model)
                meshSection
                if !diagnostics.isEmpty { diagnosticsSection }
                deleteSection(model)
            }
            .formStyle(.grouped)
        } else {
            EmptyView()
        }
    }

    // MARK: - Sections

    private func identitySection(_ model: CADBody) -> some View {
        Section("Body") {
            TextField(
                "Name",
                text: document.bodyBinding(bodyID, \.name, actionName: "Rename Body", field: "name")
            )

            Picker(
                "Primitive",
                selection: Binding(
                    get: { model.kind },
                    set: { newKind in
                        guard newKind != model.kind else { return }
                        document.updateBody(bodyID, actionName: "Change Primitive") { body in
                            body.primitive = body.primitive.converted(to: newKind)
                        }
                    }
                )
            ) {
                ForEach(PrimitiveKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }

            Toggle(
                "Visible",
                isOn: document.bodyStepBinding(bodyID, \.isVisible, actionName: "Toggle Visibility")
            )
        }
    }

    @ViewBuilder
    private func dimensionsSection(_ model: CADBody) -> some View {
        Section {
            switch model.primitive {
            case .box:
                ExpressionRow(
                    label: "Width (X)",
                    expression: boxBinding(\.width, field: "width"),
                    variables: variables,
                    unitSymbol: unit
                )
                ExpressionRow(
                    label: "Height (Y)",
                    expression: boxBinding(\.height, field: "height"),
                    variables: variables,
                    unitSymbol: unit
                )
                ExpressionRow(
                    label: "Depth (Z)",
                    expression: boxBinding(\.depth, field: "depth"),
                    variables: variables,
                    unitSymbol: unit
                )

            case .cylinder(let spec):
                ExpressionRow(
                    label: "Radius",
                    expression: cylinderBinding(\.radius, field: "radius"),
                    variables: variables,
                    unitSymbol: unit
                )
                ExpressionRow(
                    label: "Length",
                    expression: cylinderBinding(\.length, field: "length"),
                    variables: variables,
                    unitSymbol: unit
                )
                Picker(
                    "Axis",
                    selection: Binding(
                        get: { spec.axis },
                        set: { newAxis in
                            document.updateBody(bodyID, actionName: "Change Cylinder Axis") { body in
                                body.primitive.updateCylinder { $0.axis = newAxis }
                            }
                        }
                    )
                ) {
                    ForEach(Axis.allCases) { axis in
                        Text(axis.displayName).tag(axis)
                    }
                }
                .pickerStyle(.segmented)

            case .sheet(let spec):
                Picker(
                    "Normal",
                    selection: Binding(
                        get: { spec.normal },
                        set: { newNormal in
                            document.updateBody(bodyID, actionName: "Change Sheet Normal") { body in
                                body.primitive.updateSheet { $0.normal = newNormal }
                            }
                        }
                    )
                ) {
                    ForEach(Axis.allCases) { axis in
                        Text(axis.displayName).tag(axis)
                    }
                }
                .pickerStyle(.segmented)

                ExpressionRow(
                    label: "Width (\(spec.normal.perpendicular.0.displayName))",
                    expression: sheetBinding(\.width, field: "width"),
                    variables: variables,
                    unitSymbol: unit
                )
                ExpressionRow(
                    label: "Depth (\(spec.normal.perpendicular.1.displayName))",
                    expression: sheetBinding(\.depth, field: "depth"),
                    variables: variables,
                    unitSymbol: unit
                )
                ExpressionRow(
                    label: "Thickness",
                    expression: sheetBinding(\.thickness, field: "thickness"),
                    variables: variables,
                    unitSymbol: unit,
                    help: "Zero is allowed and means an infinitely thin sheet."
                )

                if let thickness = try? spec.thickness.value(variables: variables), thickness == 0 {
                    Label(
                        "Zero-thickness sheet — meshed as a surface. Ideal for a PEC patch or ground plane.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Dimensions")
        } footer: {
            Text("Fields accept expressions: `patch_w / 2`, `lambda / 4`, `sqrt(2) * h_sub`.")
                .font(.caption)
        }
    }

    private var transformSection: some View {
        Section("Transform") {
            LabeledContent("Position") {
                EmptyView()
            }
            ExpressionRow(
                label: "X",
                expression: transformBinding(\.position.x, field: "position.x"),
                variables: variables,
                unitSymbol: unit
            )
            ExpressionRow(
                label: "Y",
                expression: transformBinding(\.position.y, field: "position.y"),
                variables: variables,
                unitSymbol: unit
            )
            ExpressionRow(
                label: "Z",
                expression: transformBinding(\.position.z, field: "position.z"),
                variables: variables,
                unitSymbol: unit
            )

            Divider()

            LabeledContent("Rotation") { Text("degrees").font(.caption).foregroundStyle(.secondary) }
            ExpressionRow(
                label: "Rx",
                expression: transformBinding(\.rotationDegrees.x, field: "rotation.x"),
                variables: variables,
                unitSymbol: "°"
            )
            ExpressionRow(
                label: "Ry",
                expression: transformBinding(\.rotationDegrees.y, field: "rotation.y"),
                variables: variables,
                unitSymbol: "°"
            )
            ExpressionRow(
                label: "Rz",
                expression: transformBinding(\.rotationDegrees.z, field: "rotation.z"),
                variables: variables,
                unitSymbol: "°"
            )

            Divider()

            LabeledContent("Scale") { EmptyView() }
            ExpressionRow(
                label: "Sx",
                expression: transformBinding(\.scale.x, field: "scale.x"),
                variables: variables
            )
            ExpressionRow(
                label: "Sy",
                expression: transformBinding(\.scale.y, field: "scale.y"),
                variables: variables
            )
            ExpressionRow(
                label: "Sz",
                expression: transformBinding(\.scale.z, field: "scale.z"),
                variables: variables
            )
        }
    }

    /// The extent editor, which is offered only where a well-defined inverse
    /// exists. Everything else shows the true rotated bounding box read-only.
    @ViewBuilder
    private var extentsSection: some View {
        if let resolved = resolvedBody {
            Section {
                switch resolved.boundsEditability {
                case .editable:
                    EditableExtentsView(
                        document: document,
                        bodyID: bodyID,
                        bounds: resolved.localBounds,
                        unitSymbol: unit,
                        warnsAboutFlattening: document.state.body(id: bodyID)?
                            .primitive.hasParametricExtents ?? false
                    )
                case .rotated, .lossyForKind:
                    BoundsReadout(bounds: resolved.axisAlignedBounds, unitSymbol: unit)
                    if let explanation = resolved.boundsEditability.explanation {
                        Text(explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(resolved.isAxisAligned ? "Extents" : "Bounding box (rotated)")
            }
        }
    }

    private func materialSection(_ model: CADBody) -> some View {
        Section("Material") {
            Picker(
                "Assignment",
                selection: document.bodyStepBinding(
                    bodyID,
                    \.materialID,
                    actionName: "Assign Material"
                )
            ) {
                Text("Default (vacuum)").tag(Optional<UUID>.none)
                ForEach(document.state.materials) { material in
                    Text(material.name).tag(Optional(material.id))
                }
            }

            let material = document.state.effectiveMaterial(for: model)
            MaterialSummaryView(
                material: material,
                referenceHertz: document.state.simulation.frequency.centerHertz
            )
        }
    }

    private var meshSection: some View {
        Section {
            Stepper(
                value: document.bodyStepBinding(bodyID, \.priority, actionName: "Change Priority"),
                in: -100...100
            ) {
                LabeledContent("Overlap priority") {
                    Text("\(document.state.body(id: bodyID)?.priority ?? 0)")
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Meshing")
        } footer: {
            Text("Where bodies overlap, the higher priority owns the cells. Give a patch a higher priority than the substrate it sits on.")
                .font(.caption)
        }
    }

    private var diagnosticsSection: some View {
        Section("Issues") {
            ForEach(diagnostics) { diagnostic in
                DiagnosticRow(diagnostic: diagnostic)
            }
        }
    }

    private func deleteSection(_ model: CADBody) -> some View {
        Section {
            Button(role: .destructive) {
                document.deleteBody(bodyID)
            } label: {
                Label("Delete “\(model.name)”", systemImage: "trash")
            }
        }
    }

    // MARK: - Bindings

    private func boxBinding(
        _ keyPath: WritableKeyPath<BoxSpec, Expression>,
        field: String
    ) -> Binding<Expression> {
        Binding(
            get: { self.body_?.primitive.boxSpec?[keyPath: keyPath] ?? .unset },
            set: { newValue in
                document.updateBody(
                    bodyID,
                    actionName: "Edit Dimension",
                    coalescingKey: "body.\(bodyID.uuidString).\(field)"
                ) { body in
                    body.primitive.updateBox { $0[keyPath: keyPath] = newValue }
                }
            }
        )
    }

    private func cylinderBinding(
        _ keyPath: WritableKeyPath<CylinderSpec, Expression>,
        field: String
    ) -> Binding<Expression> {
        Binding(
            get: { self.body_?.primitive.cylinderSpec?[keyPath: keyPath] ?? .unset },
            set: { newValue in
                document.updateBody(
                    bodyID,
                    actionName: "Edit Dimension",
                    coalescingKey: "body.\(bodyID.uuidString).\(field)"
                ) { body in
                    body.primitive.updateCylinder { $0[keyPath: keyPath] = newValue }
                }
            }
        )
    }

    private func sheetBinding(
        _ keyPath: WritableKeyPath<SheetSpec, Expression>,
        field: String
    ) -> Binding<Expression> {
        Binding(
            get: { self.body_?.primitive.sheetSpec?[keyPath: keyPath] ?? .unset },
            set: { newValue in
                document.updateBody(
                    bodyID,
                    actionName: "Edit Dimension",
                    coalescingKey: "body.\(bodyID.uuidString).\(field)"
                ) { body in
                    body.primitive.updateSheet { $0[keyPath: keyPath] = newValue }
                }
            }
        )
    }

    private func transformBinding(
        _ keyPath: WritableKeyPath<BodyTransform, Expression>,
        field: String
    ) -> Binding<Expression> {
        Binding(
            get: { self.body_?.transform[keyPath: keyPath] ?? .unset },
            set: { newValue in
                document.updateBody(
                    bodyID,
                    actionName: "Edit Transform",
                    coalescingKey: "body.\(bodyID.uuidString).\(field)"
                ) { body in
                    body.transform[keyPath: keyPath] = newValue
                }
            }
        )
    }
}

/// Numeric extent editor for unrotated boxes and sheets.
///
/// Writing here replaces the affected expressions with literals, which is said
/// out loud when the body is currently parametric.
private struct EditableExtentsView: View {
    @ObservedObject var document: CADDocument
    let bodyID: UUID
    let bounds: BodyBounds
    let unitSymbol: String
    let warnsAboutFlattening: Bool

    @State private var draft: BodyBounds?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Axis.allCases) { axis in
                HStack(spacing: 6) {
                    Text(axis.displayName)
                        .frame(width: 14, alignment: .leading)
                        .foregroundStyle(.secondary)
                    TextField(
                        "min",
                        value: binding(for: axis, isMinimum: true),
                        format: FieldFormat.decimal
                    )
                    .textFieldStyle(.roundedBorder)
                    TextField(
                        "max",
                        value: binding(for: axis, isMinimum: false),
                        format: FieldFormat.decimal
                    )
                    .textFieldStyle(.roundedBorder)
                    Text(unitSymbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .leading)
                }
            }

            if warnsAboutFlattening {
                Label(
                    "This body's dimensions come from variables. Editing extents here replaces those expressions with plain numbers.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private func binding(for axis: Axis, isMinimum: Bool) -> Binding<Double> {
        Binding(
            get: {
                let current = draft ?? bounds
                return isMinimum ? current.minimum[axis] : current.maximum[axis]
            },
            set: { newValue in
                var updated = draft ?? bounds
                if isMinimum {
                    updated[keyPath: Self.minimumKeyPath(axis)] = newValue
                } else {
                    updated[keyPath: Self.maximumKeyPath(axis)] = newValue
                }
                draft = updated
                apply(updated)
            }
        )
    }

    private func apply(_ newBounds: BodyBounds) {
        let normalized = newBounds.normalized()
        let size = normalized.size
        // A zero or inverted span is refused rather than silently widened; the
        // field keeps the user's text so they can correct it.
        guard size.components.allSatisfy({ $0 > 0 }) else { return }

        document.updateBody(
            bodyID,
            actionName: "Edit Extents",
            coalescingKey: "body.\(bodyID.uuidString).extents"
        ) { body in
            body.primitive.applyLocalExtents(size)
            body.transform.position = Vector3Expression(normalized.center)
        }
        draft = nil
    }

    private static func minimumKeyPath(_ axis: Axis) -> WritableKeyPath<BodyBounds, Double> {
        switch axis {
        case .x: return \.xMin
        case .y: return \.yMin
        case .z: return \.zMin
        }
    }

    private static func maximumKeyPath(_ axis: Axis) -> WritableKeyPath<BodyBounds, Double> {
        switch axis {
        case .x: return \.xMax
        case .y: return \.yMax
        case .z: return \.zMax
        }
    }
}

struct MaterialSummaryView: View {
    let material: MaterialDefinition
    let referenceHertz: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent("Type", value: material.kind.displayName)
            if material.kind.usesConstitutiveParameters {
                LabeledContent("εr", value: Expression.literalSource(material.epsilonR))
                LabeledContent("µr", value: Expression.literalSource(material.muR))
                LabeledContent(
                    "σ",
                    value: "\(Expression.literalSource(material.electricConductivity)) S/m"
                )
                if let tangent = material.lossTangent(atHertz: referenceHertz) {
                    LabeledContent(
                        "tan δ @ \(FrequencyFormatter.string(hertz: referenceHertz))",
                        value: Expression.literalSource(tangent)
                    )
                }
                if !material.dispersion.isNone {
                    LabeledContent("Dispersion", value: material.dispersion.displayName)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct DiagnosticRow: View {
    let diagnostic: Diagnostic

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(
                systemName: diagnostic.severity == .error
                    ? "exclamationmark.octagon.fill"
                    : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(diagnostic.severity == .error ? .red : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(diagnostic.message)
                    .font(.caption)
                if let field = diagnostic.field {
                    Text(field)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
