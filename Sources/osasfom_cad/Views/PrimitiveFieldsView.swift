import SwiftUI
import osasfom_cadCore

/// The dimension fields for one primitive.
///
/// Shared by a body's own shape and by a boolean tool, so the two can never
/// drift apart — adding a field to a primitive means editing one view, not
/// remembering to edit two.
struct PrimitiveFieldsView: View {
    let primitive: Primitive
    let variables: [String: Double]
    let unitSymbol: String
    /// Whether to spell out that Position is ignored on the axes this
    /// primitive's own begin/end drive. A boolean tool makes that note once
    /// for the whole step instead of on every field.
    var showsPositionNotes: Bool = true
    /// `field` identifies the edited property so keystrokes coalesce into one
    /// undo step per field rather than one per character.
    let edit: (_ field: String, _ actionName: String, _ mutation: @escaping (inout Primitive) -> Void) -> Void

    var body: some View {
        switch primitive {
        case .box:
            ForEach(Axis.allCases) { axis in
                ExpressionRow(
                    label: "Begin (\(axis.displayName))",
                    expression: boxBinding(axis, isBegin: true),
                    variables: variables,
                    unitSymbol: unitSymbol,
                    help: showsPositionNotes && axis == .x
                        ? "Absolute coordinate of the box's face on this axis. Position is unused for a box — set extents here instead."
                        : nil
                )
                ExpressionRow(
                    label: "End (\(axis.displayName))",
                    expression: boxBinding(axis, isBegin: false),
                    variables: variables,
                    unitSymbol: unitSymbol
                )
            }

        case .cylinder(let spec):
            ExpressionRow(
                label: "Radius",
                expression: cylinderBinding(\.radius, field: "radius"),
                variables: variables,
                unitSymbol: unitSymbol
            )
            Picker(
                "Axis",
                selection: Binding(
                    get: { spec.axis },
                    set: { newAxis in
                        edit("axis", "Change Cylinder Axis") { $0.updateCylinder { $0.axis = newAxis } }
                    }
                )
            ) {
                ForEach(Axis.allCases) { axis in
                    Text(axis.displayName).tag(axis)
                }
            }
            .pickerStyle(.segmented)
            ExpressionRow(
                label: "Begin (\(spec.axis.displayName))",
                expression: cylinderBinding(\.begin, field: "begin"),
                variables: variables,
                unitSymbol: unitSymbol,
                help: showsPositionNotes
                    ? "Absolute coordinate of the first terminal along \(spec.axis.displayName). Position \(spec.axis.displayName) is unused for a cylinder — set the extent here instead."
                    : nil
            )
            ExpressionRow(
                label: "End (\(spec.axis.displayName))",
                expression: cylinderBinding(\.end, field: "end"),
                variables: variables,
                unitSymbol: unitSymbol
            )

        case .sheet(let spec):
            Picker(
                "Normal",
                selection: Binding(
                    get: { spec.normal },
                    set: { newNormal in
                        edit("normal", "Change Sheet Normal") { $0.updateSheet { $0.normal = newNormal } }
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
                unitSymbol: unitSymbol
            )
            ExpressionRow(
                label: "Depth (\(spec.normal.perpendicular.1.displayName))",
                expression: sheetBinding(\.depth, field: "depth"),
                variables: variables,
                unitSymbol: unitSymbol
            )
            ExpressionRow(
                label: "Begin (\(spec.normal.displayName))",
                expression: sheetBinding(\.begin, field: "begin"),
                variables: variables,
                unitSymbol: unitSymbol,
                help: showsPositionNotes
                    ? "Absolute coordinate of the first face along \(spec.normal.displayName). Position \(spec.normal.displayName) is unused for a sheet — set the extent here instead. Equal begin/end is allowed and means an infinitely thin sheet."
                    : nil
            )
            ExpressionRow(
                label: "End (\(spec.normal.displayName))",
                expression: sheetBinding(\.end, field: "end"),
                variables: variables,
                unitSymbol: unitSymbol
            )

            if let begin = try? spec.begin.value(variables: variables),
               let end = try? spec.end.value(variables: variables),
               begin == end {
                Label(
                    "Zero-thickness sheet — meshed as a surface. Ideal for a PEC patch or ground plane.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bindings

    private func boxBinding(_ axis: Axis, isBegin: Bool) -> Binding<Expression> {
        let field = "\(isBegin ? "begin" : "end")\(axis.displayName)"
        return Binding(
            get: {
                guard let spec = primitive.boxSpec else { return .unset }
                return isBegin ? spec.begin(axis) : spec.end(axis)
            },
            set: { newValue in
                edit(field, "Edit Dimension") { primitive in
                    primitive.updateBox { spec in
                        if isBegin { spec.setBegin(axis, newValue) } else { spec.setEnd(axis, newValue) }
                    }
                }
            }
        )
    }

    private func cylinderBinding(
        _ keyPath: WritableKeyPath<CylinderSpec, Expression>,
        field: String
    ) -> Binding<Expression> {
        Binding(
            get: { primitive.cylinderSpec?[keyPath: keyPath] ?? .unset },
            set: { newValue in
                edit(field, "Edit Dimension") { $0.updateCylinder { $0[keyPath: keyPath] = newValue } }
            }
        )
    }

    private func sheetBinding(
        _ keyPath: WritableKeyPath<SheetSpec, Expression>,
        field: String
    ) -> Binding<Expression> {
        Binding(
            get: { primitive.sheetSpec?[keyPath: keyPath] ?? .unset },
            set: { newValue in
                edit(field, "Edit Dimension") { $0.updateSheet { $0[keyPath: keyPath] = newValue } }
            }
        )
    }
}
