import Foundation

public struct ExpressionToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case number(Double)
        case identifier(String)
        case plus
        case minus
        case star
        case slash
        case percent
        case caret
        case leftParen
        case rightParen
        case comma

        public var text: String {
            switch self {
            case .number(let value): return Expression.literalSource(value)
            case .identifier(let name): return name
            case .plus: return "+"
            case .minus: return "-"
            case .star: return "*"
            case .slash: return "/"
            case .percent: return "%"
            case .caret: return "^"
            case .leftParen: return "("
            case .rightParen: return ")"
            case .comma: return ","
            }
        }
    }

    public let kind: Kind
    /// Range within the source string, used for identifier-accurate renaming.
    public let range: Range<String.Index>

    public init(kind: Kind, range: Range<String.Index>) {
        self.kind = kind
        self.range = range
    }
}

/// Tokenizer for the dimension-expression language.
///
/// Deliberately ASCII-only and locale-independent: `.` is the one decimal
/// separator, so a project file means the same thing on every machine. (The old
/// code accepted `,` as a decimal separator, which silently changed meaning
/// between locales.)
public enum ExpressionLexer {
    public static func tokenize(_ source: String) throws -> [ExpressionToken] {
        var tokens: [ExpressionToken] = []
        var index = source.startIndex

        while index < source.endIndex {
            let character = source[index]

            if character.isWhitespace {
                index = source.index(after: index)
                continue
            }

            let start = index

            if let simple = simpleKind(for: character) {
                index = source.index(after: index)
                tokens.append(ExpressionToken(kind: simple, range: start..<index))
                continue
            }

            if isDigit(character) || character == "." {
                index = scanNumberEnd(in: source, from: index)
                let text = String(source[start..<index])
                guard let value = Double(text), value.isFinite else {
                    throw ExpressionError.invalidNumber(text)
                }
                tokens.append(ExpressionToken(kind: .number(value), range: start..<index))
                continue
            }

            if isIdentifierStart(character) {
                index = scanIdentifierEnd(in: source, from: index)
                let text = String(source[start..<index])
                tokens.append(ExpressionToken(kind: .identifier(text), range: start..<index))
                continue
            }

            throw ExpressionError.invalidCharacter(String(character))
        }

        return tokens
    }

    private static func simpleKind(for character: Character) -> ExpressionToken.Kind? {
        switch character {
        case "+": return .plus
        case "-": return .minus
        case "*": return .star
        case "/": return .slash
        case "%": return .percent
        case "^": return .caret
        case "(": return .leftParen
        case ")": return .rightParen
        case ",": return .comma
        default: return nil
        }
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        (character.isASCII && character.isLetter) || character == "_"
    }

    private static func isIdentifierBody(_ character: Character) -> Bool {
        isIdentifierStart(character) || isDigit(character)
    }

    private static func scanNumberEnd(in source: String, from start: String.Index) -> String.Index {
        var index = start
        var sawDecimalPoint = false

        while index < source.endIndex {
            let character = source[index]
            if isDigit(character) {
                index = source.index(after: index)
            } else if character == "." && !sawDecimalPoint {
                sawDecimalPoint = true
                index = source.index(after: index)
            } else {
                break
            }
        }

        // Optional exponent, only consumed if it is well formed. `2e` stays a
        // number followed by an identifier, which the parser then rejects.
        guard index < source.endIndex, source[index] == "e" || source[index] == "E" else {
            return index
        }

        var probe = source.index(after: index)
        if probe < source.endIndex, source[probe] == "+" || source[probe] == "-" {
            probe = source.index(after: probe)
        }
        guard probe < source.endIndex, isDigit(source[probe]) else { return index }

        while probe < source.endIndex, isDigit(source[probe]) {
            probe = source.index(after: probe)
        }
        return probe
    }

    private static func scanIdentifierEnd(in source: String, from start: String.Index) -> String.Index {
        var index = start
        while index < source.endIndex, isIdentifierBody(source[index]) {
            index = source.index(after: index)
        }
        return index
    }
}
