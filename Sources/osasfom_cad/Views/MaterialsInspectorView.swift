import SwiftUI
import osasfom_cadCore

/// Material library editor.
struct MaterialsInspectorView: View {
    @ObservedObject var document: CADDocument
    @State private var selectedMaterialID: UUID?

    var body: some View {
        VSplitView {
            List(selection: $selectedMaterialID) {
                ForEach(document.state.materials) { material in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(
                                .sRGB,
                                red: material.color.red,
                                green: material.color.green,
                                blue: material.color.blue,
                                opacity: 1
                            ))
                            .frame(width: 14, height: 14)
                        Text(material.name)
                        Spacer()
                        let count = document.bodyCount(usingMaterial: material.id)
                        if count > 0 {
                            Text("\(count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(Optional(material.id))
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 140)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        selectedMaterialID = document.addMaterial()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }

            if let selectedMaterialID,
               document.state.material(id: selectedMaterialID) != nil {
                MaterialEditor(document: document, materialID: selectedMaterialID)
            } else {
                Text("Select a material.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct MaterialEditor: View {
    @ObservedObject var document: CADDocument
    let materialID: UUID

    private var material: MaterialDefinition? { document.state.material(id: materialID) }
    private var referenceHertz: Double { document.state.simulation.frequency.centerHertz }

    var body: some View {
        if let material {
            Form {
                Section("Material") {
                    TextField(
                        "Name",
                        text: document.materialBinding(
                            materialID,
                            \.name,
                            actionName: "Rename Material",
                            field: "name"
                        )
                    )

                    Picker(
                        "Type",
                        selection: document.materialBinding(
                            materialID,
                            \.kind,
                            actionName: "Change Material Type",
                            field: "kind"
                        )
                    ) {
                        ForEach(MaterialKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }

                    ColorPicker(
                        "Colour",
                        selection: Binding(
                            get: {
                                Color(
                                    .sRGB,
                                    red: material.color.red,
                                    green: material.color.green,
                                    blue: material.color.blue,
                                    opacity: material.color.alpha
                                )
                            },
                            set: { newColor in
                                guard let components = NSColor(newColor)
                                    .usingColorSpace(.sRGB) else { return }
                                document.updateMaterial(
                                    materialID,
                                    actionName: "Change Material Colour"
                                ) { material in
                                    material.color = RGBAColor(
                                        red: Double(components.redComponent),
                                        green: Double(components.greenComponent),
                                        blue: Double(components.blueComponent),
                                        alpha: Double(components.alphaComponent)
                                    )
                                }
                            }
                        ),
                        supportsOpacity: true
                    )
                }

                if material.kind.usesConstitutiveParameters {
                    Section("Constitutive parameters") {
                        numberRow(
                            "εr (relative permittivity)",
                            keyPath: \.epsilonR,
                            field: "epsilonR"
                        )
                        numberRow("µr (relative permeability)", keyPath: \.muR, field: "muR")
                        numberRow(
                            "σ (S/m)",
                            keyPath: \.electricConductivity,
                            field: "sigma",
                            format: FieldFormat.scientific
                        )
                        numberRow(
                            "σ* magnetic (Ω/m)",
                            keyPath: \.magneticConductivity,
                            field: "sigmaMagnetic",
                            format: FieldFormat.scientific
                        )

                        if let tangent = material.lossTangent(atHertz: referenceHertz) {
                            HStack {
                                Text("tan δ @ \(FrequencyFormatter.string(hertz: referenceHertz))")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                TextField(
                                    "",
                                    value: Binding(
                                        get: { tangent },
                                        set: { newValue in
                                            document.updateMaterial(
                                                materialID,
                                                actionName: "Edit Loss Tangent",
                                                coalescingKey: "material.\(materialID.uuidString).tand"
                                            ) { material in
                                                material.setLossTangent(
                                                    newValue,
                                                    atHertz: referenceHertz
                                                )
                                            }
                                        }
                                    ),
                                    format: FieldFormat.scientific
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                            }
                            Text("Editing the loss tangent rewrites σ at the band centre.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Dispersion") {
                        Picker(
                            "Model",
                            selection: Binding(
                                get: { dispersionTag(material.dispersion) },
                                set: { newTag in
                                    document.updateMaterial(
                                        materialID,
                                        actionName: "Change Dispersion Model"
                                    ) { material in
                                        material.dispersion = makeDispersion(newTag)
                                    }
                                }
                            )
                        ) {
                            Text("None").tag("none")
                            Text("Debye").tag("debye")
                            Text("Drude").tag("drude")
                            Text("Lorentz").tag("lorentz")
                        }

                        if !material.dispersion.isNone {
                            Text("εr above is treated as ε∞. Pole parameters are carried through to the solver deck.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section {
                        Text("\(material.kind.displayName) is a boundary condition, so ε, µ and σ do not apply.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Notes") {
                    TextField(
                        "Reference",
                        text: document.materialBinding(
                            materialID,
                            \.reference,
                            actionName: "Edit Material Reference",
                            field: "reference"
                        )
                    )
                }

                Section {
                    let usage = document.bodyCount(usingMaterial: materialID)
                    Button(role: .destructive) {
                        document.deleteMaterial(materialID)
                    } label: {
                        Label(
                            usage > 0
                                ? "Delete (unassigns \(usage) bod\(usage == 1 ? "y" : "ies"))"
                                : "Delete Material",
                            systemImage: "trash"
                        )
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func numberRow(
        _ label: String,
        keyPath: WritableKeyPath<MaterialDefinition, Double>,
        field: String,
        format: FloatingPointFormatStyle<Double> = FieldFormat.decimal
    ) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            TextField(
                "",
                value: document.materialBinding(
                    materialID,
                    keyPath,
                    actionName: "Edit Material",
                    field: field
                ),
                format: format
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 90)
        }
    }

    private func dispersionTag(_ model: DispersionModel) -> String {
        switch model {
        case .none: return "none"
        case .debye: return "debye"
        case .drude: return "drude"
        case .lorentz: return "lorentz"
        }
    }

    private func makeDispersion(_ tag: String) -> DispersionModel {
        switch tag {
        case "debye":
            return .debye(poles: [DebyePole(deltaEpsilon: 1, relaxationTimeSeconds: 1e-11)])
        case "drude":
            return .drude(plasmaHertz: 2e15, collisionHertz: 5e13)
        case "lorentz":
            return .lorentz(
                poles: [LorentzPole(deltaEpsilon: 1, resonanceHertz: 5e14, dampingHertz: 1e13)]
            )
        default:
            return .none
        }
    }
}
