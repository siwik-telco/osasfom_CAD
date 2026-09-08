import Foundation
import osasfom_cadCore

/// Works out what distinguishes one run from another, so overlaid traces can
/// be labelled by *what changed* rather than by an opaque run number.
///
/// Comparing two runs of the same antenna, the interesting fact is almost
/// never "#3 versus #4" — it is "x = 10 versus x = 9". This finds that.
public enum RunComparison {

    /// Variable names whose value is not the same across every run given.
    ///
    /// A variable missing from one run's snapshot counts as differing: it was
    /// added or removed between runs, which is exactly the kind of change
    /// worth surfacing.
    public static func differingVariableNames(across runs: [RunRecord]) -> [String] {
        guard runs.count > 1 else { return [] }

        var names = Set<String>()
        for run in runs { names.formUnion(run.variableSnapshot.keys) }

        return names.filter { name in
            let values = runs.map { $0.variableSnapshot[name] }
            guard let first = values.first else { return false }
            return values.contains { !sameValue($0, first) }
        }
        .sorted()
    }

    /// Treats absence as distinct from any value, and compares numbers with a
    /// tolerance so a variable that merely re-resolved to the same quantity
    /// doesn't register as a change.
    private static func sameValue(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (let a?, let b?): return abs(a - b) <= 1e-12 * max(1, max(abs(a), abs(b)))
        default: return false
        }
    }

    /// A short label for one run within a comparison set.
    ///
    /// Falls back to the run number when nothing distinguishes the runs by
    /// variables — re-running an unchanged model to check convergence is a
    /// normal thing to do, and those runs still need telling apart.
    public static func label(for run: RunRecord, differingIn names: [String]) -> String {
        guard !names.isEmpty else { return "#\(run.id)" }

        let parts = names.compactMap { name -> String? in
            guard let value = run.variableSnapshot[name] else { return "\(name) —" }
            return "\(name) = \(format(value))"
        }
        // More than a couple of differences stop being a legible legend entry.
        let shown = parts.prefix(2).joined(separator: ", ")
        let remainder = parts.count - min(parts.count, 2)
        return remainder > 0 ? "#\(run.id) · \(shown) +\(remainder)" : "#\(run.id) · \(shown)"
    }

    /// Trailing zeros dropped, so 9 reads as "9" and not "9.000".
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e12 {
            return String(Int(value))
        }
        return String(format: "%g", value)
    }

    /// Labels for a whole set, computed once so every trace is labelled
    /// against the same set of differing names.
    public static func labels(for runs: [RunRecord]) -> [Int: String] {
        let names = differingVariableNames(across: runs)
        return Dictionary(uniqueKeysWithValues: runs.map { ($0.id, label(for: $0, differingIn: names)) })
    }

    /// How a run's headline number moved against a baseline, for a "what did
    /// that change buy me" read-out.
    public struct Delta: Sendable {
        public let decibels: Double
        public let hertz: Double
    }

    /// The shift in the deepest dip from `baseline` to `run`.
    public static func deepestDipDelta(from baseline: RunRecord, to run: RunRecord) -> Delta? {
        guard let before = baseline.deepestDip, let after = run.deepestDip else { return nil }
        return Delta(decibels: after.decibels - before.decibels, hertz: after.hertz - before.hertz)
    }
}
