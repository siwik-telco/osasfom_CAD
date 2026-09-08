import SwiftUI
import Charts
import osasfom_cadCore
import osasfom_cadSolver

/// Lets the user launch the FDTD solver on the current document and see its
/// return-loss result — the "Run" inspector tab.
struct SimulationRunnerView: View {
    @ObservedObject var document: CADDocument
    @ObservedObject var runner: SimulationRunner
    /// Owned by the main view: the 3D overlay and its legend show the same
    /// frequency and quantity as these plots, so the selection has to be one
    /// value rather than one per view.
    @Binding var farFieldFrequencyIndex: Int
    @Binding var farFieldQuantity: FarFieldQuantity

    @State private var errorMessage: String?
    @State private var resultsTab: ResultsTab = .chart
    /// Runs picked in the history table. One inspects, several compare.
    @State private var comparisonSelection = Set<Int>()
    /// Marker frequencies dropped on the comparison chart, in hertz.
    @State private var comparisonMarkers: [Double] = []
    @State private var exportFormat: ResultsExporter.Format = .csv
    @State private var plotMinGHzText: String = ""
    @State private var plotMaxGHzText: String = ""

    private enum ResultsTab: String, CaseIterable, Identifiable {
        case chart = "Chart"
        case table = "Table"
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            runSection
            if !runner.s11Spectrum.isEmpty {
                resultsSection
            }
            farFieldSection
            if !runner.history.isEmpty {
                historySection
            }
        }
        .formStyle(.grouped)
        .onAppear { runner.loadHistory(for: document.fileURL) }
        .onReceive(NotificationCenter.default.publisher(for: .cadDocumentCommand)) { notification in
            guard case .exportResults? = notification.object as? DocumentCommand else { return }
            exportResults()
        }
        .onChange(of: document.fileURL) { url in
            // Swapping projects swaps the stored history with it, so runs from
            // one model never show up under another.
            comparisonSelection = []
            comparisonMarkers = []
            runner.loadHistory(for: url)
        }
        .onChange(of: runner.plotRange) { range in
            guard let range else { return }
            plotMinGHzText = String(format: "%.3f", range.minimumHertz / 1e9)
            plotMaxGHzText = String(format: "%.3f", range.maximumHertz / 1e9)
        }
    }

    // MARK: - Run

    private var runSection: some View {
        Section("FDTD Solver") {
            if runner.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: runner.progress) {
                        Text("Running… \(Int(runner.progress * 100))%")
                    }
                    if runner.gridSize != (0, 0, 0) {
                        Text("Grid \(runner.gridSize.0) × \(runner.gridSize.1) × \(runner.gridSize.2) cells")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        runner.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                }
            } else {
                Button {
                    start()
                } label: {
                    Label("Run Simulation", systemImage: "play.fill")
                }
                .disabled(!canRun)

                if !canRun {
                    Text(disabledReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var canRun: Bool {
        !runner.isRunning
            && document.resolved.errorCount == 0
            && document.resolved.simulation.domain != nil
            && document.resolved.simulation.ports.contains { $0.kind == .lumped && $0.isExcited }
    }

    private var disabledReason: String {
        if document.resolved.errorCount > 0 {
            return "Fix the model's errors first (see the diagnostics bar)."
        }
        if document.resolved.simulation.domain == nil {
            return "No computational domain — add a visible body, or set manual domain bounds."
        }
        if !document.resolved.simulation.ports.contains(where: { $0.kind == .lumped && $0.isExcited }) {
            return "Add an excited lumped port to compute a return loss."
        }
        return ""
    }

    private func start() {
        errorMessage = nil
        do {
            try runner.run(document: document)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Results

    private var resultsSection: some View {
        Section {
            if runner.wasStoppedEarly {
                Label("Stopped early — spectrum is from a partial, less-converged run.", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Picker("", selection: $resultsTab) {
                ForEach(ResultsTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch resultsTab {
            case .chart:
                resultsChart
            case .table:
                resultsTable
            }

            plotRangeControl
            Divider()
            exportControls

            if let center = runner.s11DbAtCenter {
                LabeledContent("At band center") {
                    Text(String(format: "%.2f dB", center)).monospacedDigit()
                }
            }
            if let deepest = runner.s11Spectrum.min(by: { $0.decibels < $1.decibels }) {
                LabeledContent("Deepest dip") {
                    Text(String(format: "%.2f dB @ %.3f GHz", deepest.decibels, deepest.hertz / 1e9))
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Return Loss (S11)")
        } footer: {
            Text("The absorbing boundary is an approximate lossy layer, not a true PML, so treat this as a qualitative resonance estimate.")
                .font(.caption)
        }
    }

    /// Lets the plot be zoomed into a sub-band of what was actually
    /// simulated, recomputed instantly from the recorded time series (no
    /// re-run needed) — useful for a closer look at a resonance without
    /// paying for a fresh, narrower-band simulation.
    private var plotRangeControl: some View {
        HStack(spacing: 8) {
            Text("Plot range").foregroundStyle(.secondary)
            TextField("Min", text: $plotMinGHzText)
                .frame(width: 60)
            Text("–").foregroundStyle(.secondary)
            TextField("Max", text: $plotMaxGHzText)
                .frame(width: 60)
            Text("GHz").foregroundStyle(.secondary)
            Spacer()
            Button("Apply") {
                guard let minGHz = Double(plotMinGHzText), let maxGHz = Double(plotMaxGHzText) else { return }
                runner.setPlotRange(minimumHertz: minGHz * 1e9, maximumHertz: maxGHz * 1e9)
            }
            Button("Full Sweep") {
                runner.resetPlotRangeToFullSweep()
            }
        }
        .font(.caption)
        .textFieldStyle(.roundedBorder)
    }

    private var resultsChart: some View {
        s11Chart(runner.s11Spectrum, height: 180)
    }

    /// One S11 plot, with its axes pinned to the data.
    ///
    /// Left to itself Swift Charts picks a "nice" numeric domain anchored at
    /// zero, so a 2–3 GHz sweep spent two thirds of the plot on frequencies
    /// that were never simulated and squashed the resonance into a spike.
    /// The swept range *is* the interesting range, so it is stated outright —
    /// and the dB axis is derived too, so a dip deeper than the default
    /// domain can't be clipped off the bottom.
    @ViewBuilder
    private func s11Chart(_ spectrum: [S11Point], height: CGFloat) -> some View {
        let domain = S11PlotDomain(spectrum)
        Chart(spectrum, id: \.hertz) { point in
            LineMark(
                x: .value("Frequency", point.hertz / 1e9),
                y: .value("S11", point.decibels)
            )
        }
        .chartXScale(domain: domain.frequencyGHz)
        .chartYScale(domain: domain.decibels)
        .chartXAxisLabel("GHz")
        .chartYAxisLabel("dB")
        .frame(height: height)
    }

    private var resultsTable: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(runner.s11Spectrum, id: \.hertz) { point in
                    HStack {
                        Text(String(format: "%.3f GHz", point.hertz / 1e9))
                        Spacer()
                        Text(String(format: "%.2f dB", point.decibels))
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
        .frame(height: 180)
    }

    // MARK: - History

    /// Every completed run this session, each tied to the variable values
    /// that produced it — selecting one shows those values against the
    /// document's *current* ones, so a variable changed since that run is
    /// immediately visible rather than silently invalidating the old result.
    /// Shown whenever there is a pattern to show, or a reason there isn't.
    @ViewBuilder
    private var farFieldSection: some View {
        if let warning = runner.farFieldWarning {
            Section("Far Field") {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } else if !runner.farFieldPatterns.isEmpty {
            Section("Radiation Pattern") {
                FarFieldPatternView(
                    patterns: runner.farFieldPatterns,
                    frequencyIndex: $farFieldFrequencyIndex,
                    quantity: $farFieldQuantity
                )
            }
        }
    }

    /// What the export acts on: the selected runs, or the live result when
    /// nothing is selected. Exporting "whatever is on screen" is what a user
    /// means by Export.
    private var runsToExport: [RunRecord] {
        let selected = selectedRuns
        guard selected.isEmpty else { return selected }
        return runner.history.suffix(1)
    }

    @ViewBuilder
    private var exportControls: some View {
        if !runsToExport.isEmpty {
            HStack {
                Picker("Format", selection: $exportFormat) {
                    ForEach(ResultsExporter.Format.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .fixedSize()

                Spacer()

                Button {
                    exportResults()
                } label: {
                    Label(exportButtonTitle, systemImage: "square.and.arrow.up")
                }
                .disabled(!exportFormat.supportsMultipleRuns && runsToExport.count > 1)
            }

            if !exportFormat.supportsMultipleRuns && runsToExport.count > 1 {
                Text("Touchstone holds one network per file. Select a single run, or export CSV to compare several.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var exportButtonTitle: String {
        let count = runsToExport.count
        return count == 1 ? "Export Return Loss…" : "Export \(count) Runs…"
    }

    private func exportResults() {
        let runs = runsToExport
        guard !runs.isEmpty else {
            errorMessage = "There are no results to export yet. Run a simulation first."
            return
        }
        guard exportFormat.supportsMultipleRuns || runs.count == 1 else {
            errorMessage = ResultsExporter.Format.touchstone.displayName
                + " holds one network per file. Select a single run, or export CSV."
            return
        }

        let text: String
        do {
            switch exportFormat {
            case .csv:
                text = ResultsExporter.csv(runs: runs, labels: RunComparison.labels(for: runs))
            case .touchstone:
                text = try ResultsExporter.touchstone(
                    run: runs[0],
                    referenceOhm: document.state.simulation.ports.first?.impedanceOhm ?? 50
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        guard let url = ProjectPanels.chooseResultsExportLocation(
            suggestedName: ResultsExporter.suggestedFileName(
                projectName: document.displayName,
                runs: runs,
                format: exportFormat
            ),
            fileExtension: exportFormat.fileExtension
        ) else { return }

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private var historySection: some View {
        Section("Run History") {
            Table(runner.history.reversed(), selection: $comparisonSelection) {
                TableColumn("Run") { record in
                    Text("#\(record.id)")
                }
                .width(40)
                TableColumn("Deepest dip") { record in
                    if let deepest = record.s11Spectrum.min(by: { $0.decibels < $1.decibels }) {
                        Text(String(format: "%.2f dB @ %.3f GHz", deepest.decibels, deepest.hertz / 1e9))
                    } else {
                        Text("—")
                    }
                }
                TableColumn("Steps") { record in
                    Text(record.wasStoppedEarly ? "\(record.maximumTimeSteps) (stopped)" : "\(record.maximumTimeSteps)")
                }
                .width(100)
                TableColumn("Time") { record in
                    Text(record.timestamp, style: .time)
                }
                .width(80)
            }
            .frame(minHeight: 120, maxHeight: 220)

            HStack {
                Text(selectionHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !comparisonSelection.isEmpty {
                    Button("Deselect") { comparisonSelection = [] }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                if !runner.history.isEmpty {
                    Button("Clear History", role: .destructive) {
                        comparisonSelection = []
                        runner.clearHistory()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            if selectedRuns.count == 1, let record = selectedRuns.first {
                historyDetail(record)
            } else if selectedRuns.count > 1 {
                comparisonDetail
            }
        }
    }

    /// Runs picked for comparison, in the order they were run so the legend
    /// reads oldest to newest.
    private var selectedRuns: [RunRecord] {
        runner.history.filter { comparisonSelection.contains($0.id) }
    }

    private var selectionHint: String {
        switch selectedRuns.count {
        case 0: return "Select a run to inspect it, or several to compare."
        case 1: return "Select another run to overlay them."
        default: return "\(selectedRuns.count) runs overlaid."
        }
    }

    /// Several runs at once: one chart with every trace, plus the radiation
    /// patterns of whichever of them recorded one.
    private var comparisonDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            RunComparisonChart(runs: selectedRuns, markers: $comparisonMarkers)

            Text("Click the chart to drop a marker and read every trace at that frequency.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if selectedRuns.contains(where: { !$0.farFieldPatterns.isEmpty }) {
                Divider()
                HStack {
                    Text("Radiation Pattern").font(.callout.bold())
                    Spacer()
                    Picker("", selection: $farFieldQuantity) {
                        ForEach(FarFieldQuantity.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                }
                FarFieldComparisonView(
                    runs: selectedRuns,
                    quantity: farFieldQuantity,
                    thetaCutDegrees: 90,
                    dynamicRangeDb: 40
                )
                Text("The 3D pattern in the viewport always shows the most recent run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func historyDetail(_ record: RunRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // A stored run keeps its own swept range, which may differ from
            // whatever the live chart is currently showing.
            s11Chart(record.s11Spectrum, height: 140)

            Text("Variables at this run")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            let currentValues = document.resolved.variables.values
            ForEach(record.variableSnapshot.keys.sorted(), id: \.self) { name in
                let storedValue = record.variableSnapshot[name] ?? 0
                let currentValue = currentValues[name]
                let changed = currentValue.map { abs($0 - storedValue) > 1e-12 } ?? true

                HStack {
                    Text(name).font(.caption.monospaced())
                    Spacer()
                    Text(Expression.literalSource(storedValue))
                        .font(.caption.monospaced())
                        .foregroundStyle(changed ? .orange : .secondary)
                    if changed {
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text(currentValue.map(Expression.literalSource) ?? "removed")
                            .font(.caption.monospaced())
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}
