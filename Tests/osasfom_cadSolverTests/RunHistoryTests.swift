import XCTest
import osasfom_cadCore
@testable import osasfom_cadSolver

/// Persisting run history, and working out what distinguishes one run from
/// another. Both are the machinery behind comparing several runs on one plot.
final class RunHistoryTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("osasfom-history-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeRun(
        id: Int,
        variables: [String: Double] = [:],
        dipDb: Double = -20,
        dipHertz: Double = 2.4e9,
        patterns: [FarFieldPattern] = []
    ) -> RunRecord {
        RunRecord(
            id: id,
            timestamp: Date(timeIntervalSinceReferenceDate: Double(id) * 60),
            variableSnapshot: variables,
            sweptFrequencyRange: FrequencyRange(minimumHertz: 2e9, maximumHertz: 3e9),
            maximumTimeSteps: 20_000,
            wasStoppedEarly: false,
            gridSize: (30, 40, 50),
            s11Spectrum: [
                S11Point(hertz: 2.0e9, decibels: -1),
                S11Point(hertz: dipHertz, decibels: dipDb),
                S11Point(hertz: 3.0e9, decibels: -1)
            ],
            s11DbAtCenter: -3,
            farFieldPatterns: patterns
        )
    }

    private func makePattern() -> FarFieldPattern {
        let thetas = stride(from: 0.0, through: 180.0, by: 30.0).map { $0 }
        let phis = stride(from: 0.0, to: 360.0, by: 30.0).map { $0 }
        return FarFieldPattern(
            hertz: 2.4e9,
            thetaDegrees: thetas,
            phiDegrees: phis,
            radiationIntensity: thetas.map { theta in
                phis.map { _ in pow(sin(theta * .pi / 180), 2) }
            },
            acceptedPowerWatts: 12,
            reflectionCoefficient: 0.1
        )
    }

    // MARK: - Persistence

    func testHistorySurvivesAcrossStoreInstances() {
        let project = URL(fileURLWithPath: "/tmp/patch.osasfomcad")
        let store = RunHistoryStore(directory: directory)
        store.save([makeRun(id: 1), makeRun(id: 2)], project: project)

        let reopened = RunHistoryStore(directory: directory).load(project: project)
        XCTAssertEqual(reopened.map(\.id), [1, 2])
        XCTAssertEqual(reopened[0].gridSize.0, 30, "the tuple round-trips")
        XCTAssertEqual(reopened[1].s11Spectrum.count, 3)
    }

    /// The whole point of storing patterns with the run: comparing today's
    /// radiation pattern against one from a previous session.
    func testFarFieldPatternsRoundTripWithTheRun() throws {
        let project = URL(fileURLWithPath: "/tmp/patch.osasfomcad")
        let original = makePattern()
        RunHistoryStore(directory: directory).save([makeRun(id: 1, patterns: [original])], project: project)

        let restored = try XCTUnwrap(
            RunHistoryStore(directory: directory).load(project: project).first?.farFieldPatterns.first
        )
        XCTAssertEqual(restored.hertz, original.hertz)
        XCTAssertEqual(restored.thetaDegrees, original.thetaDegrees)
        // Radiated power is re-derived on decode, so it must match rather than
        // being separately stored and drifting.
        XCTAssertEqual(restored.radiatedPowerWatts, original.radiatedPowerWatts, accuracy: 1e-12)
        XCTAssertEqual(restored.peakDirectivityDbi, original.peakDirectivityDbi, accuracy: 1e-12)
        XCTAssertEqual(restored.radiationEfficiency, original.radiationEfficiency)
    }

    /// Two projects of the same name in different folders must not share a
    /// history file.
    func testProjectsWithTheSameNameGetSeparateHistories() {
        let store = RunHistoryStore(directory: directory)
        let a = URL(fileURLWithPath: "/tmp/one/patch.osasfomcad")
        let b = URL(fileURLWithPath: "/tmp/two/patch.osasfomcad")

        store.save([makeRun(id: 1)], project: a)
        store.save([makeRun(id: 99)], project: b)

        XCTAssertEqual(store.load(project: a).map(\.id), [1])
        XCTAssertEqual(store.load(project: b).map(\.id), [99])
        XCTAssertNotEqual(store.fileURL(for: a), store.fileURL(for: b))
    }

    func testUnsavedProjectsShareAnUntitledHistory() {
        let store = RunHistoryStore(directory: directory)
        store.save([makeRun(id: 7)], project: nil)
        XCTAssertEqual(store.load(project: nil).map(\.id), [7])
    }

    func testOldestRunsAreDroppedPastTheLimit() {
        let store = RunHistoryStore(directory: directory, limit: 3)
        store.save((1...6).map { makeRun(id: $0) }, project: nil)

        XCTAssertEqual(store.load(project: nil).map(\.id), [4, 5, 6], "newest kept")
    }

    func testMissingOrCorruptHistoryLoadsEmptyRatherThanFailing() throws {
        let store = RunHistoryStore(directory: directory)
        XCTAssertTrue(store.load(project: nil).isEmpty, "nothing saved yet")

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.fileURL(for: nil))
        XCTAssertTrue(store.load(project: nil).isEmpty, "a corrupt file must not block opening")
    }

    func testClearRemovesOnlyThatProjectsHistory() {
        let store = RunHistoryStore(directory: directory)
        let a = URL(fileURLWithPath: "/tmp/a.osasfomcad")
        let b = URL(fileURLWithPath: "/tmp/b.osasfomcad")
        store.save([makeRun(id: 1)], project: a)
        store.save([makeRun(id: 2)], project: b)

        store.clear(project: a)
        XCTAssertTrue(store.load(project: a).isEmpty)
        XCTAssertEqual(store.load(project: b).map(\.id), [2])
    }

    // MARK: - Comparison

    func testOnlyChangedVariablesAreReportedAsDiffering() {
        let runs = [
            makeRun(id: 1, variables: ["x": 10, "h": 1.6, "w": 38]),
            makeRun(id: 2, variables: ["x": 9, "h": 1.6, "w": 38])
        ]
        XCTAssertEqual(RunComparison.differingVariableNames(across: runs), ["x"])
    }

    func testASingleRunHasNothingToDifferFrom() {
        XCTAssertTrue(RunComparison.differingVariableNames(across: [makeRun(id: 1, variables: ["x": 1])]).isEmpty)
    }

    /// A variable added or removed between runs is a change worth surfacing.
    func testAVariablePresentInOnlyOneRunCountsAsDiffering() {
        let runs = [
            makeRun(id: 1, variables: ["x": 10]),
            makeRun(id: 2, variables: ["x": 10, "gap": 0.7])
        ]
        XCTAssertEqual(RunComparison.differingVariableNames(across: runs), ["gap"])
    }

    /// The example from the request: "x = 10" before, "x = 9" now.
    func testLabelsNameTheChangedVariableRatherThanTheRunNumberAlone() {
        let runs = [
            makeRun(id: 1, variables: ["x": 10, "h": 1.6]),
            makeRun(id: 2, variables: ["x": 9, "h": 1.6])
        ]
        let labels = RunComparison.labels(for: runs)

        XCTAssertEqual(labels[1], "#1 · x = 10")
        XCTAssertEqual(labels[2], "#2 · x = 9")
    }

    /// Re-running an unchanged model to check convergence is normal, and those
    /// runs still have to be tellable apart.
    func testIdenticalRunsFallBackToRunNumbers() {
        let runs = [
            makeRun(id: 1, variables: ["x": 10]),
            makeRun(id: 2, variables: ["x": 10])
        ]
        XCTAssertEqual(RunComparison.labels(for: runs), [1: "#1", 2: "#2"])
    }

    func testManyDifferencesAreTruncatedToStayLegible() {
        let runs = [
            makeRun(id: 1, variables: ["a": 1, "b": 1, "c": 1, "d": 1]),
            makeRun(id: 2, variables: ["a": 2, "b": 2, "c": 2, "d": 2])
        ]
        let label = try? XCTUnwrap(RunComparison.labels(for: runs)[1])
        XCTAssertEqual(label, "#1 · a = 1, b = 1 +2")
    }

    func testDeepestDipDeltaReportsBothAxes() throws {
        let before = makeRun(id: 1, dipDb: -12, dipHertz: 2.40e9)
        let after = makeRun(id: 2, dipDb: -20, dipHertz: 2.45e9)

        let delta = try XCTUnwrap(RunComparison.deepestDipDelta(from: before, to: after))
        XCTAssertEqual(delta.decibels, -8, accuracy: 1e-9, "8 dB deeper")
        XCTAssertEqual(delta.hertz, 0.05e9, accuracy: 1e3, "and 50 MHz higher")
    }

    // MARK: - Runner integration

    /// Swapping the open project swaps the history with it.
    @MainActor
    func testRunnerLoadsThePerProjectHistory() {
        let store = RunHistoryStore(directory: directory)
        let a = URL(fileURLWithPath: "/tmp/a.osasfomcad")
        let b = URL(fileURLWithPath: "/tmp/b.osasfomcad")
        store.save([makeRun(id: 1)], project: a)
        store.save([makeRun(id: 2), makeRun(id: 3)], project: b)

        let runner = SimulationRunner(historyStore: store)
        runner.loadHistory(for: a)
        XCTAssertEqual(runner.history.map(\.id), [1])

        runner.loadHistory(for: b)
        XCTAssertEqual(runner.history.map(\.id), [2, 3], "history follows the project")
    }

    /// Saving an untitled project must not look like it wiped the runs made
    /// before the save — they belong to this model and move with it.
    @MainActor
    func testUntitledHistoryMovesToTheProjectOnFirstSave() {
        let store = RunHistoryStore(directory: directory)
        store.save([makeRun(id: 1), makeRun(id: 2)], project: nil)

        let runner = SimulationRunner(historyStore: store)
        runner.loadHistory(for: nil)
        XCTAssertEqual(runner.history.map(\.id), [1, 2])

        let saved = URL(fileURLWithPath: "/tmp/freshly-saved.osasfomcad")
        runner.loadHistory(for: saved)

        XCTAssertEqual(runner.history.map(\.id), [1, 2], "runs survive the save")
        XCTAssertEqual(store.load(project: saved).map(\.id), [1, 2], "and are now the project's")
    }

    /// An existing project's own history still wins — the carry-over is only
    /// for the untitled-to-named transition.
    @MainActor
    func testAProjectWithItsOwnHistoryIsNotOverwritten() {
        let store = RunHistoryStore(directory: directory)
        let existing = URL(fileURLWithPath: "/tmp/existing.osasfomcad")
        store.save([makeRun(id: 42)], project: existing)
        store.save([makeRun(id: 1)], project: nil)

        let runner = SimulationRunner(historyStore: store)
        runner.loadHistory(for: nil)
        runner.loadHistory(for: existing)

        XCTAssertEqual(runner.history.map(\.id), [42])
    }

    @MainActor
    func testClearHistoryRemovesItFromDiskToo() {
        let store = RunHistoryStore(directory: directory)
        let project = URL(fileURLWithPath: "/tmp/c.osasfomcad")
        store.save([makeRun(id: 1)], project: project)

        let runner = SimulationRunner(historyStore: store)
        runner.loadHistory(for: project)
        runner.clearHistory()

        XCTAssertTrue(runner.history.isEmpty)
        XCTAssertTrue(store.load(project: project).isEmpty, "and stays cleared after a relaunch")
    }

}
