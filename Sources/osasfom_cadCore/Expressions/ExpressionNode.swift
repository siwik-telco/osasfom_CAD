import Foundation

public enum BinaryOperator: String, Hashable, Sendable {
    case add = "+"
    case subtract = "-"
    case multiply = "*"
    case divide = "/"
    case modulo = "%"
    case power = "^"
}

public indirect enum ExpressionNode: Hashable, Sendable {
    case number(Double)
    case variable(String)
    case negate(ExpressionNode)
    case binary(BinaryOperator, ExpressionNode, ExpressionNode)
    case call(String, [ExpressionNode])

    /// Names this node reads from the variable scope. Function names are not
    /// included — they resolve against the builtin table, not user variables.
    public var referencedVariableNames: Set<String> {
        switch self {
        case .number:
            return []
        case .variable(let name):
            // Builtin constants are not user variables and must not create a
            // dependency edge.
            return ExpressionBuiltins.constants[name] == nil ? [name] : []
        case .negate(let operand):
            return operand.referencedVariableNames
        case .binary(_, let lhs, let rhs):
            return lhs.referencedVariableNames.union(rhs.referencedVariableNames)
        case .call(_, let arguments):
            return arguments.reduce(into: Set<String>()) { result, argument in
                result.formUnion(argument.referencedVariableNames)
            }
        }
    }
}

/// Recursive-descent parser.
///
/// Grammar (lowest precedence first):
/// ```
/// expression := term (("+" | "-") term)*
/// term       := unary (("*" | "/" | "%") unary)*
/// unary      := ("-" | "+") unary | power
/// power      := primary ("^" unary)?      // right associative
/// primary    := number | identifier | identifier "(" args ")" | "(" expression ")"
/// ```
/// So `-2^2 == -4` and `2^-1 == 0.5`, matching the usual mathematical reading.
public struct ExpressionParser {
    private let tokens: [ExpressionToken]
    private var position = 0

    private init(tokens: [ExpressionToken]) {
        self.tokens = tokens
    }

    public static func parse(_ source: String) throws -> ExpressionNode {
        let tokens = try ExpressionLexer.tokenize(source)
        guard !tokens.isEmpty else { throw ExpressionError.empty }

        var parser = ExpressionParser(tokens: tokens)
        let node = try parser.parseExpression()
        if let leftover = parser.peek() {
            throw ExpressionError.trailingInput(leftover.text)
        }
        return node
    }

    private func peek() -> ExpressionToken.Kind? {
        position < tokens.count ? tokens[position].kind : nil
    }

    private mutating func advance() -> ExpressionToken.Kind? {
        guard position < tokens.count else { return nil }
        defer { position += 1 }
        return tokens[position].kind
    }

    private mutating func match(_ kind: ExpressionToken.Kind) -> Bool {
        guard peek() == kind else { return false }
        position += 1
        return true
    }

    private mutating func parseExpression() throws -> ExpressionNode {
        var left = try parseTerm()
        while let kind = peek() {
            let operatorKind: BinaryOperator
            switch kind {
            case .plus: operatorKind = .add
            case .minus: operatorKind = .subtract
            default: return left
            }
            position += 1
            let right = try parseTerm()
            left = .binary(operatorKind, left, right)
        }
        return left
    }

    private mutating func parseTerm() throws -> ExpressionNode {
        var left = try parseUnary()
        while let kind = peek() {
            let operatorKind: BinaryOperator
            switch kind {
            case .star: operatorKind = .multiply
            case .slash: operatorKind = .divide
            case .percent: operatorKind = .modulo
            default: return left
            }
            position += 1
            let right = try parseUnary()
            left = .binary(operatorKind, left, right)
        }
        return left
    }

    private mutating func parseUnary() throws -> ExpressionNode {
        if match(.minus) {
            return .negate(try parseUnary())
        }
        if match(.plus) {
            return try parseUnary()
        }
        return try parsePower()
    }

    private mutating func parsePower() throws -> ExpressionNode {
        let base = try parsePrimary()
        guard match(.caret) else { return base }
        let exponent = try parseUnary()
        return .binary(.power, base, exponent)
    }

    private mutating func parsePrimary() throws -> ExpressionNode {
        guard let kind = advance() else { throw ExpressionError.unexpectedEnd }

        switch kind {
        case .number(let value):
            return .number(value)

        case .identifier(let name):
            guard match(.leftParen) else { return .variable(name) }
            var arguments: [ExpressionNode] = []
            if peek() != .rightParen {
                repeat {
                    arguments.append(try parseExpression())
                } while match(.comma)
            }
            guard match(.rightParen) else {
                throw peek().map { ExpressionError.unexpectedToken($0.text) } ?? ExpressionError.unexpectedEnd
            }
            return .call(name, arguments)

        case .leftParen:
            let inner = try parseExpression()
            guard match(.rightParen) else {
                throw peek().map { ExpressionError.unexpectedToken($0.text) } ?? ExpressionError.unexpectedEnd
            }
            return inner

        default:
            throw ExpressionError.unexpectedToken(kind.text)
        }
    }
}
