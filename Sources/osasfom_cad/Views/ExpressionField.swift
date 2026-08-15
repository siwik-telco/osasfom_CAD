import SwiftUI
import osasfom_cadCore

/// A text field for an `Expression`, showing what it currently evaluates to.
///
/// This is the main affordance of the parametric model: the user types
/// `patch_w / 2` and immediately sees both the source and the number, so there
/// is never a question of which one the model holds.
struct ExpressionField: View {
    let title: String
    @Binding var expression: Expression
    let variables: [String: Double]
    /// Suffix shown next to the evaluated value, normally the project unit.
    var unitSymbol: String?
    /// Treat an empty expression as valid (an unset optional setting).
    var allowsEmpty: Bool = false
    var onCommit: (() -> Void)?

    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    private var evaluation: Result<Double, ExpressionError>? {
        if expression.isEmpty { return allowsEmpty ? nil : .failure(.empty) }
        return expression.evaluate(variables: variables)
    }

    private var isLiteral: Bool {
        expression.referencedVariableNames.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(title, text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($isFocused)
                .onSubmit(commit)
                .onChange(of: draft) { newValue in
                    // Live update so the viewport tracks typing, while undo
                    // coalescing keeps it to a single step.
                    guard newValue != expression.source else { return }
                    expression = Expression(source: newValue)
                }
                .onChange(of: isFocused) { focused in
                    if focused {
                        draft = expression.source
                    } else {
                        commit()
                    }
                }
                .onAppear { draft = expression.source }
                .onChange(of: expression) { newValue in
                    // Reflect programmatic changes (undo, variable rename) while
                    // the field is not being typed into.
                    guard !isFocused, newValue.source != draft else { return }
                    draft = newValue.source
                }

            statusLine
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch evaluation {
        case .none:
            Text("Automatic")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .success(let value):
            HStack(spacing: 4) {
                if !isLiteral {
                    Image(systemName: "function")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
                Text(formatted(value))
                    .font(.caption2)
                    .foregroundStyle(isLiteral ? .tertiary : .secondary)
            }
        case .failure(let error):
            Label(error.description, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func formatted(_ value: Double) -> String {
        let text = Expression.literalSource(value)
        guard let unitSymbol else { return "= \(text)" }
        return "= \(text) \(unitSymbol)"
    }

    private func commit() {
        expression = Expression(source: draft)
        onCommit?()
    }
}

/// A labelled row wrapping `ExpressionField`, so inspector sections line up.
struct ExpressionRow: View {
    let label: String
    @Binding var expression: Expression
    let variables: [String: Double]
    var unitSymbol: String?
    var allowsEmpty: Bool = false
    var help: String?
    var onCommit: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .help(help ?? "")
            Spacer(minLength: 8)
            ExpressionField(
                title: label,
                expression: $expression,
                variables: variables,
                unitSymbol: unitSymbol,
                allowsEmpty: allowsEmpty,
                onCommit: onCommit
            )
            .frame(width: 150)
        }
    }
}

/// Six expression fields for a parametric box, used by the domain, ports,
/// monitors and mesh refinements.
struct BoundsExpressionEditor: View {
    @Binding var bounds: BoundsExpression
    let variables: [String: Double]
    let unitSymbol: String
    var onCommit: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            row(axis: "X", minimum: $bounds.xMin, maximum: $bounds.xMax)
            row(axis: "Y", minimum: $bounds.yMin, maximum: $bounds.yMax)
            row(axis: "Z", minimum: $bounds.zMin, maximum: $bounds.zMax)
        }
    }

    private func row(
        axis: String,
        minimum: Binding<Expression>,
        maximum: Binding<Expression>
    ) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(axis)
                .frame(width: 14, alignment: .leading)
                .foregroundStyle(.secondary)
            ExpressionField(
                title: "\(axis) min",
                expression: minimum,
                variables: variables,
                unitSymbol: unitSymbol,
                onCommit: onCommit
            )
            ExpressionField(
                title: "\(axis) max",
                expression: maximum,
                variables: variables,
                unitSymbol: unitSymbol,
                onCommit: onCommit
            )
        }
    }
}

/// A read-only axis-aligned box display, for values that have no valid inverse.
struct BoundsReadout: View {
    let bounds: BodyBounds
    let unitSymbol: String

    var body: some View {
        VStack(spacing: 4) {
            row(axis: "X", minimum: bounds.xMin, maximum: bounds.xMax)
            row(axis: "Y", minimum: bounds.yMin, maximum: bounds.yMax)
            row(axis: "Z", minimum: bounds.zMin, maximum: bounds.zMax)
        }
        .font(.system(.caption, design: .monospaced))
    }

    private func row(axis: String, minimum: Double, maximum: Double) -> some View {
        HStack {
            Text(axis).foregroundStyle(.secondary).frame(width: 14, alignment: .leading)
            Text(Expression.literalSource(minimum))
            Text("…").foregroundStyle(.tertiary)
            Text(Expression.literalSource(maximum))
            Spacer()
            Text("Δ \(Expression.literalSource(maximum - minimum)) \(unitSymbol)")
                .foregroundStyle(.secondary)
        }
    }
}
