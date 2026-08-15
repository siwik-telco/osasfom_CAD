import SwiftUI
import osasfom_cadCore

/// Editor for the FDTD setup: domain, boundaries, mesh, excitation, ports and
/// monitors. None of this existed before, so a body-only export could not be run.
struct SimulationInspectorView: View {
    @ObservedObject var document: CADDocument

    private var setup: SimulationSetup { document.state.simulation }
    private var variables: [String: Double] { document.resolved.variables.values }
    private var unit: String { document.state.lengthUnit.symbol }

    var body: some View {
        Form {
            projectSection
            frequencySection
            domainSection
            boundariesSection
            meshSection
            portsSection
            monitorsSection
            solverSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Project

    private var projectSection: some View {
        Section("Project") {
            TextField(
                "Name",
                text: Binding(
                    get: { document.state.name },
                    set: { document.setProjectName($0) }
                )
            )

            Picker(
                "Length unit",
                selection: Binding(
                    get: { document.state.lengthUnit },
                    set: { document.setLengthUnit($0) }
                )
            ) {
                ForEach(LengthUnit.allCases) { unit in
                    Text(unit.displayName).tag(unit)
                }
            }

            Text("Changing the unit reinterprets existing numbers rather than rescaling them — expressions such as `patch_w / 2` have no meaningful rescale.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Frequency

    private var frequencySection: some View {
        Section("Frequency") {
            HStack {
                Text("Range").foregroundStyle(.secondary)
                Spacer()
                TextField(
                    "min",
                    value: frequencyBinding(\.minimumHertz, field: "fmin"),
                    format: FieldFormat.scientific
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                TextField(
                    "max",
                    value: frequencyBinding(\.maximumHertz, field: "fmax"),
                    format: FieldFormat.scientific
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                Text("Hz").font(.caption).foregroundStyle(.secondary)
            }

            LabeledContent("Band", value: setup.frequency.description)

            if let wavelength = document.state.lengthUnit.wavelength(
                atHertz: setup.frequency.maximumHertz
            ) {
                LabeledContent(
                    "λ at f_max",
                    value: "\(Expression.literalSource(wavelength)) \(unit)"
                )
            }

            Picker(
                "Excitation",
                selection: document.simulationStepBinding(
                    \.excitation.waveform,
                    actionName: "Change Excitation"
                )
            ) {
                ForEach(ExcitationWaveform.allCases) { waveform in
                    Text(waveform.displayName).tag(waveform)
                }
            }

            if setup.excitation.waveform == .sinusoidal {
                HStack {
                    Text("Drive frequency").foregroundStyle(.secondary)
                    Spacer()
                    TextField(
                        "Hz",
                        value: document.simulationBinding(
                            \.excitation.sinusoidalHertz,
                            actionName: "Edit Excitation",
                            field: "excitation.sinusoidal"
                        ),
                        format: FieldFormat.scientific
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                }
            }
        }
    }

    // MARK: - Domain

    private var domainSection: some View {
        Section("Computational domain") {
            Picker(
                "Mode",
                selection: document.simulationStepBinding(
                    \.domain.mode,
                    actionName: "Change Domain Mode"
                )
            ) {
                ForEach(DomainSettings.Mode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            switch setup.domain.mode {
            case .automatic:
                ExpressionRow(
                    label: "Padding X",
                    expression: simulationExpression(\.domain.padding.x, field: "domain.padding.x"),
                    variables: variables,
                    unitSymbol: unit
                )
                ExpressionRow(
                    label: "Padding Y",
                    expression: simulationExpression(\.domain.padding.y, field: "domain.padding.y"),
                    variables: variables,
                    unitSymbol: unit
                )
                ExpressionRow(
                    label: "Padding Z",
                    expression: simulationExpression(\.domain.padding.z, field: "domain.padding.z"),
                    variables: variables,
                    unitSymbol: unit
                )
                Text("A quarter wavelength at the lowest frequency is the usual rule of thumb for an open boundary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .manual:
                BoundsExpressionEditor(
                    bounds: Binding(
                        get: { setup.domain.manualBounds },
                        set: { newValue in
                            document.updateSimulation(
                                actionName: "Edit Domain",
                                coalescingKey: "simulation.domain.manual"
                            ) { $0.domain.manualBounds = newValue }
                        }
                    ),
                    variables: variables,
                    unitSymbol: unit
                )
            }

            if let domain = document.resolved.simulation.domain {
                BoundsReadout(bounds: domain, unitSymbol: unit)
            }
        }
    }

    // MARK: - Boundaries

    private var boundariesSection: some View {
        Section("Boundary conditions") {
            ForEach(Axis.allCases) { axis in
                HStack {
                    Text(axis.displayName)
                        .frame(width: 16, alignment: .leading)
                        .foregroundStyle(.secondary)
                    boundaryPicker(axis: axis, isLower: true)
                    boundaryPicker(axis: axis, isLower: false)
                }
            }

            Stepper(
                value: document.simulationStepBinding(
                    \.boundaries.pmlCellCount,
                    actionName: "Change PML Thickness"
                ),
                in: 2...32
            ) {
                LabeledContent("PML cells", value: "\(setup.boundaries.pmlCellCount)")
            }
        }
    }

    private func boundaryPicker(axis: Axis, isLower: Bool) -> some View {
        Picker(
            isLower ? "min" : "max",
            selection: Binding(
                get: {
                    isLower
                        ? setup.boundaries.lower(on: axis)
                        : setup.boundaries.upper(on: axis)
                },
                set: { newValue in
                    document.updateSimulation(actionName: "Change Boundary") { simulation in
                        if isLower {
                            simulation.boundaries.setLower(newValue, on: axis)
                        } else {
                            simulation.boundaries.setUpper(newValue, on: axis)
                        }
                    }
                }
            )
        ) {
            ForEach(BoundaryCondition.allCases) { condition in
                Text(condition.shortName).tag(condition)
            }
        }
        .labelsHidden()
    }

    // MARK: - Mesh

    private var meshSection: some View {
        Section("Mesh") {
            HStack {
                Text("Cells per wavelength").foregroundStyle(.secondary)
                Spacer()
                TextField(
                    "",
                    value: document.simulationBinding(
                        \.mesh.cellsPerWavelength,
                        actionName: "Edit Mesh",
                        field: "mesh.cellsPerWavelength"
                    ),
                    format: FieldFormat.decimal
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
            }

            ExpressionRow(
                label: "Max cell size",
                expression: simulationExpression(\.mesh.maxCellSize, field: "mesh.maxCellSize"),
                variables: variables,
                unitSymbol: unit,
                allowsEmpty: true
            )
            ExpressionRow(
                label: "Min cell size",
                expression: simulationExpression(\.mesh.minCellSize, field: "mesh.minCellSize"),
                variables: variables,
                unitSymbol: unit,
                allowsEmpty: true
            )

            Toggle(
                "Snap grid lines to body faces",
                isOn: document.simulationStepBinding(
                    \.mesh.snapToBodyEdges,
                    actionName: "Toggle Mesh Snapping"
                )
            )

            let plan = document.resolved.simulation.mesh
            if let limit = plan.wavelengthLimitedCellSize {
                LabeledContent(
                    "Wavelength limit",
                    value: "\(Expression.literalSource(limit)) \(unit)"
                )
                .font(.caption)
            }
            if let effective = plan.effectiveMaxCellSize {
                LabeledContent(
                    "Effective max cell",
                    value: "\(Expression.literalSource(effective)) \(unit)"
                )
                .font(.caption)
            }
            if let cells = plan.estimatedCellCount(domain: document.resolved.simulation.domain) {
                LabeledContent("Uniform-fill estimate", value: "\(cells) cells")
                    .font(.caption)
            }
        }
    }

    // MARK: - Ports

    private var portsSection: some View {
        Section {
            if setup.ports.isEmpty {
                Text("No ports. Without one there is nothing to excite and no S-parameters to report.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(setup.ports) { port in
                PortEditor(document: document, portID: port.id)
                Divider()
            }

            Button {
                document.addPort()
            } label: {
                Label("Add SimulationPort", systemImage: "plus")
            }
        } header: {
            Text("Ports")
        }
    }

    // MARK: - Monitors

    private var monitorsSection: some View {
        Section {
            ForEach(setup.monitors) { monitor in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField(
                            "Name",
                            text: document.monitorBinding(
                                monitor.id,
                                \.name,
                                actionName: "Rename Monitor",
                                field: "name"
                            )
                        )
                        .textFieldStyle(.roundedBorder)

                        Picker(
                            "Quantity",
                            selection: document.monitorBinding(
                                monitor.id,
                                \.quantity,
                                actionName: "Change Monitor Quantity",
                                field: "quantity"
                            )
                        ) {
                            ForEach(MonitorQuantity.allCases) { quantity in
                                Text(quantity.displayName).tag(quantity)
                            }
                        }
                        .labelsHidden()

                        Text(
                            monitor.isTimeDomain
                                ? "Time domain"
                                : monitor.frequenciesHertz
                                    .map { FrequencyFormatter.string(hertz: $0) }
                                    .joined(separator: ", ")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        document.deleteMonitor(monitor.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }

                ForEach(document.resolved.diagnostics(for: .monitor(monitor.id))) { diagnostic in
                    DiagnosticRow(diagnostic: diagnostic)
                }
            }

            Button {
                document.addMonitor()
            } label: {
                Label("Add Monitor", systemImage: "plus")
            }
        } header: {
            Text("Monitors")
        }
    }

    // MARK: - Solver

    private var solverSection: some View {
        Section("Solver") {
            HStack {
                Text("Energy decay").foregroundStyle(.secondary)
                Spacer()
                TextField(
                    "",
                    value: document.simulationBinding(
                        \.solver.energyDecayDecibels,
                        actionName: "Edit Solver",
                        field: "solver.decay"
                    ),
                    format: FieldFormat.decimal
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                Text("dB").font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Text("Courant factor").foregroundStyle(.secondary)
                Spacer()
                TextField(
                    "",
                    value: document.simulationBinding(
                        \.solver.courantFactor,
                        actionName: "Edit Solver",
                        field: "solver.courant"
                    ),
                    format: FieldFormat.decimal
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
            }

            HStack {
                Text("Max time steps").foregroundStyle(.secondary)
                Spacer()
                TextField(
                    "",
                    value: document.simulationBinding(
                        \.solver.maximumTimeSteps,
                        actionName: "Edit Solver",
                        field: "solver.steps"
                    ),
                    format: .number
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
            }

            ForEach(document.resolved.diagnostics(for: .simulation)) { diagnostic in
                DiagnosticRow(diagnostic: diagnostic)
            }
        }
    }

    // MARK: - Bindings

    private func frequencyBinding(
        _ keyPath: WritableKeyPath<FrequencyRange, Double>,
        field: String
    ) -> Binding<Double> {
        Binding(
            get: { setup.frequency[keyPath: keyPath] },
            set: { newValue in
                document.updateSimulation(
                    actionName: "Edit Frequency",
                    coalescingKey: "simulation.frequency.\(field)"
                ) { simulation in
                    simulation.frequency[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func simulationExpression(
        _ keyPath: WritableKeyPath<SimulationSetup, Expression>,
        field: String
    ) -> Binding<Expression> {
        Binding(
            get: { document.state.simulation[keyPath: keyPath] },
            set: { newValue in
                document.updateSimulation(
                    actionName: "Edit Simulation",
                    coalescingKey: "simulation.\(field)"
                ) { simulation in
                    simulation[keyPath: keyPath] = newValue
                }
            }
        )
    }
}

private struct PortEditor: View {
    @ObservedObject var document: CADDocument
    let portID: UUID

    private var port: SimulationPort? {
        document.state.simulation.ports.first { $0.id == portID }
    }

    var body: some View {
        if let port {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField(
                        "Name",
                        text: document.portBinding(
                            portID,
                            \.name,
                            actionName: "Rename SimulationPort",
                            field: "name"
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    Button(role: .destructive) {
                        document.deletePort(portID)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }

                Picker(
                    "Kind",
                    selection: document.portBinding(
                        portID,
                        \.kind,
                        actionName: "Change SimulationPort Kind",
                        field: "kind"
                    )
                ) {
                    ForEach(PortKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }

                Picker(
                    "Direction",
                    selection: document.portBinding(
                        portID,
                        \.direction,
                        actionName: "Change SimulationPort Direction",
                        field: "direction"
                    )
                ) {
                    ForEach(Axis.allCases) { axis in
                        Text(axis.displayName).tag(axis)
                    }
                }
                .pickerStyle(.segmented)

                BoundsExpressionEditor(
                    bounds: Binding(
                        get: { port.region },
                        set: { newValue in
                            document.updatePort(
                                portID,
                                actionName: "Edit SimulationPort",
                                coalescingKey: "port.\(portID.uuidString).region"
                            ) { $0.region = newValue }
                        }
                    ),
                    variables: document.resolved.variables.values,
                    unitSymbol: document.state.lengthUnit.symbol
                )

                HStack {
                    Text("Impedance").foregroundStyle(.secondary)
                    Spacer()
                    TextField(
                        "",
                        value: document.portBinding(
                            portID,
                            \.impedanceOhm,
                            actionName: "Edit SimulationPort Impedance",
                            field: "impedance"
                        ),
                        format: FieldFormat.decimal
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    Text("Ω").font(.caption).foregroundStyle(.secondary)
                }

                Toggle(
                    "Excite from this port",
                    isOn: document.portBinding(
                        portID,
                        \.isExcited,
                        actionName: "Toggle SimulationPort Excitation",
                        field: "excited"
                    )
                )

                ForEach(document.resolved.diagnostics(for: .port(portID))) { diagnostic in
                    DiagnosticRow(diagnostic: diagnostic)
                }
            }
        }
    }
}
