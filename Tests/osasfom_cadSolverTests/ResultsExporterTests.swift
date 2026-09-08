import XCTest
import osasfom_cadCore
@testable import osasfom_cadSolver

/// Exported files are read by other tools, so their shape is a contract.
/// These tests pin the parts a spreadsheet or an RF simulator would choke on.
final class ResultsExporterTests: XCTestCase {

    private func makeRun(
        id: Int,
        variables: [String: Double] = [:],
        points: [(Double, Double, Double?)] = [(2.0e9, -1.5, 170), (2.5e9, -18.2, -5), (3.0e9, -2.0, -160)]
    ) -> RunRecord {
        RunRecord(
            id: id,
            timestamp: Date(timeIntervalSinceReferenceDate: 0),
            variableSnapshot: variables,
            sweptFrequencyRange: FrequencyRange(minimumHertz: 2e9, maximumHertz: 3e9),
            maximumTimeSteps: 20_000,
            wasStoppedEarly: false,
            gridSize: (30, 40, 50),
            s11Spectrum: points.map { S11Point(hertz: $0.0, decibels: $0.1, phaseDegrees: $0.2) },
            s11DbAtCenter: -18.2
        )
    }

    /// A minimal quote-aware CSV field splitter, so the tests check what a
    /// reader would actually see rather than counting raw commas.
    static func csvFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for character in line {
            switch character {
            case "\"": inQuotes.toggle()
            case "," where !inQuotes:
                fields.append(current)
                current = ""
            default: current.append(character)
            }
        }
        fields.append(current)
        return fields
    }

    private func rows(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("!") }
    }

    // MARK: - CSV

    func testCSVHasAHeaderAndOneRowPerFrequency() {
        let text = ResultsExporter.csv(runs: [makeRun(id: 1)])
        let lines = text.split(separator: "\n").map(String.init)

        let header = try? XCTUnwrap(lines.first { $0.hasPrefix("frequency_hz") })
        XCTAssertNotNil(header)
        XCTAssertEqual(rows(text).count, 4, "header plus three sample rows")
        XCTAssertTrue(text.contains("2500000000"), "frequencies in hertz, unabbreviated")
        XCTAssertTrue(text.contains("-18.2"))
    }

    /// The comparison case: one frequency column, one dB column per run.
    func testComparingRunsGivesAColumnPerRun() throws {
        let text = ResultsExporter.csv(
            runs: [makeRun(id: 1, variables: ["x": 10]), makeRun(id: 2, variables: ["x": 9])],
            labels: [1: "#1 · x = 10", 2: "#2 · x = 9"]
        )
        let header = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("frequency_hz") })

        XCTAssertTrue(header.contains("#1 · x = 10 s11_db"))
        XCTAssertTrue(header.contains("#2 · x = 9 s11_db"))
        // freq + (db, deg) x 2 runs
        XCTAssertEqual(Self.csvFields(String(header)).count, 5)
    }

    /// Runs swept over different bands must not be silently resampled onto
    /// each other's grid — the union of frequencies is written, with blanks.
    func testRunsOnDifferentFrequencyGridsAreUnionedNotResampled() {
        let a = makeRun(id: 1, points: [(2.0e9, -1, 0), (3.0e9, -2, 0)])
        let b = makeRun(id: 2, points: [(2.5e9, -18, 0)])
        let text = ResultsExporter.csv(runs: [a, b])
        let dataRows = rows(text).dropFirst()

        XCTAssertEqual(dataRows.count, 3, "2.0, 2.5 and 3.0 GHz")
        let middle = try? XCTUnwrap(dataRows.first { $0.hasPrefix("2500000000") })
        // Run 1 has no sample at 2.5 GHz, so its cells stay empty.
        XCTAssertTrue(try! XCTUnwrap(middle).contains(",,"), "a gap, not an invented value")
    }

    /// A label containing a comma would otherwise split into two columns.
    func testLabelsWithCommasAreQuoted() throws {
        let text = ResultsExporter.csv(runs: [makeRun(id: 1)], labels: [1: "#1 · a = 1, b = 2"])
        let header = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("frequency_hz") })

        XCTAssertTrue(header.contains("\"#1 · a = 1, b = 2 s11_db\""))
        // Split the way a CSV reader would, not on every comma — the point is
        // that a reader sees three fields despite the comma in the label.
        XCTAssertEqual(Self.csvFields(String(header)).count, 3, "frequency, dB, degrees")
    }

    func testPhaseColumnsAreOmittedWhenNoRunHasPhase() throws {
        let noPhase = makeRun(id: 1, points: [(2.0e9, -1, nil), (3.0e9, -2, nil)])
        let header = try XCTUnwrap(
            ResultsExporter.csv(runs: [noPhase]).split(separator: "\n").first { $0.hasPrefix("frequency_hz") }
        )
        XCTAssertFalse(header.contains("s11_deg"), "no column of empty cells")
    }

    func testCSVCarriesTheVariablesThatProducedEachRun() {
        let text = ResultsExporter.csv(runs: [makeRun(id: 1, variables: ["x": 9, "h": 1.6])])
        XCTAssertTrue(text.contains("x=9"))
        XCTAssertTrue(text.contains("h=1.6"))
    }

    func testEmptyInputProducesNothingRatherThanAStrayHeader() {
        XCTAssertTrue(ResultsExporter.csv(runs: []).isEmpty)
    }

    // MARK: - Touchstone

    func testTouchstoneHasTheStandardOptionsLine() throws {
        let text = try ResultsExporter.touchstone(run: makeRun(id: 1), referenceOhm: 50)
        let options = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("#") })

        XCTAssertEqual(options.trimmingCharacters(in: .whitespaces), "# HZ S DB R 50")
    }

    func testTouchstoneRowsAreFrequencyMagnitudeAndPhase() throws {
        let text = try ResultsExporter.touchstone(run: makeRun(id: 1))
        let data = rows(text)

        XCTAssertEqual(data.count, 3)
        let fields = data[1].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(fields.count, 3)
        XCTAssertEqual(Double(fields[0]), 2.5e9)
        XCTAssertEqual(try XCTUnwrap(Double(fields[1])), -18.2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Double(fields[2])), -5, accuracy: 1e-9, "phase preserved, not zeroed")
    }

    /// The important refusal: a Touchstone file implies the phase is real.
    func testTouchstoneRefusesWhenPhaseWasNotRecorded() {
        let noPhase = makeRun(id: 1, points: [(2.0e9, -1, nil)])

        XCTAssertThrowsError(try ResultsExporter.touchstone(run: noPhase)) { error in
            guard case ResultsExporter.TouchstoneError.noPhaseRecorded = error else {
                return XCTFail("expected .noPhaseRecorded, got \(error)")
            }
        }
    }

    func testTouchstoneCommentsRecordTheRunItCameFrom() throws {
        let text = try ResultsExporter.touchstone(run: makeRun(id: 7, variables: ["x": 9]))

        XCTAssertTrue(text.contains("!osasfom_cad return loss, run 7"))
        XCTAssertTrue(text.contains("!x = 9"))
        XCTAssertTrue(text.contains("20000 timesteps"))
    }

    func testTouchstoneOnlySupportsOneRun() {
        XCTAssertFalse(ResultsExporter.Format.touchstone.supportsMultipleRuns)
        XCTAssertTrue(ResultsExporter.Format.csv.supportsMultipleRuns)
    }

    // MARK: - Naming

    func testSuggestedNameSaysWhatTheFileHolds() {
        XCTAssertEqual(
            ResultsExporter.suggestedFileName(projectName: "patch", runs: [makeRun(id: 3)], format: .touchstone),
            "patch-s11-run3.s1p"
        )
        XCTAssertEqual(
            ResultsExporter.suggestedFileName(
                projectName: "patch",
                runs: [makeRun(id: 1), makeRun(id: 2)],
                format: .csv
            ),
            "patch-s11-2runs.csv"
        )
    }
}
