import Foundation

/// Constants and functions available inside dimension expressions.
///
/// `c0` in particular matters for antenna work: `lambda = c0 / f / 1000` in a
/// millimetre project, or just write `lambda_mm = 299792.458 / f_MHz`.
public enum ExpressionBuiltins {
    public static let constants: [String: Double] = [
        "pi": Double.pi,
        "tau": 2 * Double.pi,
        "e": M_E,
        // Speed of light in vacuum, m/s.
        "c0": 299_792_458.0,
        // Vacuum permittivity, F/m.
        "eps0": 8.854_187_812_8e-12,
        // Vacuum permeability, H/m.
        "mu0": 4e-7 * Double.pi,
        // Free-space wave impedance, ohm.
        "z0": 376.730_313_668
    ]

    /// Accepted argument counts per function name.
    public static let functionArity: [String: ClosedRange<Int>] = [
        "abs": 1...1,
        "sqrt": 1...1,
        "cbrt": 1...1,
        "exp": 1...1,
        "log": 1...1,
        "ln": 1...1,
        "log10": 1...1,
        "log2": 1...1,
        "sin": 1...1,
        "cos": 1...1,
        "tan": 1...1,
        "asin": 1...1,
        "acos": 1...1,
        "atan": 1...1,
        "sinh": 1...1,
        "cosh": 1...1,
        "tanh": 1...1,
        "sind": 1...1,
        "cosd": 1...1,
        "tand": 1...1,
        "floor": 1...1,
        "ceil": 1...1,
        "round": 1...1,
        "sign": 1...1,
        "deg": 1...1,
        "rad": 1...1,
        "atan2": 2...2,
        "pow": 2...2,
        "hypot": 2...2,
        "mod": 2...2,
        "min": 1...16,
        "max": 1...16,
        "clamp": 3...3,
        "lerp": 3...3
    ]

    /// Names a user variable may not take, so that `pi` and `sqrt` always mean
    /// what they look like.
    public static var reservedNames: Set<String> {
        Set(constants.keys).union(functionArity.keys)
    }

    public static func call(_ name: String, arguments: [Double]) throws -> Double {
        guard let arity = functionArity[name] else {
            throw ExpressionError.unknownFunction(name)
        }
        guard arity.contains(arguments.count) else {
            let expected = arity.lowerBound == arity.upperBound
                ? "\(arity.lowerBound)"
                : "\(arity.lowerBound)–\(arity.upperBound)"
            throw ExpressionError.wrongArgumentCount(
                function: name,
                expected: expected,
                got: arguments.count
            )
        }

        let toRadians = Double.pi / 180
        let result: Double

        switch name {
        case "abs": result = abs(arguments[0])
        case "sqrt": result = sqrt(arguments[0])
        case "cbrt": result = cbrt(arguments[0])
        case "exp": result = exp(arguments[0])
        case "log", "ln": result = log(arguments[0])
        case "log10": result = log10(arguments[0])
        case "log2": result = log2(arguments[0])
        case "sin": result = sin(arguments[0])
        case "cos": result = cos(arguments[0])
        case "tan": result = tan(arguments[0])
        case "asin": result = asin(arguments[0])
        case "acos": result = acos(arguments[0])
        case "atan": result = atan(arguments[0])
        case "sinh": result = sinh(arguments[0])
        case "cosh": result = cosh(arguments[0])
        case "tanh": result = tanh(arguments[0])
        case "sind": result = sin(arguments[0] * toRadians)
        case "cosd": result = cos(arguments[0] * toRadians)
        case "tand": result = tan(arguments[0] * toRadians)
        case "floor": result = arguments[0].rounded(.down)
        case "ceil": result = arguments[0].rounded(.up)
        case "round": result = arguments[0].rounded()
        case "sign": result = arguments[0] == 0 ? 0 : (arguments[0] < 0 ? -1 : 1)
        case "deg": result = arguments[0] / toRadians
        case "rad": result = arguments[0] * toRadians
        case "atan2": result = atan2(arguments[0], arguments[1])
        case "pow": result = pow(arguments[0], arguments[1])
        case "hypot": result = (arguments[0] * arguments[0] + arguments[1] * arguments[1]).squareRoot()
        case "mod":
            guard arguments[1] != 0 else { throw ExpressionError.divisionByZero }
            result = fmod(arguments[0], arguments[1])
        case "min": result = arguments.min() ?? 0
        case "max": result = arguments.max() ?? 0
        case "clamp": result = min(max(arguments[0], arguments[1]), arguments[2])
        case "lerp": result = arguments[0] + (arguments[1] - arguments[0]) * arguments[2]
        default: throw ExpressionError.unknownFunction(name)
        }

        guard result.isFinite else { throw ExpressionError.notFinite }
        return result
    }
}
