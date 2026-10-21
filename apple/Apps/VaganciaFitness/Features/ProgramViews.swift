import FitnessCore
import FitnessRuntime
import SwiftUI

struct ProgramListView: View {
    @Bindable var coordinator: WorkoutCoordinator
    let startWorkout: (WorkoutProgram) -> Void
    @State private var filter: ProgramFilter = .all
    @State private var draft: WorkoutProgram?
    @State private var error: String?

    private var filtered: [WorkoutProgram] {
        coordinator.programs.filter { program in
            switch filter {
            case .all: true
            case .short: program.durationSeconds <= 20 * 60
            case .long: program.durationSeconds > 20 * 60
            }
        }
    }

    var body: some View {
        ScreenContent {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Elige un plan y ajusta cada etapa a tu ritmo.", bundle: .main))
                    .font(FitnessType.body(.subheadline)).foregroundStyle(FitnessPalette.secondary)
            }
            Picker(String(localized: "Duración del programa", bundle: .main), selection: $filter) {
                ForEach(ProgramFilter.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("program-duration-filter")

            if filtered.isEmpty {
                ContentUnavailableView(
                    String(localized: "No hay programas en este filtro", bundle: .main),
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text(
                        String(localized: "Prueba otra duración o crea un programa.", bundle: .main)))
            } else {
                LazyVStack(spacing: 16) {
                    ForEach(filtered) { program in
                        NavigationLink {
                            ProgramDetailView(
                                coordinator: coordinator, program: program, startWorkout: startWorkout)
                        } label: {
                            ProgramRow(program: program, prominent: program.id == filtered.first?.id)
                        }.buttonStyle(.plain).accessibilityIdentifier("program-\(program.id)")
                    }
                }

            }

            Button {
                draft = WorkoutProgram(
                    name: String(localized: "Mi programa", bundle: .main),
                    intervals: [.init(durationSeconds: 120, targetSpeedKPH: 5, phase: .warmup)])
            } label: {
                Label(String(localized: "Crear programa", bundle: .main), systemImage: "plus").font(
                    FitnessType.body(.headline)
                ).frame(maxWidth: .infinity).frame(height: 52)
            }.buttonStyle(.bordered).tint(FitnessPalette.text).accessibilityIdentifier("create-program")
        }
        .navigationTitle(String(localized: "Programas", bundle: .main))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $draft) { draft in
            ProgramEditorView(program: draft, limits: coordinator.targetLimits) { saved in
                do {
                    try coordinator.saveProgram(saved)
                    coordinator.refresh()
                    self.draft = nil
                } catch { self.error = error.localizedDescription }
            }
        }
        .alert(
            String(localized: "No se pudo guardar", bundle: .main),
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .refreshable { coordinator.refresh() }
    }
}

private enum ProgramFilter: String, CaseIterable, Identifiable {
    case all, short, long
    var id: Self { self }
    var title: String {
        switch self {
        case .all: String(localized: "Todos", bundle: .main)
        case .short: String(localized: "Hasta 20 min", bundle: .main)
        case .long: String(localized: "Más de 20 min", bundle: .main)
        }
    }
}

struct ProgramRow: View {
    let program: WorkoutProgram
    var prominent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(program.localizedSeedName()).font(FitnessType.body(.title3, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: prominent ? "arrow.up.right" : "chevron.right").foregroundStyle(
                    FitnessPalette.accent)
            }
            if prominent { ProgramProfile(intervals: program.intervals) }
            Text(
                String(
                    localized:
                        "\(max(1, program.durationSeconds / 60)) min · \(FitnessText.intervalCount(program.intervals.count))",
                    bundle: .main)
            )
            .font(FitnessType.metadata).foregroundStyle(FitnessPalette.secondary)
        }
        .padding(prominent ? 18 : 0).padding(.vertical, prominent ? 0 : 16)
        .background(prominent ? FitnessPalette.paper : .clear, in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .bottom) {
            if !prominent { Rectangle().fill(FitnessPalette.border).frame(height: 1) }
        }
        .contentShape(Rectangle())
    }
}

struct ProgramDetailView: View {
    @Bindable var coordinator: WorkoutCoordinator
    let program: WorkoutProgram
    let startWorkout: (WorkoutProgram) -> Void
    @State private var showDelete = false
    @State private var message: String?
    @State private var editValue: WorkoutProgram?

    var body: some View {
        ScreenContent {
            VStack(alignment: .leading, spacing: 12) {
                Text(program.localizedSeedName()).font(FitnessType.title()).fixedSize(
                    horizontal: false, vertical: true)
                Text(
                    String(
                        localized:
                            "\(FitnessText.intervalCount(program.intervals.count)) · \(max(1, program.durationSeconds / 60)) min",
                        bundle: .main)
                ).font(FitnessType.body(.subheadline)).foregroundStyle(FitnessPalette.secondary)
            }.padding(.top, 4)

            VStack(alignment: .leading, spacing: 14) {
                ProgramProfile(intervals: program.intervals)
                HStack {
                    Text(String(localized: "0 min", bundle: .main))
                    Spacer()
                    Text(String(localized: "\(max(1, program.durationSeconds / 60)) min", bundle: .main))
                }.font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
                HStack(spacing: 18) {
                    Label(String(localized: "Ritmo objetivo", bundle: .main), systemImage: "speedometer")
                        .font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
                    Label(
                        String(localized: "Inclinación planificada", bundle: .main), systemImage: "mountain.2"
                    ).font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
                }
            }.padding(18).background(FitnessPalette.paper, in: RoundedRectangle(cornerRadius: 14))

            SectionTitle(title: String(localized: "Etapas", bundle: .main))
            VStack(spacing: 0) {
                ForEach(Array(program.intervals.enumerated()), id: \.element.id) { index, interval in
                    HStack(spacing: 12) {
                        Text("\(index + 1)").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(
                            interval.phase == .work ? FitnessPalette.canvas : FitnessPalette.secondary
                        ).frame(width: 30, height: 30).background(
                            interval.phase == .work ? FitnessPalette.red : FitnessPalette.surface, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(interval.phase.title).font(FitnessType.body(.subheadline, weight: .semibold))
                            Text(
                                String(
                                    localized:
                                        "\(interval.durationLabel) · \(interval.targetSpeedKPH.formatted(.number.precision(.fractionLength(1)))) km/h · \(interval.targetInclinationPercent.formatted(.number.precision(.fractionLength(0))))% planificado",
                                    bundle: .main)
                            ).font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
                        }
                        Spacer()
                    }.padding(.vertical, 13)
                    if index < program.intervals.count - 1 { Divider().padding(.leading, 42) }
                }
            }.padding(.horizontal, 15).background(
                FitnessPalette.paper, in: RoundedRectangle(cornerRadius: 14))

            Text(
                String(
                    localized:
                        "Los valores describen el programa. La máquina puede aceptar rangos distintos.",
                    bundle: .main)
            ).font(FitnessType.body(.footnote)).foregroundStyle(FitnessPalette.secondary)
            Button {
                startWorkout(program)
            } label: {
                Label(String(localized: "Iniciar programa", bundle: .main), systemImage: "play.fill").font(
                    FitnessType.body(.headline)
                ).frame(maxWidth: .infinity).frame(height: 54)
            }.buttonStyle(.glassProminent).tint(FitnessPalette.text).foregroundStyle(
                FitnessPalette.canvas
            ).accessibilityIdentifier("start-program")
        }
        .navigationTitle(String(localized: "Programa", bundle: .main))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(String(localized: "Editar programa", bundle: .main), systemImage: "pencil") {
                        editValue = program
                    }
                    Button(
                        String(localized: "Duplicar programa", bundle: .main),
                        systemImage: "plus.square.on.square"
                    ) { duplicate() }
                    Divider()
                    Button(
                        String(localized: "Eliminar programa", bundle: .main), systemImage: "trash",
                        role: .destructive
                    ) { showDelete = true }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel(String(localized: "Opciones del programa", bundle: .main))
            }
        }
        .sheet(item: $editValue) { editValue in
            ProgramEditorView(program: editValue, limits: coordinator.targetLimits) { saved in
                do {
                    try coordinator.saveProgram(saved)
                    coordinator.refresh()
                    self.editValue = nil
                } catch { message = error.localizedDescription }
            }
        }
        .confirmationDialog(
            String(localized: "¿Eliminar este programa?", bundle: .main), isPresented: $showDelete,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Eliminar programa", bundle: .main), role: .destructive) {
                do {
                    try coordinator.deleteProgram(id: program.id)
                    coordinator.refresh()
                } catch { message = error.localizedDescription }
            }
            Button(String(localized: "Cancelar", bundle: .main), role: .cancel) {}
        } message: {
            Text(String(localized: "El historial de actividad se conservará.", bundle: .main))
        }
        .alert(
            "VAGANCIA FITNESS",
            isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
        ) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func duplicate() {
        let copy = WorkoutProgram(
            name: String(localized: "\(program.name) (copia)", bundle: .main),
            intervals: program.intervals.map {
                .init(
                    durationSeconds: $0.durationSeconds, targetSpeedKPH: $0.targetSpeedKPH,
                    targetInclinationPercent: $0.targetInclinationPercent, phase: $0.phase)
            })
        do {
            try coordinator.saveProgram(copy)
            coordinator.refresh()
        } catch { message = error.localizedDescription }
    }
}

private struct ProgramEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var program: WorkoutProgram
    @State private var editingInterval: WorkoutInterval?
    @State private var isNewInterval = false
    @State private var error: String?
    @State private var showDiscard = false
    let limits: WorkoutTargetLimits
    let onSave: (WorkoutProgram) -> Void

    init(
        program: WorkoutProgram, limits: WorkoutTargetLimits, onSave: @escaping (WorkoutProgram) -> Void
    ) {
        _program = State(initialValue: program)
        self.limits = limits
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Programa", bundle: .main)) {
                    TextField(String(localized: "Nombre", bundle: .main), text: $program.name).onChange(
                        of: program.name
                    ) { _, value in if value.count > 60 { program.name = String(value.prefix(60)) } }
                    .accessibilityIdentifier("program-name-field")
                    Text(
                        String(
                            localized:
                                "De 1 a 60 caracteres · \(program.durationSeconds / 60) min · \(FitnessText.intervalCount(program.intervals.count))",
                            bundle: .main)
                    ).font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
                }
                Section {
                    ForEach(Array(program.intervals.enumerated()), id: \.element.id) { index, interval in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(interval.phase.title).font(FitnessType.body(.subheadline, weight: .semibold))
                                    Text(
                                        String(
                                            localized:
                                                "\(interval.durationLabel) · \(interval.targetSpeedKPH.formatted(.number.precision(.fractionLength(1)))) km/h · \(interval.targetInclinationPercent.formatted(.number.precision(.fractionLength(0))))%",
                                            bundle: .main)
                                    ).font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
                                }
                                Spacer()
                                Menu {
                                    Button(String(localized: "Editar", bundle: .main), systemImage: "pencil") {
                                        editingInterval = interval
                                        isNewInterval = false
                                    }
                                    if index > 0 {
                                        Button(String(localized: "Subir", bundle: .main), systemImage: "arrow.up") {
                                            move(index, -1)
                                        }
                                    }
                                    if index < program.intervals.count - 1 {
                                        Button(String(localized: "Bajar", bundle: .main), systemImage: "arrow.down") {
                                            move(index, 1)
                                        }
                                    }
                                    Button(
                                        String(localized: "Duplicar", bundle: .main),
                                        systemImage: "plus.square.on.square"
                                    ) { duplicate(index) }
                                    Button(
                                        String(localized: "Eliminar", bundle: .main), systemImage: "trash",
                                        role: .destructive
                                    ) { program.intervals.remove(at: index) }
                                } label: {
                                    Image(systemName: "ellipsis.circle").font(FitnessType.body(.title3)).frame(
                                        width: 44, height: 44)
                                }.accessibilityLabel(
                                    String(localized: "Acciones de etapa \(index + 1)", bundle: .main))
                            }
                        }.accessibilityIdentifier("editor-interval-\(index)")
                    }
                    Button {
                        editingInterval = WorkoutInterval(durationSeconds: 90, targetSpeedKPH: 8, phase: .work)
                        isNewInterval = true
                    } label: {
                        Label(String(localized: "Añadir intervalo", bundle: .main), systemImage: "plus")
                    }.accessibilityIdentifier("add-workout-interval")
                } header: {
                    Text(String(localized: "Etapas", bundle: .main))
                } footer: {
                    Text(
                        String(
                            localized:
                                "Límites guardados: \(limits.speed.minimum.formatted(.number.precision(.fractionLength(0...1))))–\(limits.speed.maximum.formatted(.number.precision(.fractionLength(0...1)))) km/h, pasos de \(limits.speed.increment.formatted(.number.precision(.fractionLength(0...1)))); inclinación \(limits.inclination.minimum.formatted(.number.precision(.fractionLength(0...1))))–\(limits.inclination.maximum.formatted(.number.precision(.fractionLength(0...1))))%, pasos de \(limits.inclination.increment.formatted(.number.precision(.fractionLength(0...1)))). Los límites anunciados se validan de nuevo al iniciar.",
                            bundle: .main))
                }
            }
            .fitnessSurface()
            .navigationTitle(String(localized: "Editar programa", bundle: .main))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancelar", bundle: .main)) { showDiscard = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Guardar", bundle: .main)) { save() }.fontWeight(.semibold)
                        .accessibilityIdentifier("save-program")
                }
            }
            .sheet(item: $editingInterval) { interval in
                IntervalEditorView(interval: interval, limits: limits) { updated in
                    if isNewInterval {
                        program.intervals.append(updated)
                    } else if let index = program.intervals.firstIndex(where: { $0.id == updated.id }) {
                        program.intervals[index] = updated
                    }
                    editingInterval = nil
                }
            }
            .alert(
                String(localized: "Revisa el programa", bundle: .main),
                isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
            ) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .confirmationDialog(
                String(localized: "¿Salir sin guardar?", bundle: .main), isPresented: $showDiscard,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Descartar cambios", bundle: .main), role: .destructive) {
                    dismiss()
                }
                Button(String(localized: "Seguir editando", bundle: .main), role: .cancel) {}
            } message: {
                Text(String(localized: "Los cambios de este programa se perderán.", bundle: .main))
            }
        }
    }

    private func move(_ index: Int, _ direction: Int) {
        let destination = index + direction
        guard program.intervals.indices.contains(destination) else { return }
        program.intervals.swapAt(index, destination)
    }
    private func duplicate(_ index: Int) {
        let value = program.intervals[index]
        program.intervals.insert(
            .init(
                durationSeconds: value.durationSeconds, targetSpeedKPH: value.targetSpeedKPH,
                targetInclinationPercent: value.targetInclinationPercent, phase: value.phase), at: index + 1
        )
    }
    private func save() {
        do {
            try WorkoutProgram.validate(name: program.name, intervals: program.intervals, limits: limits)
            program.name = program.name.trimmingCharacters(in: .whitespacesAndNewlines)
            program.updatedAt = Date()
            onSave(program)
        } catch let issue as WorkoutProgramValidationError {
            switch issue {
            case .invalidName:
                error = String(localized: "El nombre debe tener entre 1 y 60 caracteres.", bundle: .main)
            case .noIntervals: error = String(localized: "Añade al menos un intervalo.", bundle: .main)
            case .invalidDuration:
                error = String(
                    localized: "Cada intervalo debe durar entre 15 y 3600 segundos.", bundle: .main)
            case .invalidSpeed:
                error = String(
                    localized:
                        "La velocidad debe estar entre \(limits.speed.minimum) y \(limits.speed.maximum) km/h, en pasos de \(limits.speed.increment).",
                    bundle: .main)
            case .invalidInclination:
                error = String(
                    localized:
                        "La inclinación debe estar entre \(limits.inclination.minimum) y \(limits.inclination.maximum)%, en pasos de \(limits.inclination.increment).",
                    bundle: .main)
            case .invalidLimits:
                error = String(localized: "Los límites de edición no son válidos.", bundle: .main)
            }
        } catch { self.error = error.localizedDescription }
    }
}

private struct IntervalEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var interval: WorkoutInterval
    @State private var error: String?
    let limits: WorkoutTargetLimits
    let onSave: (WorkoutInterval) -> Void

    init(
        interval: WorkoutInterval, limits: WorkoutTargetLimits,
        onSave: @escaping (WorkoutInterval) -> Void
    ) {
        _interval = State(initialValue: interval)
        self.limits = limits
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker(String(localized: "Tipo", bundle: .main), selection: $interval.phase) {
                    ForEach(WorkoutPhase.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Section {
                    LabeledContent(
                        String(localized: "Duración", bundle: .main), value: interval.durationLabel)
                    HStack(spacing: 0) {
                        Picker(String(localized: "Minutos", bundle: .main), selection: durationMinutes) {
                            ForEach(0...60, id: \.self) {
                                Text(String(localized: "\($0) min", bundle: .main)).tag($0)
                            }
                        }.accessibilityIdentifier("interval-duration-minutes")
                        Picker(String(localized: "Segundos", bundle: .main), selection: durationSeconds) {
                            ForEach(secondOptions, id: \.self) {
                                Text(String(localized: "\($0) s", bundle: .main)).tag($0)
                            }
                        }.accessibilityIdentifier("interval-duration-seconds")
                    }
                    .pickerStyle(.wheel)
                    .frame(height: dynamicTypeSize.isAccessibilitySize ? 180 : 130)
                } header: {
                    Text(String(localized: "Tiempo", bundle: .main))
                } footer: {
                    Text(String(localized: "De 15 segundos a 60 minutos.", bundle: .main))
                }
                Section {
                    IntervalTargetControl(
                        title: String(localized: "Velocidad", bundle: .main), value: $interval.targetSpeedKPH,
                        range: limits.speed, unit: "km/h", identifier: "interval-speed")
                } header: {
                    Text(String(localized: "Velocidad", bundle: .main))
                } footer: {
                    Text(
                        String(
                            localized:
                                "Cada paso cambia \(limits.speed.increment.formatted(.number.precision(.fractionLength(0...2)))) km/h.",
                            bundle: .main))
                }
                Section {
                    IntervalTargetControl(
                        title: String(localized: "Inclinación", bundle: .main),
                        value: $interval.targetInclinationPercent, range: limits.inclination, unit: "%",
                        identifier: "interval-incline")
                } header: {
                    Text(String(localized: "Inclinación", bundle: .main))
                } footer: {
                    Text(
                        String(
                            localized:
                                "Cada paso cambia \(limits.inclination.increment.formatted(.number.precision(.fractionLength(0...2)))) %.",
                            bundle: .main))
                }
                if let error { Text(error).foregroundStyle(.red).font(FitnessType.body(.footnote)) }
            }
            .fitnessSurface()
            .navigationTitle(String(localized: "Intervalo", bundle: .main))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancelar", bundle: .main)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Guardar", bundle: .main)) { save() }.accessibilityIdentifier(
                        "save-interval")
                }
            }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
    }

    private var durationMinutes: Binding<Int> {
        Binding(
            get: { interval.durationSeconds / 60 },
            set: { minutes in
                interval.durationSeconds = min(3600, max(15, minutes * 60 + interval.durationSeconds % 60))
            })
    }
    private var durationSeconds: Binding<Int> {
        Binding(
            get: { interval.durationSeconds % 60 },
            set: { seconds in
                interval.durationSeconds = min(3600, max(15, interval.durationSeconds / 60 * 60 + seconds))
            })
    }
    private var secondOptions: [Int] {
        if interval.durationSeconds / 60 == 60 { return [0] }
        return Array((interval.durationSeconds < 60 ? 15 : 0)...59)
    }

    private func save() {
        do {
            try WorkoutProgram.validate(
                name: String(localized: "Intervalo", bundle: .main), intervals: [interval], limits: limits)
            onSave(interval)
            dismiss()
        } catch let issue as WorkoutProgramValidationError {
            switch issue {
            case .invalidDuration:
                error = String(localized: "La duración debe estar entre 15 y 3600 segundos.", bundle: .main)
            case .invalidSpeed:
                error = String(
                    localized:
                        "La velocidad debe estar entre \(limits.speed.minimum) y \(limits.speed.maximum) km/h, con pasos de \(limits.speed.increment).",
                    bundle: .main)
            case .invalidInclination:
                error = String(
                    localized:
                        "La inclinación debe estar entre \(limits.inclination.minimum) y \(limits.inclination.maximum)%, con pasos de \(limits.inclination.increment).",
                    bundle: .main)
            default: error = String(localized: "Revisa los valores del intervalo.", bundle: .main)
            }
        } catch { self.error = error.localizedDescription }
    }
}

/// Edits a program draft; these controls never send commands to the treadmill.
private struct IntervalTargetControl: View {
    let title: String
    @Binding var value: Double
    let range: FTMSRange
    let unit: String
    let identifier: String

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Stepper(value: $value, in: range.minimum...range.maximum, step: range.increment) {
                Text(String(localized: "\(formatted(value)) \(unit)", bundle: .main)).font(
                    FitnessType.body(.title2, weight: .semibold)
                ).monospacedDigit()
            }
            .accessibilityLabel(title)
            .accessibilityValue(String(localized: "\(formatted(value)) \(unit)", bundle: .main))
            .accessibilityIdentifier("\(identifier)-stepper")
            .frame(minHeight: 44)
            if range.minimum < range.maximum {
                Slider(value: $value, in: range.minimum...range.maximum, step: range.increment)
                    .accessibilityLabel(title)
                    .accessibilityValue(String(localized: "\(formatted(value)) \(unit)", bundle: .main))
                    .accessibilityIdentifier("\(identifier)-slider")
                    .frame(minHeight: 44)
            }
            HStack {
                Text(String(localized: "\(formatted(range.minimum)) \(unit)", bundle: .main))
                Spacer()
                Text(String(localized: "\(formatted(range.maximum)) \(unit)", bundle: .main))
            }.font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
        }.padding(.vertical, 4)
    }
}
