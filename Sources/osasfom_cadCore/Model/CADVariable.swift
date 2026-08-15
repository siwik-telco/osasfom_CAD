import Foundation

/// A named parametric value.
///
/// The value is itself an expression, so variables can build on each other —
/// `lambda = c0 / f0 / 1e6`, `patch_w = 0.49 * lambda`. Cycles are detected
/// rather than hanging or producing garbage.
public struct CADVariable: Identifiable, Codable, Hashable, Sendable, ExpressionWalkable {
    public let id: UUID
    public var name: String
    public var expression: Expression
    public var comment: String

    public init(
        id: UUID = UUID(),
        name: String,
        expression: Expression,
        comment: String = ""
    ) {
        self.id = id
        self.name = name
        self.expression = expression
        self.comment = comment
    }

    public init(id: UUID = UUID(), name: String, value: Double, comment: String = "") {
        self.init(id: id, name: name, expression: Expression(value), comment: comment)
    }

    public var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        transform(&expression)
    }

    // MARK: - Name validation

    public enum NameProblem: Hashable, Sendable, CustomStringConvertible {
        case empty
        case invalidCharacters
        case leadingDigit
        case reserved
        case duplicate

        public var description: String {
            switch self {
            case .empty:
                return "Variable name is empty."
            case .invalidCharacters:
                return "Use only letters, digits and underscores."
            case .leadingDigit:
                return "Variable names cannot start with a digit."
            case .reserved:
                return "That name is a built-in constant or function."
            case .duplicate:
                return "Another variable already uses that name."
            }
        }
    }

    /// Structural check only; duplicate detection needs the whole list.
    public static func nameProblem(for rawName: String) -> NameProblem? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .empty }

        guard let first = name.first else { return .empty }
        if first.isNumber { return .leadingDigit }

        let isValid = name.allSatisfy { character in
            (character.isASCII && (character.isLetter || character.isNumber)) || character == "_"
        }
        guard isValid else { return .invalidCharacters }

        if ExpressionBuiltins.reservedNames.contains(name) { return .reserved }
        return nil
    }
}

/// The result of evaluating the variable table.
public struct ResolvedVariables: Sendable {
    /// Only successfully resolved variables appear here. An unresolved variable
    /// is absent rather than stale — dependents then fail loudly too.
    public let values: [String: Double]
    public let valuesByID: [UUID: Double]
    public let diagnostics: [Diagnostic]

    public init(values: [String: Double], valuesByID: [UUID: Double], diagnostics: [Diagnostic]) {
        self.values = values
        self.valuesByID = valuesByID
        self.diagnostics = diagnostics
    }

    public static let empty = ResolvedVariables(values: [:], valuesByID: [:], diagnostics: [])

    public var sortedNames: [String] { values.keys.sorted() }
}

/// Evaluates the variable table in dependency order.
public enum VariableResolver {
    public static func resolve(_ variables: [CADVariable]) -> ResolvedVariables {
        var diagnostics: [Diagnostic] = []
        var variablesByName: [String: CADVariable] = [:]

        for variable in variables {
            let name = variable.trimmedName

            if let problem = CADVariable.nameProblem(for: name) {
                diagnostics.append(
                    .error(.variable(variable.id), field: "name", problem.description)
                )
                continue
            }
            if variablesByName[name] != nil {
                diagnostics.append(
                    .error(
                        .variable(variable.id),
                        field: "name",
                        CADVariable.NameProblem.duplicate.description
                    )
                )
                continue
            }
            variablesByName[name] = variable
        }

        enum ResolutionState {
            case visiting
            case resolved(Double)
            case failed
        }

        var states: [String: ResolutionState] = [:]
        var values: [String: Double] = [:]
        var valuesByID: [UUID: Double] = [:]

        // Depth-first resolution with an explicit path so a cycle can be named
        // in the diagnostic instead of just reported as "invalid".
        func resolveName(_ name: String, path: [String]) -> Double? {
            if let state = states[name] {
                switch state {
                case .resolved(let value):
                    return value
                case .failed:
                    return nil
                case .visiting:
                    let cycleStart = path.firstIndex(of: name) ?? 0
                    let cycle = Array(path[cycleStart...]) + [name]
                    if let variable = variablesByName[name] {
                        diagnostics.append(
                            .error(
                                .variable(variable.id),
                                field: "expression",
                                ExpressionError.cycle(cycle).description
                            )
                        )
                    }
                    states[name] = .failed
                    return nil
                }
            }

            guard let variable = variablesByName[name] else { return nil }

            states[name] = .visiting
            defer {
                if case .visiting = states[name] ?? .failed { states[name] = .failed }
            }

            let node: ExpressionNode
            do {
                node = try variable.expression.node()
            } catch {
                let message = (error as? ExpressionError)?.description ?? "Invalid expression."
                diagnostics.append(.error(.variable(variable.id), field: "expression", message))
                states[name] = .failed
                return nil
            }

            var scope: [String: Double] = [:]
            for dependency in node.referencedVariableNames {
                guard variablesByName[dependency] != nil else {
                    diagnostics.append(
                        .error(
                            .variable(variable.id),
                            field: "expression",
                            ExpressionError.unknownVariable(dependency).description
                        )
                    )
                    states[name] = .failed
                    return nil
                }
                guard let value = resolveName(dependency, path: path + [name]) else {
                    // The dependency already reported the root cause; adding a
                    // second message per hop just creates noise.
                    states[name] = .failed
                    return nil
                }
                scope[dependency] = value
            }

            do {
                let value = try ExpressionEvaluator.evaluate(node, variables: scope)
                states[name] = .resolved(value)
                values[name] = value
                valuesByID[variable.id] = value
                return value
            } catch {
                let message = (error as? ExpressionError)?.description ?? "Invalid expression."
                diagnostics.append(.error(.variable(variable.id), field: "expression", message))
                states[name] = .failed
                return nil
            }
        }

        for name in variablesByName.keys.sorted() {
            _ = resolveName(name, path: [])
        }

        return ResolvedVariables(values: values, valuesByID: valuesByID, diagnostics: diagnostics)
    }
}
