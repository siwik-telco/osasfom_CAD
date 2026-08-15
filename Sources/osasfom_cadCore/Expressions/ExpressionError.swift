import Foundation

public enum ExpressionError: Error, Hashable, Sendable, CustomStringConvertible {
    case empty
    case invalidCharacter(String)
    case invalidNumber(String)
    case unexpectedToken(String)
    case unexpectedEnd
    case trailingInput(String)
    case unknownVariable(String)
    case unknownFunction(String)
    case wrongArgumentCount(function: String, expected: String, got: Int)
    case divisionByZero
    case notFinite
    case cycle([String])

    public var description: String {
        switch self {
        case .empty:
            return "Expression is empty."
        case .invalidCharacter(let character):
            return "Unexpected character '\(character)'."
        case .invalidNumber(let text):
            return "'\(text)' is not a valid number."
        case .unexpectedToken(let text):
            return "Unexpected '\(text)'."
        case .unexpectedEnd:
            return "Expression ends too early."
        case .trailingInput(let text):
            return "Unexpected trailing input '\(text)'."
        case .unknownVariable(let name):
            return "Unknown variable '\(name)'."
        case .unknownFunction(let name):
            return "Unknown function '\(name)'."
        case .wrongArgumentCount(let function, let expected, let got):
            return "\(function)() takes \(expected) argument(s), got \(got)."
        case .divisionByZero:
            return "Division by zero."
        case .notFinite:
            return "Result is not a finite number."
        case .cycle(let names):
            return "Circular reference: \(names.joined(separator: " → "))."
        }
    }
}
