import Foundation

/// A parametric scalar: the *source text* the user typed, never a baked-in
/// number.
///
/// This is the central fix for the old design, where resolved variable values
/// were written back into the geometry. Because the model stores only source
/// text, editing a dimension can never be silently clobbered by a later
/// re-resolve, and there is exactly one place a value can come from.
///
/// An empty expression means "not set". Optional-valued settings use that
/// instead of `Expression?`, which keeps the recursive rename walk uniform.
public struct Expression: Codable, Hashable, Sendable, CustomStringConvertible {
    public var source: String

    public init(source: String) {
        self.source = source
    }

    public init(_ value: Double) {
        self.source = Self.literalSource(value)
    }

    public static let unset = Expression(source: "")
    public static let zero = Expression(0)
    public static let one = Expression(1)

    public var trimmed: String {
        source.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmpty: Bool { trimmed.isEmpty }

    public var description: String { source }

    // MARK: - Codable

    /// Encoded as a bare JSON string so project files stay readable and
    /// hand-editable: `"width": "patch_w"`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self.source = text
        } else {
            // Tolerate a bare number, which is what a hand-written file or an
            // older exporter is likely to contain.
            self.source = Self.literalSource(try container.decode(Double.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(source)
    }

    // MARK: - Evaluation

    public func node() throws -> ExpressionNode {
        guard !isEmpty else { throw ExpressionError.empty }
        return try ExpressionParser.parse(trimmed)
    }

    public func value(variables: [String: Double] = [:]) throws -> Double {
        try ExpressionEvaluator.evaluate(node(), variables: variables)
    }

    /// Non-throwing form for UI previews.
    public func evaluate(variables: [String: Double] = [:]) -> Result<Double, ExpressionError> {
        do {
            return .success(try value(variables: variables))
        } catch let error as ExpressionError {
            return .failure(error)
        } catch {
            return .failure(.notFinite)
        }
    }

    /// `nil` when unset; throws when set but invalid. Lets callers distinguish
    /// "the user left this blank" from "the user typed nonsense".
    public func optionalValue(variables: [String: Double] = [:]) throws -> Double? {
        guard !isEmpty else { return nil }
        return try value(variables: variables)
    }

    public var referencedVariableNames: Set<String> {
        (try? node().referencedVariableNames) ?? []
    }

    // MARK: - Renaming

    /// Rewrites references to `oldName` as `newName`, token-accurately.
    ///
    /// This is what makes name-based variable references safe: renaming a
    /// variable refactors every expression that mentions it instead of leaving
    /// dangling references. Substrings (`w` inside `width`) and same-named
    /// functions are left alone, and all other characters — including spacing —
    /// are preserved exactly.
    public func renamingVariable(_ oldName: String, to newName: String) -> Expression {
        guard oldName != newName, !oldName.isEmpty, !newName.isEmpty else { return self }
        guard let tokens = try? ExpressionLexer.tokenize(source), !tokens.isEmpty else { return self }

        var result = ""
        var cursor = source.startIndex
        var didChange = false

        for (offset, token) in tokens.enumerated() {
            guard case .identifier(let name) = token.kind, name == oldName else { continue }
            let isFunctionCall = offset + 1 < tokens.count && tokens[offset + 1].kind == .leftParen
            guard !isFunctionCall else { continue }

            result += source[cursor..<token.range.lowerBound]
            result += newName
            cursor = token.range.upperBound
            didChange = true
        }

        guard didChange else { return self }
        result += source[cursor...]
        return Expression(source: result)
    }

    // MARK: - Formatting

    /// Locale-independent compact formatting. Always uses `.` as the decimal
    /// separator so a project file round-trips identically on any machine.
    public static func literalSource(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == 0 { return "0" }

        let magnitude = abs(value)
        if value == value.rounded() && magnitude < 1e15 {
            return String(Int64(value))
        }
        if magnitude >= 1e-4 && magnitude < 1e12 {
            var text = String(format: "%.6f", value)
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            return text.isEmpty ? "0" : text
        }
        return String(format: "%g", value)
    }
}

public enum ExpressionEvaluator {
    public static func evaluate(_ node: ExpressionNode, variables: [String: Double]) throws -> Double {
        let result = try rawValue(node, variables: variables)
        guard result.isFinite else { throw ExpressionError.notFinite }
        return result
    }

    private static func rawValue(_ node: ExpressionNode, variables: [String: Double]) throws -> Double {
        switch node {
        case .number(let value):
            return value

        case .variable(let name):
            // User variables shadow nothing: reserved names are rejected at
            // validation time, so this order can never surprise anyone.
            if let value = variables[name] { return value }
            if let constant = ExpressionBuiltins.constants[name] { return constant }
            throw ExpressionError.unknownVariable(name)

        case .negate(let operand):
            return -(try rawValue(operand, variables: variables))

        case .binary(let operatorKind, let lhsNode, let rhsNode):
            let lhs = try rawValue(lhsNode, variables: variables)
            let rhs = try rawValue(rhsNode, variables: variables)
            switch operatorKind {
            case .add:
                return lhs + rhs
            case .subtract:
                return lhs - rhs
            case .multiply:
                return lhs * rhs
            case .divide:
                guard rhs != 0 else { throw ExpressionError.divisionByZero }
                return lhs / rhs
            case .modulo:
                guard rhs != 0 else { throw ExpressionError.divisionByZero }
                return fmod(lhs, rhs)
            case .power:
                let result = pow(lhs, rhs)
                guard result.isFinite else { throw ExpressionError.notFinite }
                return result
            }

        case .call(let name, let argumentNodes):
            let arguments = try argumentNodes.map { try rawValue($0, variables: variables) }
            return try ExpressionBuiltins.call(name, arguments: arguments)
        }
    }
}
