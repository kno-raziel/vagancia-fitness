import Charts
import FitnessCore
import FitnessRuntime
import SwiftUI
import UIKit

struct ActivityView: View {
    @Bindable var coordinator: WorkoutCoordinator
    let selectPrograms: () -> Void
    @State private var samplesByWorkout: [String: [WorkoutRecordedSample]] = [:]

    private var sessions: [WorkoutRecord] { coordinator.history }
    private var seconds: TimeInterval {
        sessions.reduce(0) { total, record in
            let wall = max(0, (record.endedAt ?? record.startedAt).timeIntervalSince(record.startedAt))
            return total + max(0, record.latestSnapshot.activeElapsedSeconds ?? wall)
        }
    }
    private var totalDistance: Double? {
        let values = sessions.compactMap { record -> Double? in
            guard
                let sample = samplesByWorkout[record.id]?.last(where: {
                    $0.metric == "sessionDistanceMeters"
                })
            else { return nil }
            return sample.sample.value
        }
        return values.isEmpty ? nil : values.reduce(0, +) / 1_000
    }

    var body: some View {
        ScreenContent {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "CADA VUELTA\nDEJA ALGO.", bundle: .main)).font(
                    FitnessType.title(30)
                ).fixedSize(horizontal: false, vertical: true)
                Text(String(localized: "Tus sesiones guardadas en este dispositivo.", bundle: .main)).font(
                    FitnessType.body(.subheadline)
                ).foregroundStyle(FitnessPalette.secondary)
            }
            if sessions.isEmpty {
                EmptyHistory(action: selectPrograms)
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                    alignment: .leading, spacing: 16
                ) {
                    MetricValue(
                        value: sessions.count.formatted(), unit: "",
                        title: String(localized: "Sesiones", bundle: .main))
                    MetricValue(
                        value: durationLabel(seconds), unit: "",
                        title: String(localized: "Tiempo registrado", bundle: .main))
                    MetricValue(
                        value: totalDistance.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—",
                        unit: "km", title: String(localized: "Distancia registrada", bundle: .main))
                }.padding(.vertical, 14)
                Text(
                    String(
                        localized:
                            "La distancia conserva su fuente; las sesiones simuladas se identifican en el historial.",
                        bundle: .main)
                ).font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
                SectionTitle(title: String(localized: "Historial", bundle: .main))
                VStack(spacing: 0) {
                    ForEach(sessions) { record in
                        let samples = samplesByWorkout[record.id] ?? []
                        NavigationLink {
                            WorkoutSummaryView(coordinator: coordinator, record: record, close: {})
                        } label: {
                            WorkoutHistoryRow(record: record, samples: samples)
                        }.buttonStyle(.plain)
                        if record.id != sessions.last?.id { Divider().padding(.leading, 58) }
                    }
                }.padding(.horizontal, 14).background(
                    FitnessPalette.paper, in: RoundedRectangle(cornerRadius: 14))
                Label(
                    String(localized: "Historial local. Sin cuenta ni nube.", bundle: .main),
                    systemImage: "lock.shield"
                ).font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary).frame(
                    maxWidth: .infinity
                ).padding(.top, 4)
            }
        }
        .navigationTitle(String(localized: "Actividad", bundle: .main))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sessions.map(\.id).joined(separator: "|")) { loadEvidence() }
        .onChange(of: coordinator.history) { _, _ in loadEvidence() }
        .refreshable {
            coordinator.refresh()
            loadEvidence()
        }
    }

    private func durationLabel(_ value: TimeInterval) -> String {
        let min = Int(value / 60)
        return min >= 60
            ? String(localized: "\(min / 60) h \(min % 60) min", bundle: .main)
            : String(localized: "\(min) min", bundle: .main)
    }

    private func loadEvidence() {
        samplesByWorkout = Dictionary(
            uniqueKeysWithValues: sessions.map { record in
                (record.id, (try? coordinator.loadSamples(for: record.id)) ?? [])
            })
    }
}

private struct WorkoutHistoryRow: View {
    let record: WorkoutRecord
    let samples: [WorkoutRecordedSample]
    private var title: String {
        record.program?.localizedSeedName() ?? String(localized: "Entrenamiento libre", bundle: .main)
    }
    private var distance: String {
        samples.last(where: { $0.metric == "sessionDistanceMeters" }).map {
            ($0.sample.value / 1_000).formatted(.number.precision(.fractionLength(2)))
        } ?? "—"
    }
    private var detail: String {
        let state =
            record.interrupted
            ? String(localized: "Interrumpida", bundle: .main)
            : String(localized: "Guardada", bundle: .main)
        let source =
            samples.contains(where: { $0.sample.source == .mock })
            ? String(localized: "Simulación", bundle: .main) : String(localized: "Equipo", bundle: .main)
        let count = String(localized: "\(record.sampleCount) mediciones", bundle: .main)
        return String(
            localized:
                "\(record.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(state) · \(source) · \(count)",
            bundle: .main)
    }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.walk").font(FitnessType.body(.title3)).foregroundStyle(
                FitnessPalette.accent
            ).frame(width: 40, height: 40).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(FitnessType.body(.subheadline, weight: .semibold)).lineLimit(2)
                Text(detail).font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(distance).font(.subheadline.weight(.semibold).monospacedDigit())
                Text("km").font(FitnessType.body(.caption2)).foregroundStyle(FitnessPalette.secondary)
            }
            Image(systemName: "chevron.right").font(FitnessType.body(.caption, weight: .semibold))
                .foregroundStyle(FitnessPalette.secondary)
        }.padding(.vertical, 15).contentShape(Rectangle())
    }
}

struct WorkoutSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var coordinator: WorkoutCoordinator
    let record: WorkoutRecord
    let close: () -> Void
    @State private var samples: [WorkoutRecordedSample] = []
    @State private var events: [WorkoutRuntimeEvent] = []
    @State private var sharePayload: WorkoutSharePayload?
    @State private var showAddNote = false
    @State private var noteText = ""
    @State private var error: String?
    @State private var showZIPExportOptions = false

    private var liveHealthResult: HealthSaveResult? {
        coordinator.history.first(where: { $0.id == record.id })?.healthSave ?? record.healthSave
    }
    private var wallDuration: TimeInterval {
        max(0, (record.endedAt ?? record.startedAt).timeIntervalSince(record.startedAt))
    }
    private var duration: TimeInterval {
        max(0, record.latestSnapshot.activeElapsedSeconds ?? wallDuration)
    }
    private var pausedDuration: TimeInterval {
        max(0, record.latestSnapshot.pausedElapsedSeconds ?? 0)
    }
    private var speeds: [Double] {
        samples.filter { $0.metric.localizedCaseInsensitiveContains("speed") }.map(\.sample.value)
            .filter(\.isFinite)
    }
    private var inclines: [Double] {
        samples.filter { $0.metric.localizedCaseInsensitiveContains("inclination") }.map(\.sample.value)
            .filter(\.isFinite)
    }
    private var distances: [Double] {
        samples.filter { $0.metric.localizedCaseInsensitiveContains("distance") }.map(\.sample.value)
            .filter(\.isFinite)
    }
    private var heartRate: WorkoutRecordedSample? { samples.last { $0.metric == "heartRateBPM" } }
    private var heartSamples: [WorkoutRecordedSample] {
        let values = samples.filter {
            $0.metric == "heartRateBPM" && $0.sample.source == .watchHealthKit
        }
        let raw = values.filter { $0.sample.aggregation == "rawHealthKit" }
        return raw.isEmpty ? values : raw
    }
    private var averageHeart: Double? {
        liveHealthResult?.heartRateAverageBPM
            ?? (heartSamples.isEmpty
                ? nil : heartSamples.map(\.sample.value).reduce(0, +) / Double(heartSamples.count))
    }
    private var maximumHeart: Double? {
        liveHealthResult?.heartRateMaximumBPM ?? heartSamples.map(\.sample.value).max()
    }
    private var steps: WorkoutRecordedSample? { samples.last { $0.metric == "steps" } }
    private var energy: WorkoutRecordedSample? { samples.last { $0.metric == "energyKilocalories" } }
    private var latestSpeed: Double? { record.latestSnapshot.measuredSpeed?.value ?? speeds.last }
    private var latestIncline: Double? {
        record.latestSnapshot.measuredInclination?.value ?? inclines.last
    }
    private var distance: Double? { distances.last.map { $0 / 1_000 } }
    private var distanceSource: String {
        guard
            let sample = samples.last(where: { $0.metric.localizedCaseInsensitiveContains("distance") })
        else { return String(localized: "Sin lectura", bundle: .main) }
        return sample.sample.source.label
    }
    private var activeInterval: WorkoutInterval? {
        let intervals = record.latestSnapshot.program.intervals
        guard intervals.indices.contains(record.latestSnapshot.intervalIndex) else {
            return intervals.last
        }
        return intervals[record.latestSnapshot.intervalIndex]
    }
    private var visibleNotes: [WorkoutNote] {
        guard let current = coordinator.currentRecord, current.id == record.id else {
            return record.notes
        }
        return current.notes
    }
    private var canAddNote: Bool { coordinator.currentRecord?.id == record.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                summaryHeader
                interruptionNotice
                metricsPanel
                evidenceCaption
                HealthSavePanel(result: liveHealthResult, workoutID: record.id)
                speedChartSection
                provenancePanel
                notesPanel
                exportActions
            }.padding(.horizontal, 20).padding(.bottom, 28).frame(maxWidth: 720).frame(
                maxWidth: .infinity)
        }
        .fitnessSurface()
        .navigationTitle(String(localized: "Resumen", bundle: .main))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await prepareImage() }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }.accessibilityLabel(String(localized: "Compartir imagen de sesión", bundle: .main))
            }
        }
        .task { await loadEvidence() }
        .onChange(of: coordinator.history.first(where: { $0.id == record.id })?.sampleCount) { _, _ in
            Task { await loadEvidence() }
        }
        .sheet(item: $sharePayload) { payload in
            WorkoutSystemShareSheet(url: payload.url)
                .accessibilityIdentifier("workout-system-share-sheet")
        }
        .sheet(isPresented: $showAddNote) { addNoteEditor }
        .confirmationDialog(
            String(localized: "Perfil de exportación", bundle: .main), isPresented: $showZIPExportOptions,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Exportación completa", bundle: .main)) {
                Task { await prepareZIP(profile: .complete) }
            }
            .accessibilityIdentifier("export-workout-complete")
            Button(String(localized: "Soporte público", bundle: .main)) {
                Task { await prepareZIP(profile: .publicSupport) }
            }
            .accessibilityIdentifier("export-workout-public")
            Button(String(localized: "Cancelar", bundle: .main), role: .cancel) {}
        } message: {
            Text(
                String(
                    localized: "Soporte público omite notas, identidad, Salud y cargas útiles desconocidas.",
                    bundle: .main))
        }
        .alert(
            String(localized: "Exportación", bundle: .main),
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var summaryHeader: some View {
        VStack(alignment: .center, spacing: 8) {
            Image("FitnessMark").resizable().scaledToFit().frame(width: 58, height: 58)
                .accessibilityHidden(true).padding(.top, 22)
            Text(
                record.interrupted
                    ? String(localized: "Sesión interrumpida", bundle: .main)
                    : String(localized: "Sesión guardada", bundle: .main)
            ).font(FitnessType.title()).multilineTextAlignment(.center)
            Text(
                record.program?.localizedSeedName()
                    ?? String(localized: "Entrenamiento libre", bundle: .main)
            ).font(FitnessType.body(.subheadline)).foregroundStyle(FitnessPalette.secondary)
            Text(record.startedAt.formatted(date: .complete, time: .shortened)).font(
                FitnessType.body(.caption)
            ).foregroundStyle(FitnessPalette.secondary)
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder private var interruptionNotice: some View {
        if record.interrupted {
            Label(
                String(
                    localized:
                        "El registro se cerró sin confirmar que la banda se haya detenido. Usa la consola física del equipo.",
                    bundle: .main), systemImage: "exclamationmark.triangle.fill"
            )
            .font(FitnessType.body(.footnote, weight: .medium)).foregroundStyle(.orange).fixedSize(
                horizontal: false, vertical: true
            )
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var metricsPanel: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 22
        ) {
            MetricValue(
                value: durationText, unit: "", title: String(localized: "Duración", bundle: .main))
            MetricValue(
                value: distance.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—",
                unit: "km", title: String(localized: "Distancia registrada", bundle: .main))
            MetricValue(
                value: averageSpeed.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—",
                unit: "km/h", title: String(localized: "Velocidad media medida", bundle: .main))
            MetricValue(
                value: speeds.max().map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—",
                unit: "km/h", title: String(localized: "Velocidad máxima medida", bundle: .main))
            MetricValue(
                value: latestIncline.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—",
                unit: "%", title: String(localized: "Inclinación recibida", bundle: .main))
            MetricValue(
                value: display(heartRate, digits: 0), unit: "bpm",
                title: metricTitle(
                    String(localized: "Frecuencia cardiaca", bundle: .main), sample: heartRate))
            if !heartSamples.isEmpty {
                MetricValue(
                    value: averageHeart?.formatted(.number.precision(.fractionLength(0))) ?? "—",
                    unit: String(localized: "lpm", bundle: .main),
                    title: String(localized: "Pulso medio · Watch", bundle: .main))
                MetricValue(
                    value: maximumHeart?.formatted(.number.precision(.fractionLength(0))) ?? "—",
                    unit: String(localized: "lpm", bundle: .main),
                    title: String(localized: "Pulso máximo · Watch", bundle: .main))
            }
            MetricValue(
                value: display(steps, digits: 0), unit: "",
                title: metricTitle(String(localized: "Pasos", bundle: .main), sample: steps))
            MetricValue(
                value: display(energy, digits: 0), unit: "kcal",
                title: metricTitle(String(localized: "Energía", bundle: .main), sample: energy))
        }.padding(20).background(FitnessPalette.paper, in: RoundedRectangle(cornerRadius: 14))
    }

    private var evidenceCaption: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(
                String(
                    localized:
                        "Distancia registrada: \(distanceSource). Los datos simulados conservan su origen visible.",
                    bundle: .main))
            Text(
                String(
                    localized:
                        "Registro local: \(String(localized: "\(samples.count) mediciones", bundle: .main)) · \(String(localized: "\(events.count) eventos", bundle: .main)).",
                    bundle: .main))
            Text(String(localized: "Tiempo transcurrido: \(durationLabel(wallDuration)).", bundle: .main))
            if pausedDuration > 0 {
                Text(String(localized: "Tiempo en pausa: \(durationLabel(pausedDuration)).", bundle: .main))
            }
        }.font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
    }

    private var speedChartSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: String(localized: "Velocidad observada", bundle: .main))
            if speeds.isEmpty {
                ContentUnavailableView(
                    String(localized: "Sin mediciones de velocidad", bundle: .main),
                    systemImage: "waveform.path",
                    description: Text(
                        String(
                            localized: "El registro no contiene lecturas de velocidad para graficar.",
                            bundle: .main)))
            } else {
                speedChart
                HStack(spacing: 12) {
                    ForEach(speedChartSources, id: \.self) { source in
                        HStack(spacing: 5) {
                            Circle().fill(speedChartColor(for: source)).frame(width: 8, height: 8)
                            Text(source.localizedTitle())
                        }.accessibilityElement(children: .combine)
                            .accessibilityIdentifier("speed-source-legend-\(source.rawValue)")
                    }
                }.font(FitnessType.body(.caption2)).foregroundStyle(FitnessPalette.secondary)
                    .accessibilityElement(children: .contain)
            }
            Text(
                String(
                    localized:
                        "Cada punto conserva su origen. Los objetivos del programa no se presentan como mediciones.",
                    bundle: .main)
            ).font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
        }
    }

    private var speedChart: some View {
        Chart {
            ForEach(speedChartPoints) { point in
                LineMark(
                    x: .value(String(localized: "Hora", bundle: .main), point.date),
                    y: .value("km/h", point.speed),
                    series: .value(String(localized: "Tramo", bundle: .main), point.segmentID)
                )
                .foregroundStyle(by: .value(String(localized: "Origen", bundle: .main), point.source))
                PointMark(
                    x: .value(String(localized: "Hora", bundle: .main), point.date),
                    y: .value("km/h", point.speed)
                )
                .foregroundStyle(by: .value(String(localized: "Origen", bundle: .main), point.source))
                .symbolSize(18)
            }
        }
        .chartForegroundStyleScale(
            domain: MetricSource.allCases.map(\.rawValue),
            range: MetricSource.allCases.map(speedChartColor(for:))
        )
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartLegend(.hidden).frame(height: 190).accessibilityLabel(
            String(
                localized: "Gráfica de velocidad recibida en el tiempo, separada por fuente", bundle: .main)
        )
    }

    private var speedChartSources: [MetricSource] {
        MetricSource.allCases.filter { source in
            speedChartPoints.contains { $0.source == source.rawValue }
        }
    }

    private func speedChartColor(for source: MetricSource) -> Color {
        switch source {
        case .machineFTMS: FitnessPalette.accent
        case .watchHealthKit: .green
        case .mock: FitnessPalette.text
        case .derived: .orange
        case .unknown: FitnessPalette.secondary
        }
    }

    private var provenancePanel: some View {
        let snapshot = record.latestSnapshot
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: String(localized: "Plan, objetivo efectivo y lectura", bundle: .main))
            if let interval = activeInterval {
                provenanceRow(
                    String(localized: "Planificado", bundle: .main), speed: interval.targetSpeedKPH,
                    incline: interval.targetInclinationPercent,
                    speedSource: String(localized: "Programa", bundle: .main),
                    inclineSource: String(localized: "Programa", bundle: .main))
            }
            provenanceRow(
                String(localized: "Efectivo", bundle: .main), speed: snapshot.effectiveSpeedKPH,
                incline: snapshot.effectiveInclinationPercent,
                speedSource: String(localized: "Control", bundle: .main),
                inclineSource: String(localized: "Control", bundle: .main))
            provenanceRow(
                String(localized: "Medido", bundle: .main),
                speed: snapshot.measuredSpeed?.value ?? speeds.last,
                incline: snapshot.measuredInclination?.value ?? inclines.last,
                speedSource: snapshot.measuredSpeed?.source.label ?? latestSource(for: "speed"),
                inclineSource: snapshot.measuredInclination?.source.label
                    ?? latestSource(for: "inclination"))
        }.padding(18).background(FitnessPalette.paper, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var notesPanel: some View {
        if !visibleNotes.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: String(localized: "Notas", bundle: .main))
                ForEach(visibleNotes) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.text).font(FitnessType.body(.subheadline))
                        Text(note.createdAt.formatted(date: .abbreviated, time: .shortened)).font(
                            FitnessType.body(.caption)
                        ).foregroundStyle(FitnessPalette.secondary)
                    }
                    if note.id != visibleNotes.last?.id { Divider() }
                }
            }.padding(18).background(FitnessPalette.paper, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var exportActions: some View {
        VStack(spacing: 10) {
            Button {
                Task { await prepareImage() }
            } label: {
                Label(String(localized: "Compartir imagen", bundle: .main), systemImage: "photo").font(
                    FitnessType.body(.headline)
                ).frame(maxWidth: .infinity).frame(height: 52)
            }.buttonStyle(.glassProminent).tint(FitnessPalette.text).foregroundStyle(
                FitnessPalette.canvas
            ).accessibilityIdentifier("share-workout-image")
            Button {
                showZIPExportOptions = true
            } label: {
                Label(String(localized: "Exportar registro ZIP", bundle: .main), systemImage: "archivebox")
                    .frame(maxWidth: .infinity).frame(height: 48)
            }.buttonStyle(.bordered).accessibilityIdentifier("export-workout-zip")
            Button(action: { Task { await prepareJSON() } }) {
                Label(String(localized: "Compartir JSON", bundle: .main), systemImage: "curlybraces").frame(
                    maxWidth: .infinity
                ).frame(height: 48)
            }.buttonStyle(.bordered).accessibilityIdentifier("share-workout-json")
            if canAddNote {
                Button {
                    showAddNote = true
                } label: {
                    Label(String(localized: "Añadir nota", bundle: .main), systemImage: "note.text").frame(
                        maxWidth: .infinity
                    ).frame(height: 48)
                }.buttonStyle(.bordered)
            }
            Button(String(localized: "Volver a Actividad", bundle: .main)) {
                close()
                dismiss()
            }.font(FitnessType.body(.subheadline)).frame(minHeight: 44)
        }
    }

    private var addNoteEditor: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Nota de la sesión", bundle: .main)) {
                    TextField(
                        String(localized: "¿Qué quieres recordar?", bundle: .main), text: $noteText,
                        axis: .vertical
                    )
                    .lineLimit(3...8).accessibilityIdentifier("summary-workout-note-field")
                }
                Text(String(localized: "La nota se guardará en este registro.", bundle: .main)).font(
                    FitnessType.body(.footnote)
                ).foregroundStyle(FitnessPalette.secondary)
            }
            .fitnessSurface()
            .navigationTitle(String(localized: "Añadir nota", bundle: .main))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancelar", bundle: .main)) { showAddNote = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Guardar", bundle: .main)) {
                        do {
                            try coordinator.addNote(noteText)
                            noteText = ""
                            showAddNote = false
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var speedSamples: [WorkoutRecordedSample] {
        samples.filter { $0.metric.localizedCaseInsensitiveContains("speed") }
    }
    private var speedSegments: [SpeedSegment] {
        let ordered = speedSamples.sorted { $0.sample.receivedAt < $1.sample.receivedAt }
        var result: [SpeedSegment] = []
        var current: [WorkoutRecordedSample] = []
        for item in ordered {
            if let previous = current.last,
                item.sample.receivedAt.timeIntervalSince(previous.sample.receivedAt) > 5
                    || item.sample.source != previous.sample.source
            {
                result.append(SpeedSegment(samples: current))
                current = []
            }
            current.append(item)
        }
        if !current.isEmpty { result.append(SpeedSegment(samples: current)) }
        return result
    }
    private var speedChartPoints: [SpeedChartPoint] {
        speedSegments.flatMap { segment in
            segment.samples.map { sample in
                SpeedChartPoint(
                    id: sample.id, date: sample.sample.receivedAt, speed: sample.sample.value,
                    source: sample.sample.source.rawValue, segmentID: segment.id)
            }
        }
    }
    private var averageSpeed: Double? {
        let ordered = speedSamples.sorted { $0.sample.receivedAt < $1.sample.receivedAt }
        var weighted = 0.0
        var observedSeconds = 0.0
        for (left, right) in zip(ordered, ordered.dropFirst()) {
            let delta = right.sample.receivedAt.timeIntervalSince(left.sample.receivedAt)
            guard delta > 0, delta <= 5, left.sample.source == right.sample.source else { continue }
            weighted += (left.sample.value + right.sample.value) / 2 * delta
            observedSeconds += delta
        }
        return observedSeconds > 0 ? weighted / observedSeconds : nil
    }
    private var durationText: String {
        let total = Int(duration)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
    private func durationLabel(_ value: TimeInterval) -> String {
        let minutes = Int(value / 60)
        return minutes >= 60
            ? String(localized: "\(minutes / 60) h \(minutes % 60) min", bundle: .main)
            : String(localized: "\(minutes) min", bundle: .main)
    }

    private func provenanceRow(
        _ title: String, speed: Double?, incline: Double?, speedSource: String, inclineSource: String
    ) -> some View {
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(FitnessType.body(.subheadline, weight: .semibold))
            layout {
                Label(
                    speed.map {
                        $0.formatted(.number.precision(.fractionLength(1)))
                            + String(localized: " km/h", bundle: .main)
                    } ?? String(localized: "Sin lectura", bundle: .main), systemImage: "speedometer"
                ).fixedSize(horizontal: false, vertical: true)
                Label(
                    incline.map { $0.formatted(.number.precision(.fractionLength(0))) + "%" }
                        ?? String(localized: "Sin lectura", bundle: .main), systemImage: "mountain.2"
                ).fixedSize(horizontal: false, vertical: true)
            }.font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
            Text(
                String(
                    localized: "Velocidad: \(speedSource) · Inclinación: \(inclineSource)", bundle: .main)
            ).font(FitnessType.body(.caption2)).foregroundStyle(FitnessPalette.secondary).fixedSize(
                horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
    private func latestSource(for metric: String) -> String {
        samples.last(where: { $0.metric.localizedCaseInsensitiveContains(metric) })?.sample.source.label
            ?? String(localized: "Sin lectura", bundle: .main)
    }
    private func display(_ sample: WorkoutRecordedSample?, digits: Int) -> String {
        sample?.sample.value.formatted(.number.precision(.fractionLength(digits))) ?? "—"
    }
    private func metricTitle(_ title: String, sample: WorkoutRecordedSample?) -> String {
        guard let sample else { return title }
        return String(localized: "\(title) · \(sample.sample.source.label)", bundle: .main)
    }
    @MainActor private func loadEvidence() async {
        samples = (try? coordinator.loadSamples(for: record.id)) ?? []
        events = (try? coordinator.loadEvents(for: record.id)) ?? []
    }
    @MainActor private func prepareJSON() async {
        do {
            sharePayload = WorkoutSharePayload(
                url: try await coordinator.exportWorkoutJSONAsync(id: record.id))
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func prepareImage() async {
        do {
            await loadEvidence()
            let isExample =
                samples.contains { $0.sample.source == .mock }
                || events.contains { $0.kind == "workout.mock.started" }
            let url = try WorkoutShareCardRenderer.png(
                record: record, samples: samples, isExample: isExample)
            sharePayload = WorkoutSharePayload(url: url)
        } catch {
            self.error = String(
                localized: "No se pudo crear la imagen: \(error.localizedDescription)", bundle: .main)
        }
    }
    @MainActor private func prepareZIP(profile: DiagnosticExportProfile) async {
        do {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.6.0"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "9"
            let metadata = AppMetadata(
                version: version, build: build,
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                deviceModel: UIDevice.current.model)
            sharePayload = WorkoutSharePayload(
                url: try await coordinator.exportZIPAsync(
                    record: record, metadata: metadata, profile: profile
                ).archiveURL)
        } catch { self.error = error.localizedDescription }
    }
}

private struct WorkoutSharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

struct WorkoutSystemShareSheet: UIViewControllerRepresentable {
    let url: URL
    var identifier = "workout-system-share-sheet"
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.view.accessibilityIdentifier = identifier
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct SpeedSegment: Identifiable {
    let samples: [WorkoutRecordedSample]
    var id: String { samples.first?.id ?? "empty-segment" }
}

private struct SpeedChartPoint: Identifiable {
    let id: String
    let date: Date
    let speed: Double
    let source: String
    let segmentID: String
}
