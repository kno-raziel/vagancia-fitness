import FitnessCore
import FitnessRuntime
import SwiftUI
import UIKit

struct WorkoutFlowView: View {
    @Environment(PhoneWatchService.self) private var watch
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var speedFontSize = 64
    @Bindable var coordinator: WorkoutCoordinator
    let close: () -> Void
    let returnToActivity: () -> Void
    @State private var showFinishConfirmation = false
    @State private var confirmSaveInterrupted = false
    @State private var showManual = false
    @State private var actionError: String?
    @State private var showNote = false
    @State private var showDeviceSettings = false
    @State private var noteText = ""
    @State private var showExport = false
    @State private var showExportOptions = false
    @State private var exportFile: URL?
    @State private var summaryRecordID: String?

    private var snapshot: WorkoutSnapshot? { coordinator.snapshot }
    private var next: WorkoutInterval? {
        guard let snapshot else { return nil }
        let i = snapshot.intervalIndex + 1
        return snapshot.program.intervals.indices.contains(i) ? snapshot.program.intervals[i] : nil
    }
    private var active: Bool {
        snapshot?.state == .running || snapshot?.state == .manual || snapshot?.state == .paused
            || snapshot?.state == .pausing
    }
    private var usesAccessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }
    private var metricLayout: AnyLayout {
        usesAccessibilityLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(spacing: 0))
    }
    private var timePlanLayout: AnyLayout {
        usesAccessibilityLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 20))
    }

    var body: some View {
        ZStack {
            FitnessPalette.canvas.ignoresSafeArea()
            if let record = summaryRecord {
                NavigationStack {
                    WorkoutSummaryView(coordinator: coordinator, record: record, close: returnToActivity)
                }
                .toolbar(.visible, for: .navigationBar)
            } else if let snapshot, snapshot.state != .preparing {
                activeWorkout(snapshot)
            } else {
                preview
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: coordinator.currentRecord?.endedAt) { _, endedAt in
            if endedAt != nil { summaryRecordID = coordinator.currentRecord?.id }
        }
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog(
            confirmSaveInterrupted
                ? String(localized: "Guardar el registro interrumpido", bundle: .main)
                : String(localized: "Finalizar y guardar esta sesión?", bundle: .main),
            isPresented: $showFinishConfirmation,
            titleVisibility: .visible
        ) {
            if confirmSaveInterrupted {
                Button(
                    String(localized: "Guardar sin confirmar la parada", bundle: .main), role: .destructive
                ) { saveInterruptedRecording() }
                Button(String(localized: "Volver al entrenamiento", bundle: .main), role: .cancel) {
                    showFinishConfirmation = false
                }
            } else {
                Button(String(localized: "Finalizar y guardar", bundle: .main), role: .destructive) {
                    finishAndShowSummary()
                }
                .accessibilityIdentifier("confirm-finish-workout")
                Button(String(localized: "Seguir entrenando", bundle: .main), role: .cancel) {
                    showFinishConfirmation = false
                }
            }
        } message: {
            if confirmSaveInterrupted {
                Text(
                    String(
                        localized:
                            "Solo cierra el registro. No confirma que la banda se haya detenido; usa la consola física de la caminadora.",
                        bundle: .main))
            } else {
                Text(
                    String(
                        localized:
                            "El registro conservará las mediciones y el progreso observados hasta ahora.",
                        bundle: .main))
            }
        }
        .sheet(isPresented: $showManual) { manualControls }
        .sheet(isPresented: $showNote) { noteEditor }
        .sheet(isPresented: $showDeviceSettings) {
            NavigationStack {
                DeviceSettingsView(coordinator: coordinator)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(String(localized: "Listo", bundle: .main)) { showDeviceSettings = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showExport, onDismiss: { exportFile = nil }) {
            if let exportFile { WorkoutSystemShareSheet(url: exportFile) }
        }
        .confirmationDialog(
            String(localized: "Perfil de exportación", bundle: .main), isPresented: $showExportOptions,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Exportación completa", bundle: .main)) {
                prepareExport(profile: .complete)
            }.accessibilityIdentifier("export-current-complete")
            Button(String(localized: "Soporte público", bundle: .main)) {
                prepareExport(profile: .publicSupport)
            }.accessibilityIdentifier("export-current-public")
            Button(String(localized: "Cancelar", bundle: .main), role: .cancel) {}
        } message: {
            Text(
                String(
                    localized: "Soporte público omite notas, identidad, Salud y cargas útiles desconocidas.",
                    bundle: .main))
        }
        .alert(
            String(localized: "No se pudo completar el control", bundle: .main),
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button(String(localized: "Cerrar", bundle: .main)) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private var summaryRecord: WorkoutRecord? {
        guard
            let id = summaryRecordID
                ?? (coordinator.currentRecord?.endedAt != nil ? coordinator.currentRecord?.id : nil)
        else { return nil }
        return coordinator.currentRecord?.id == id
            ? coordinator.currentRecord : coordinator.history.first(where: { $0.id == id })
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(String(localized: "Cerrar", bundle: .main), systemImage: "xmark") {
                    coordinator.cancelWatchPreparation()
                    close()
                }.labelStyle(.iconOnly).font(FitnessType.body(.headline)).frame(width: 48, height: 48)
                    .accessibilityLabel(String(localized: "Cerrar vista previa", bundle: .main))
                Spacer()
                Text(String(localized: "VISTA PREVIA", bundle: .main)).font(
                    FitnessType.body(.caption, weight: .semibold)
                ).tracking(1.2).foregroundStyle(FitnessPalette.secondary)
                Spacer()
                Color.clear.frame(width: 48, height: 48)
            }.padding(.horizontal, 18).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            snapshot?.program.localizedSeedName()
                                ?? String(localized: "Entrenamiento libre", bundle: .main)
                        ).font(FitnessType.title()).foregroundStyle(FitnessPalette.text)
                        Text(preparationStatus)
                            .font(FitnessType.body(.subheadline)).foregroundStyle(FitnessPalette.secondary)
                    }.padding(.top, 28)

                    if let program = snapshot?.program {
                        VStack(alignment: .leading, spacing: 14) {
                            ProgramProfile(intervals: program.intervals, dark: true)
                            ForEach(Array(program.intervals.enumerated()), id: \.element.id) { index, interval in
                                HStack {
                                    Text(String(localized: "\(index + 1) · \(interval.phase.title)", bundle: .main))
                                        .font(FitnessType.body(.subheadline, weight: .medium))
                                    Spacer()
                                    Text(
                                        String(
                                            localized:
                                                "\(interval.durationLabel)  ·  \(interval.targetSpeedKPH.formatted(.number.precision(.fractionLength(1)))) km/h  ·  \(interval.targetInclinationPercent.formatted(.number.precision(.fractionLength(0))))%",
                                            bundle: .main)
                                    ).font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
                                }
                            }
                        }.padding(18).background(FitnessPalette.paper, in: RoundedRectangle(cornerRadius: 14))
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(String(localized: "Sesión libre", bundle: .main), systemImage: "figure.walk")
                                .font(FitnessType.body(.title3, weight: .semibold))
                            Text(
                                String(
                                    localized:
                                        "La sesión empieza en pausa de preparación. Usa los controles solo después de confirmar; cualquier acción de movimiento requiere tu toque explícito.",
                                    bundle: .main)
                            ).font(FitnessType.body(.subheadline)).foregroundStyle(FitnessPalette.secondary)
                        }.padding(20).background(FitnessPalette.paper, in: RoundedRectangle(cornerRadius: 14))
                    }

                    WatchPreparationPanel(coordinator: coordinator)
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            String(localized: "Qué registraremos", bundle: .main),
                            systemImage: "waveform.path.ecg"
                        ).font(FitnessType.body(.headline))
                        Text(
                            String(
                                localized:
                                    "Objetivo planificado, objetivo efectivo y lecturas de la máquina se mostrarán por separado. Pulso, pasos y energía de ejemplo llevan la etiqueta Simulada; puedes desactivarlos en Ajustes.",
                                bundle: .main)
                        ).font(FitnessType.body(.subheadline)).foregroundStyle(FitnessPalette.secondary)
                    }
                }.padding(.horizontal, 22).padding(.bottom, 28)
            }
            VStack(spacing: 12) {
                if canStartFromPreview {
                    Button {
                        Task {
                            do { try await coordinator.confirmAndStart() } catch {
                                actionError = error.localizedDescription
                            }
                        }
                    } label: {
                        Label(String(localized: "Confirmar e iniciar", bundle: .main), systemImage: "play.fill")
                            .font(FitnessType.body(.headline)).frame(maxWidth: .infinity).frame(height: 56)
                    }
                    .buttonStyle(.glassProminent).tint(FitnessPalette.text).foregroundStyle(
                        FitnessPalette.canvas
                    ).disabled(coordinator.isCommandPending)
                    .accessibilityIdentifier("confirm-workout-start")
                } else {
                    Button {
                        showDeviceSettings = true
                    } label: {
                        Label(
                            String(localized: "Conectar y preparar equipo", bundle: .main),
                            systemImage: "antenna.radiowaves.left.and.right"
                        ).font(FitnessType.body(.headline)).frame(maxWidth: .infinity).frame(height: 56)
                    }
                    .buttonStyle(.glassProminent).tint(FitnessPalette.text).foregroundStyle(
                        FitnessPalette.canvas
                    )
                    .accessibilityIdentifier("prepare-workout-transport")
                }
                Text(
                    String(
                        localized:
                            "No es un botón de paro de emergencia. Mantén acceso a la parada física de tu equipo.",
                        bundle: .main)
                ).font(FitnessType.body(.caption2)).foregroundStyle(FitnessPalette.secondary)
                    .multilineTextAlignment(.center)
            }.padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 12).background(
                .ultraThinMaterial)
        }
    }

    private var canStartFromPreview: Bool {
        coordinator.mockMode
            || (coordinator.bluetooth.phase == .ready && coordinator.bluetooth.selectedProtocol == .ftms)
    }

    private var preparationStatus: String {
        if coordinator.mockMode { return String(localized: "Demostración simulada", bundle: .main) }
        switch coordinator.bluetooth.phase {
        case .connecting: return String(localized: "Conectando con la caminadora…", bundle: .main)
        case .discovering: return String(localized: "Descubriendo servicios FTMS…", bundle: .main)
        case .ready where coordinator.bluetooth.selectedProtocol == .ftms:
            return String(localized: "FTMS listo · revisa el objetivo antes de iniciar", bundle: .main)
        case .ready:
            return String(
                localized: "Conectada · selecciona FTMS para preparar el control", bundle: .main)
        default:
            return String(localized: "Sin FTMS listo · conecta y prepara la caminadora", bundle: .main)
        }
    }

    private func activeWorkout(_ state: WorkoutSnapshot) -> some View {
        VStack(spacing: 0) {
            if usesAccessibilityLayout {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        noteButton(iconOnly: true)
                        Spacer()
                        exportButton
                    }
                    Text(stateTitle(state.state))
                        .font(FitnessType.body(.subheadline, weight: .bold))
                        .foregroundStyle(stateTint(state.state))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .accessibilityIdentifier("workout-state")
                }.padding(.horizontal, 18).padding(.top, 8)
            } else {
                HStack {
                    noteButton(iconOnly: false)
                    Spacer()
                    Text(stateTitle(state.state)).font(FitnessType.body(.caption, weight: .bold)).tracking(
                        1.1
                    ).foregroundStyle(stateTint(state.state)).lineLimit(1).minimumScaleFactor(0.8)
                        .accessibilityIdentifier("workout-state")
                    Spacer()
                    exportButton
                }.padding(.horizontal, 18).padding(.top, 8)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if watch.captureAwaitingConfirmation {
                        Label(
                            String(
                                localized:
                                    "Watch: captura sin confirmar. Se recuperará el enlace; el tiempo sin sensores quedará fuera de Salud.",
                                bundle: .main), systemImage: "applewatch.slash"
                        )
                        .font(FitnessType.body(.footnote)).foregroundStyle(.orange)
                        .accessibilityIdentifier("watch-capture-pending")
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(state.program.localizedSeedName()).font(
                            usesAccessibilityLayout
                                ? FitnessType.body(.headline, weight: .semibold)
                                : FitnessType.title(28, relativeTo: .title)
                        ).foregroundStyle(FitnessPalette.text)
                        Text(
                            String(
                                localized:
                                    "Etapa \(state.intervalIndex + 1) de \(state.program.intervals.count) · \(state.phase.title)",
                                bundle: .main)
                        ).font(FitnessType.body(usesAccessibilityLayout ? .caption : .subheadline))
                            .foregroundStyle(FitnessPalette.secondary)
                    }.padding(.top, 14)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "Velocidad recibida", bundle: .main)).font(
                            FitnessType.body(usesAccessibilityLayout ? .caption : .subheadline)
                        ).foregroundStyle(FitnessPalette.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(speedSample?.value.formatted(.number.precision(.fractionLength(1))) ?? "—")
                                .font(
                                    .system(size: speedFontSize, weight: .semibold, design: .rounded)
                                        .monospacedDigit()
                                )
                                .lineLimit(1).minimumScaleFactor(0.5)
                                .accessibilityIdentifier("workout-received-speed")
                            Text("km/h").font(FitnessType.body(.subheadline)).foregroundStyle(
                                FitnessPalette.secondary)
                        }
                        Text(sourceLabel(speedSample)).font(FitnessType.metadata).foregroundStyle(
                            FitnessPalette.secondary)
                    }
                    metricLayout {
                        liveMetric(
                            String(localized: "Inclinación", bundle: .main),
                            value: inclinationSample?.value.formatted(.number.precision(.fractionLength(0)))
                                ?? "—", unit: "%", source: sourceLabel(inclinationSample))
                        liveMetric(
                            String(localized: "Distancia", bundle: .main),
                            value: currentDistance.map { $0.formatted(.number.precision(.fractionLength(2))) }
                                ?? "—", unit: "km", source: sourceLabel(distanceSample))
                    }.padding(.vertical, 16).overlay(alignment: .top) {
                        Rectangle().fill(Color.white.opacity(0.16)).frame(height: 1)
                    }.overlay(alignment: .bottom) {
                        Rectangle().fill(Color.white.opacity(0.16)).frame(height: 1)
                    }

                    timePlanLayout {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(displayTime(state)).font(
                                .system(.largeTitle, design: .rounded).weight(.bold).monospacedDigit()
                            ).tracking(-1.5).foregroundStyle(FitnessPalette.text).contentTransition(
                                reduceMotion ? .identity : .numericText())
                            Text(
                                isFreeWorkout(state)
                                    ? String(localized: "transcurridos", bundle: .main)
                                    : String(localized: "restantes en esta etapa", bundle: .main)
                            ).font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
                        }
                        if !usesAccessibilityLayout { Spacer(minLength: 8) }
                        VStack(alignment: usesAccessibilityLayout ? .leading : .trailing, spacing: 8) {
                            Text(String(localized: "PLANIFICADA", bundle: .main)).font(
                                FitnessType.body(.caption2, weight: .semibold)
                            ).tracking(0.8).foregroundStyle(FitnessPalette.secondary)
                            Text(
                                String(
                                    localized:
                                        "\(state.program.intervals[state.intervalIndex].targetSpeedKPH.formatted(.number.precision(.fractionLength(1)))) km/h",
                                    bundle: .main)
                            ).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(
                                FitnessPalette.text)
                            Text(
                                String(
                                    localized:
                                        "\(state.program.intervals[state.intervalIndex].targetInclinationPercent.formatted(.number.precision(.fractionLength(0))))% inclinación",
                                    bundle: .main)
                            ).font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
                        }
                    }.padding(.vertical, 14)

                    metricProvenance(state)

                    metricLayout {
                        liveMetric(
                            String(localized: "Frecuencia cardiaca", bundle: .main),
                            value: metricValue("heartRateBPM", fractionDigits: 0), unit: "bpm",
                            source: metricSource("heartRateBPM"))
                        liveMetric(
                            String(localized: "Pasos", bundle: .main),
                            value: metricValue("steps", fractionDigits: 0), unit: "",
                            source: metricSource("steps"))
                        liveMetric(
                            String(localized: "Energía", bundle: .main),
                            value: metricValue("energyKilocalories", fractionDigits: 0), unit: "kcal",
                            source: metricSource("energyKilocalories"))
                    }

                    if let next {
                        HStack(spacing: 14) {
                            Image(systemName: "arrow.right.circle").font(FitnessType.body(.title2))
                                .foregroundStyle(FitnessPalette.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(String(localized: "SIGUIENTE", bundle: .main)).font(
                                    FitnessType.body(.caption2, weight: .semibold)
                                ).tracking(0.9).foregroundStyle(FitnessPalette.secondary)
                                Text(
                                    String(localized: "\(next.phase.title) · \(next.durationLabel)", bundle: .main)
                                ).font(FitnessType.body(.subheadline, weight: .semibold)).foregroundStyle(
                                    FitnessPalette.text)
                            }
                            Spacer()
                            Text(
                                String(
                                    localized:
                                        "\(next.targetSpeedKPH.formatted(.number.precision(.fractionLength(1)))) km/h",
                                    bundle: .main)
                            ).font(.subheadline.monospacedDigit()).foregroundStyle(FitnessPalette.secondary)
                        }.padding(15).background(FitnessPalette.paper, in: RoundedRectangle(cornerRadius: 16))
                    }

                    Button {
                        Task {
                            do { try await coordinator.skipSegment() } catch {
                                actionError = error.localizedDescription
                            }
                        }
                    } label: {
                        Label(
                            String(localized: "Saltar a la siguiente etapa", bundle: .main),
                            systemImage: "forward.end.fill"
                        ).font(FitnessType.body(.subheadline, weight: .semibold)).frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }.buttonStyle(.bordered).tint(.white.opacity(0.82)).disabled(
                        !active || state.state == .manual || coordinator.isCommandPending
                    )
                    .accessibilityIdentifier("skip-workout-segment")
                    if let deviation = state.deviation {
                        Label(
                            deviation.basis == .measuredVersusAccepted
                                ? String(
                                    localized:
                                        "La lectura de \(deviation.metric == .speed ? String(localized: "velocidad", bundle: .main) : String(localized: "inclinación", bundle: .main)) difiere del objetivo aceptado: \(deviation.observed.formatted()) frente a \(deviation.expected.formatted()).",
                                    bundle: .main)
                                : String(localized: "El objetivo aceptado difiere del plan.", bundle: .main),
                            systemImage: "exclamationmark.triangle"
                        ).font(FitnessType.body(.footnote)).foregroundStyle(.yellow)
                    }
                    if state.state == .manual, let reason = coordinator.errorMessage {
                        Label(FitnessText.controlMessage(reason), systemImage: "exclamationmark.triangle.fill")
                            .font(FitnessType.body(.footnote)).foregroundStyle(.orange)
                            .accessibilityIdentifier("workout-automation-suspended-reason")
                    }
                }.padding(.horizontal, 22).padding(.bottom, 26)
            }
            controlDock(state)
        }
    }

    private func metricProvenance(_ snapshot: WorkoutSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                coordinator.mockMode
                    ? String(localized: "OBJETIVO DE DEMOSTRACIÓN", bundle: .main)
                    : String(localized: "OBJETIVO ACEPTADO POR FTMS", bundle: .main)
            ).font(FitnessType.body(.caption2, weight: .semibold)).tracking(1).foregroundStyle(
                FitnessPalette.secondary)
            metricLayout {
                liveMetric(
                    String(localized: "Velocidad", bundle: .main),
                    value: snapshot.effectiveSpeedKPH?.formatted(.number.precision(.fractionLength(1)))
                        ?? "—", unit: "km/h",
                    source: coordinator.mockMode
                        ? String(localized: "Simulada", bundle: .main)
                        : String(localized: "FTMS aceptó; verifica velocidad medida", bundle: .main))
                liveMetric(
                    String(localized: "Inclinación", bundle: .main),
                    value: snapshot.effectiveInclinationPercent?.formatted(
                        .number.precision(.fractionLength(0))) ?? "—", unit: "%",
                    source: snapshot.effectiveInclinationPercent == nil
                        ? String(localized: "No disponible", bundle: .main)
                        : (coordinator.mockMode
                            ? String(localized: "Simulada", bundle: .main)
                            : String(localized: "Aceptada u observada", bundle: .main)))
            }
        }.padding(16).background(FitnessPalette.paper, in: RoundedRectangle(cornerRadius: 17))
    }

    private func noteButton(iconOnly: Bool) -> some View {
        Button {
            showNote = true
        } label: {
            if iconOnly {
                Image(systemName: "note.text").font(FitnessType.body(.headline)).frame(
                    width: 48, height: 48)
            } else {
                Label(String(localized: "Nota", bundle: .main), systemImage: "note.text").font(
                    FitnessType.body(.subheadline, weight: .medium)
                ).frame(minHeight: 48)
            }
        }
        .accessibilityLabel(String(localized: "Añadir nota a la sesión", bundle: .main))
        .accessibilityIdentifier("add-workout-note")
    }

    private var exportButton: some View {
        Button {
            showExportOptions = true
        } label: {
            Image(systemName: "square.and.arrow.up").frame(width: 48, height: 48)
        }.accessibilityLabel(String(localized: "Exportar sesión", bundle: .main))
            .accessibilityIdentifier("export-current-session")
    }

    private func liveMetric(_ title: String, value: String, unit: String, source: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(FitnessType.body(.caption2)).foregroundStyle(FitnessPalette.secondary)
                .lineLimit(usesAccessibilityLayout ? nil : 2).frame(
                    minHeight: usesAccessibilityLayout ? 0 : 30, alignment: .bottomLeading)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(
                    FitnessPalette.text)
                Text(unit).font(FitnessType.body(.caption2)).foregroundStyle(FitnessPalette.secondary)
            }
            Text(source).font(FitnessType.body(.caption2)).foregroundStyle(FitnessPalette.secondary)
                .lineLimit(usesAccessibilityLayout ? nil : 2).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func controlDock(_ snapshot: WorkoutSnapshot) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if snapshot.state == .manual {
                    if usesAccessibilityLayout {
                        Image(systemName: "pause.circle").font(FitnessType.body(.headline)).frame(
                            width: 54, height: 54
                        ).foregroundStyle(.orange).accessibilityLabel(
                            String(localized: "Control suspendido", bundle: .main))
                    } else {
                        Label(
                            String(localized: "Control suspendido", bundle: .main), systemImage: "pause.circle"
                        ).font(FitnessType.body(.headline)).frame(maxWidth: .infinity).frame(height: 54)
                            .foregroundStyle(.orange)
                    }
                } else {
                    if usesAccessibilityLayout {
                        Button {
                            togglePause(snapshot)
                        } label: {
                            Image(systemName: snapshot.state == .paused ? "play.fill" : "pause.fill").font(
                                FitnessType.body(.headline)
                            ).frame(width: 54, height: 54)
                        }.buttonStyle(.glassProminent).tint(FitnessPalette.text).foregroundStyle(
                            FitnessPalette.canvas
                        ).disabled(coordinator.isCommandPending || !active)
                            .accessibilityLabel(
                                snapshot.state == .paused
                                    ? String(localized: "Reanudar entrenamiento", bundle: .main)
                                    : String(localized: "Pausar entrenamiento", bundle: .main)
                            )
                            .accessibilityIdentifier("pause-resume-workout")
                    } else {
                        Button {
                            togglePause(snapshot)
                        } label: {
                            Label(
                                snapshot.state == .paused
                                    ? String(localized: "Reanudar", bundle: .main)
                                    : String(localized: "Pausar", bundle: .main),
                                systemImage: snapshot.state == .paused ? "play.fill" : "pause.fill"
                            ).font(FitnessType.body(.headline)).frame(maxWidth: .infinity).frame(height: 54)
                        }.buttonStyle(.glassProminent).tint(FitnessPalette.text).foregroundStyle(
                            FitnessPalette.canvas
                        ).disabled(coordinator.isCommandPending || !active).accessibilityIdentifier(
                            "pause-resume-workout")
                    }
                }
                Button {
                    showManual = true
                } label: {
                    Image(systemName: "slider.horizontal.3").font(FitnessType.body(.headline)).frame(
                        width: 54, height: 54)
                }.buttonStyle(.bordered).tint(.white).disabled(!active || coordinator.isCommandPending)
                    .accessibilityLabel(String(localized: "Ajustar velocidad e inclinación", bundle: .main))

            }
            Button {
                stopAndClose()
            } label: {
                Label(String(localized: "Parar banda", bundle: .main), systemImage: "stop.fill").font(
                    FitnessType.body(.headline, weight: .semibold)
                ).frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(.glassProminent).tint(FitnessPalette.red).foregroundStyle(FitnessPalette.canvas)
                .accessibilityLabel(String(localized: "Parar banda y guardar progreso", bundle: .main))
                .accessibilityIdentifier("stop-workout")
            Button {
                confirmSaveInterrupted = false
                showFinishConfirmation = true
            } label: {
                Text(String(localized: "Finalizar y guardar…", bundle: .main))
                    .font(FitnessType.body(.subheadline, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }.disabled(coordinator.isCommandPending || snapshot.state == .manual).accessibilityIdentifier(
                "finish-workout")
            if snapshot.state == .manual {
                Button(role: .destructive) {
                    confirmSaveInterrupted = true
                    showFinishConfirmation = true
                } label: {
                    Text(String(localized: "Guardar registro sin confirmar parada…", bundle: .main))
                        .font(FitnessType.body(.subheadline, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }.disabled(coordinator.isCommandPending)
                    .accessibilityIdentifier("save-interrupted-workout")
            }
        }.padding(.horizontal, 20).padding(.top, 13).padding(.bottom, 10).background(.ultraThinMaterial)
    }

    private func togglePause(_ snapshot: WorkoutSnapshot) {
        Task {
            do {
                if snapshot.state == .paused {
                    try await coordinator.resume()
                } else {
                    try await coordinator.pause()
                }
            } catch { actionError = error.localizedDescription }
        }
    }

    private var manualControls: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Velocidad", bundle: .main)) {
                    Stepper(
                        value: Binding(
                            get: { snapshot?.effectiveSpeedKPH ?? coordinator.targetLimits.speed.minimum },
                            set: { value in
                                Task {
                                    do { try await coordinator.overrideSpeed(value) } catch {
                                        actionError = error.localizedDescription
                                    }
                                }
                            }),
                        in: coordinator.targetLimits.speed.minimum...coordinator.targetLimits.speed.maximum,
                        step: coordinator.targetLimits.speed.increment
                    ) {
                        LabeledContent(
                            String(localized: "Objetivo efectivo", bundle: .main),
                            value: String(
                                localized:
                                    "\((snapshot?.effectiveSpeedKPH ?? coordinator.targetLimits.speed.minimum).formatted(.number.precision(.fractionLength(1)))) km/h",
                                bundle: .main))
                    }.disabled(coordinator.isCommandPending)
                }
                Section(String(localized: "Inclinación", bundle: .main)) {
                    Stepper(
                        value: Binding(
                            get: {
                                snapshot?.effectiveInclinationPercent
                                    ?? coordinator.targetLimits.inclination.minimum
                            },
                            set: { value in
                                Task {
                                    do { try await coordinator.overrideIncline(value) } catch {
                                        actionError = error.localizedDescription
                                    }
                                }
                            }),
                        in: coordinator.targetLimits.inclination
                            .minimum...coordinator.targetLimits.inclination.maximum,
                        step: coordinator.targetLimits.inclination.increment
                    ) {
                        LabeledContent(
                            String(localized: "Objetivo efectivo", bundle: .main),
                            value: String(
                                localized:
                                    "\((snapshot?.effectiveInclinationPercent ?? coordinator.targetLimits.inclination.minimum).formatted(.number.precision(.fractionLength(0))))%",
                                bundle: .main))
                    }.disabled(coordinator.isCommandPending || snapshot?.effectiveInclinationPercent == nil)
                }
                Text(
                    String(
                        localized:
                            "Cada toque envía un único cambio explícito. Los controles se desactivan mientras el equipo responde.",
                        bundle: .main)
                ).font(FitnessType.body(.footnote)).foregroundStyle(FitnessPalette.secondary)
            }.fitnessSurface().navigationTitle(String(localized: "Ajuste manual", bundle: .main))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Listo", bundle: .main)) { showManual = false }
                    }
                }
        }
        .safeAreaInset(edge: .bottom) {
            if coordinator.hasOpenWorkout {
                stopFromCoveredSheet(showManual: true).padding(.horizontal, 20).padding(.vertical, 12)
                    .background(FitnessPalette.canvas)
            }
        }
        .presentationDetents(usesAccessibilityLayout ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var noteEditor: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Nota de la sesión", bundle: .main)) {
                    TextField(
                        String(localized: "¿Qué quieres recordar?", bundle: .main), text: $noteText,
                        axis: .vertical
                    )
                    .lineLimit(3...8).accessibilityIdentifier("workout-note-field")
                }
                Text(String(localized: "La nota se guarda con el registro de esta sesión.", bundle: .main))
                    .font(FitnessType.body(.footnote)).foregroundStyle(FitnessPalette.secondary)
            }
            .fitnessSurface()
            .fitnessSurface()
            .navigationTitle(String(localized: "Añadir nota", bundle: .main))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancelar", bundle: .main)) { showNote = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Guardar", bundle: .main)) {
                        do {
                            try coordinator.addNote(noteText)
                            noteText = ""
                            showNote = false
                        } catch { actionError = error.localizedDescription }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if coordinator.hasOpenWorkout {
                stopFromCoveredSheet(showNote: true).padding(.horizontal, 20).padding(.vertical, 12)
                    .background(FitnessPalette.canvas)
            }
        }
        .presentationDetents(usesAccessibilityLayout ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func isFreeWorkout(_ snapshot: WorkoutSnapshot) -> Bool {
        snapshot.program.id.hasPrefix("free-")
    }
    private func stateTitle(_ state: WorkoutState) -> String {
        switch state {
        case .preparing: String(localized: "PREPARANDO", bundle: .main)
        case .starting: String(localized: "INICIANDO", bundle: .main)
        case .running: String(localized: "EN CURSO", bundle: .main)
        case .pausing: String(localized: "PARANDO PARA PAUSAR", bundle: .main)
        case .paused: String(localized: "EN PAUSA", bundle: .main)
        case .manual: String(localized: "CONTROL SUSPENDIDO", bundle: .main)
        case .finishing: String(localized: "FINALIZANDO", bundle: .main)
        case .completed: String(localized: "GUARDADO", bundle: .main)
        case .interrupted: String(localized: "INTERRUMPIDO", bundle: .main)
        }
    }
    private func stateTint(_ state: WorkoutState) -> Color {
        switch state {
        case .paused, .manual, .interrupted: .orange
        default: FitnessPalette.accent
        }
    }
    private func displayTime(_ snapshot: WorkoutSnapshot) -> String {
        let seconds =
            isFreeWorkout(snapshot)
            ? Int(snapshot.activeElapsedSeconds ?? snapshot.phaseElapsedSeconds)
            : max(0, snapshot.currentInterval.durationSeconds - Int(snapshot.phaseElapsedSeconds))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    private var speedSample: WorkoutSample? { coordinator.latestMetrics["speedKPH"] }
    private var inclinationSample: WorkoutSample? { coordinator.latestMetrics["inclinationPercent"] }
    private var distanceSample: WorkoutSample? { coordinator.latestMetrics["sessionDistanceMeters"] }
    private var currentDistance: Double? { distanceSample.map { $0.value / 1_000 } }
    private func metricValue(_ metric: String, fractionDigits: Int) -> String {
        coordinator.latestMetrics[metric]?.value.formatted(
            .number.precision(.fractionLength(fractionDigits))) ?? "—"
    }
    private func metricSource(_ metric: String) -> String {
        sourceLabel(coordinator.latestMetrics[metric])
    }
    private func sourceLabel(_ sample: WorkoutSample?) -> String {
        guard let sample else { return String(localized: "Sin lectura", bundle: .main) }
        let age = max(0, Int(Date.now.timeIntervalSince(sample.sampledAt ?? sample.receivedAt)))
        return age > 5
            ? String(localized: "\(sample.source.label) · hace \(age) s", bundle: .main)
            : sample.source.label
    }
    private func finishAndShowSummary() {
        Task {
            do { try await coordinator.finishAndSave() } catch {
                actionError = error.localizedDescription
            }
        }
    }
    private func saveInterruptedRecording() {
        Task {
            do { try await coordinator.saveInterruptedRecording() } catch {
                actionError = error.localizedDescription
            }
        }
    }
    private func stopAndClose() {
        Task {
            do {
                try await coordinator.stop()
                summaryRecordID = coordinator.currentRecord?.id
            } catch { actionError = error.localizedDescription }
        }
    }
    private func prepareExport(profile: DiagnosticExportProfile) {
        Task {
            do {
                let version =
                    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.6.0"
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "9"
                let metadata = AppMetadata(
                    version: version, build: build,
                    osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    deviceModel: UIDevice.current.model)
                exportFile = try await coordinator.exportCurrentAsync(metadata: metadata, profile: profile)
                    .archiveURL
                showExport = true
            } catch {
                actionError = String(
                    localized: "No se pudo preparar la exportación: \(error.localizedDescription)",
                    bundle: .main)
            }
        }
    }
    private func stopFromCoveredSheet(showManual: Bool = false, showNote: Bool = false) -> some View {
        Button(role: .destructive) {
            if showManual { self.showManual = false }
            if showNote { self.showNote = false }
            stopAndClose()
        } label: {
            Label(String(localized: "Parar banda", bundle: .main), systemImage: "stop.fill")
                .font(FitnessType.body(.headline))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.glassProminent)
        .tint(FitnessPalette.red).foregroundStyle(FitnessPalette.canvas)
        .accessibilityIdentifier("stop-workout-sheet")
    }
}

extension MetricSource {
    var label: String { localizedTitle() }
}
