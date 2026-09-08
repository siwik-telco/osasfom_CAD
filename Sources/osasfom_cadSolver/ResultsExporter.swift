import Foundation
import osasfom_cadCore

/// Writes return-loss results out in formats other tools read.
public enum ResultsExporter {

    public enum Format: String, CaseIterable, Identifiable, Sendable {
        /// Frequency plus one column per run — the format for a spreadsheet,
        /// a plotting script, or comparing several runs side by side.
        case csv
        /// The RF industry's own S-parameter format, read by every VNA and
        /// simulator. One network per file, so a single run only.
        case touchstone

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .csv: return "CSV"
            case .touchstone: return "Touchstone (.s1p)"
            }
        }

        public var fileExtension: String {
            switch self {
            case .csv: return "csv"
            case .touchstone: return "s1p"
            }
        }

        /// Touchstone describes one network, so several runs cannot share a
        /// file — the comparison case is CSV's.
        public var supportsMultipleRuns: Bool { self == .csv }
    }

    // MARK: - CSV

    /// One frequency column, then a dB column per run.
    ///
    /// Runs are sampled on their own frequency points, which need not match
    /// across a comparison — a run swept over a different band is written on
    /// the union of frequencies with blanks where it has no data, rather than
    /// being silently resampled onto someone else's grid.
    public static func csv(runs: [RunRecord], labels: [Int: String] = [:]) -> String {
        guard !runs.isEmpty else { return "" }

        let frequencies = Array(Set(runs.flatMap { $0.s11Spectrum.map(\.hertz) })).sorted()
        let names = runs.map { labels[$0.id] ?? "run \($0.id)" }

        var lines: [String] = []
        lines.append("# osasfom_cad return loss export")
        lines.append("# generated \(ISO8601DateFormatter().string(from: Date()))")
        for (run, name) in zip(runs, names) {
            let variables = run.variableSnapshot.keys.sorted()
                .map { "\($0)=\(RunComparison.format(run.variableSnapshot[$0] ?? 0))" }
                .joined(separator: " ")
            lines.append("# \(name): \(run.maximumTimeSteps) steps\(variables.isEmpty ? "" : "; \(variables)")")
        }

        // Phase is only written when at least one run has it, so a file from
        // older results doesn't carry a column of empty cells.
        let includePhase = runs.contains { $0.s11Spectrum.contains { $0.phaseDegrees != nil } }
        var header = ["frequency_hz"]
        for name in names {
            // The whole field is escaped, not just the label: quoting the
            // name and then appending the suffix outside the closing quote
            // produces malformed CSV that splits on the label's own comma.
            header.append(escape("\(name) s11_db"))
            if includePhase { header.append(escape("\(name) s11_deg")) }
        }
        lines.append(header.joined(separator: ","))

        for hertz in frequencies {
            var row = [format(hertz)]
            for run in runs {
                let point = run.s11Spectrum.first { abs($0.hertz - hertz) < 1e-6 }
                row.append(point.map { format($0.decibels) } ?? "")
                if includePhase {
                    row.append(point?.phaseDegrees.map(format) ?? "")
                }
            }
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Quotes a field that would otherwise break the column structure.
    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") else { return field }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // MARK: - Touchstone

    public enum TouchstoneError: Error, LocalizedError {
        case noPhaseRecorded

        public var errorDescription: String? {
            switch self {
            case .noPhaseRecorded:
                return "This run has magnitude only, with no phase. A Touchstone file without phase would be misleading to anything that de-embeds or cascades with it — export CSV instead, or re-run to record phase."
            }
        }
    }

    /// A `.s1p` file: `# HZ S DB R <z0>`, one row of frequency, magnitude in
    /// dB and phase in degrees.
    ///
    /// Refuses rather than inventing phase. A Touchstone file is a contract
    /// that the numbers are the network's actual complex response.
    public static func touchstone(run: RunRecord, referenceOhm: Double = 50) throws -> String {
        guard run.s11Spectrum.allSatisfy({ $0.phaseDegrees != nil }) else {
            throw TouchstoneError.noPhaseRecorded
        }

        var lines: [String] = []
        lines.append("!osasfom_cad return loss, run \(run.id)")
        lines.append("!generated \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("!\(run.maximumTimeSteps) timesteps, grid \(run.gridSize.0)x\(run.gridSize.1)x\(run.gridSize.2)")
        for name in run.variableSnapshot.keys.sorted() {
            lines.append("!\(name) = \(RunComparison.format(run.variableSnapshot[name] ?? 0))")
        }
        lines.append("# HZ S DB R \(format(referenceOhm))")
        lines.append("!freq          magS11(dB)   angS11(deg)")

        for point in run.s11Spectrum {
            let frequency = format(point.hertz).padding(toLength: 15, withPad: " ", startingAt: 0)
            let magnitude = format(point.decibels).padding(toLength: 13, withPad: " ", startingAt: 0)
            lines.append("\(frequency)\(magnitude)\(format(point.phaseDegrees ?? 0))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Enough digits to round-trip a frequency without losing hertz, without
    /// printing seventeen of them.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        return String(format: "%.10g", value)
    }

    /// A default file name that says what the file holds.
    public static func suggestedFileName(projectName: String, runs: [RunRecord], format: Format) -> String {
        let base = projectName.isEmpty ? "results" : projectName
        let suffix = runs.count == 1 ? "run\(runs[0].id)" : "\(runs.count)runs"
        return "\(base)-s11-\(suffix).\(format.fileExtension)"
    }
}
