import Foundation

/// A model-validation message.
///
/// The resolver never silently repairs bad input. Anything questionable becomes
/// a diagnostic that the UI surfaces, and anything unusable makes the affected
/// object drop out of the resolved model rather than falling back to a stale
/// value.
public struct Diagnostic: Identifiable, Hashable, Sendable {
    public enum Severity: String, Hashable, Sendable, Comparable {
        case warning
        case error

        private var rank: Int {
            switch self {
            case .warning: return 0
            case .error: return 1
            }
        }

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    /// What the diagnostic is attached to, so the UI can badge the right row.
    public enum Subject: Hashable, Sendable {
        case project
        case variable(UUID)
        case body(UUID)
        case material(UUID)
        case simulation
        case port(UUID)
        case monitor(UUID)

        public var key: String {
            switch self {
            case .project: return "project"
            case .variable(let id): return "variable:\(id.uuidString)"
            case .body(let id): return "body:\(id.uuidString)"
            case .material(let id): return "material:\(id.uuidString)"
            case .simulation: return "simulation"
            case .port(let id): return "port:\(id.uuidString)"
            case .monitor(let id): return "monitor:\(id.uuidString)"
            }
        }

        public var bodyID: UUID? {
            if case .body(let id) = self { return id }
            return nil
        }

        public var variableID: UUID? {
            if case .variable(let id) = self { return id }
            return nil
        }
    }

    public let severity: Severity
    public let subject: Subject
    /// Dotted path of the offending field, e.g. `"primitive.width"`.
    public let field: String?
    public let message: String

    public init(severity: Severity, subject: Subject, field: String? = nil, message: String) {
        self.severity = severity
        self.subject = subject
        self.field = field
        self.message = message
    }

    /// Deterministic — no `UUID()` in pure code, so resolving twice produces
    /// identical diagnostics and SwiftUI does not churn.
    public var id: String {
        "\(severity.rawValue)|\(subject.key)|\(field ?? "")|\(message)"
    }

    public static func error(_ subject: Subject, field: String? = nil, _ message: String) -> Diagnostic {
        Diagnostic(severity: .error, subject: subject, field: field, message: message)
    }

    public static func warning(_ subject: Subject, field: String? = nil, _ message: String) -> Diagnostic {
        Diagnostic(severity: .warning, subject: subject, field: field, message: message)
    }
}

extension Array where Element == Diagnostic {
    public var errors: [Diagnostic] { filter { $0.severity == .error } }
    public var warnings: [Diagnostic] { filter { $0.severity == .warning } }
    public var hasErrors: Bool { contains { $0.severity == .error } }

    public func forSubject(_ subject: Diagnostic.Subject) -> [Diagnostic] {
        filter { $0.subject == subject }
    }

    /// Errors first, then stable by identity.
    public func sortedForDisplay() -> [Diagnostic] {
        sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.id < rhs.id
        }
    }
}
