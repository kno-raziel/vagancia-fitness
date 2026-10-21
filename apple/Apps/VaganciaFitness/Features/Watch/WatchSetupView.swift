import FitnessCore
import FitnessRuntime
import SwiftUI

/// A visible clock and session identity are inputs, so old readiness cannot
/// become a confirmation merely because a different attempt is now active.
@MainActor struct WatchStatusProjection {
    let watch: PhoneWatchService
    let now: Date

    var accessReviewed: Bool {
        watch.accessFacts.reviewed == true && watch.accessFacts.isFresh(at: now)
    }
    var canSaveWorkout: Bool {
        watch.accessFacts.canSaveWorkout == true && watch.accessFacts.isFresh(at: now)
    }
    var accessFreshness: String {
        guard watch.accessFacts.updatedAt != .distantPast else {
            return String(localized: "sin informe recibido", bundle: .main)
        }
        let time = watch.accessFacts.updatedAt.formatted(date: .omitted, time: .shortened)
        return watch.accessFacts.isFresh(at: now)
            ? String(localized: "informado a las \(time)", bundle: .main)
            : String(localized: "último informe a las \(time), desactualizado", bundle: .main)
    }
    var accessReviewedTitle: String {
        if !watch.accessFacts.isFresh(at: now), watch.accessFacts.reviewed != nil {
            return String(localized: "Revisión de acceso por actualizar", bundle: .main)
        }
        return switch watch.accessFacts.reviewed {
        case true: String(localized: "Acceso a Salud revisado", bundle: .main)
        case false: String(localized: "Acceso a Salud pendiente", bundle: .main)
        case nil: String(localized: "Revisión de acceso desconocida", bundle: .main)
        }
    }
    var canSaveTitle: String {
        if !watch.accessFacts.isFresh(at: now), watch.accessFacts.canSaveWorkout != nil {
            return String(localized: "Guardado en Salud por actualizar", bundle: .main)
        }
        return switch watch.accessFacts.canSaveWorkout {
        case true: String(localized: "Watch puede guardar entrenamientos", bundle: .main)
        case false: String(localized: "Watch no puede guardar entrenamientos", bundle: .main)
        case nil: String(localized: "Guardado en Salud sin confirmar", bundle: .main)
        }
    }
    var readinessFresh: Bool {
        let age = now.timeIntervalSince(watch.readiness.updatedAt)
        return age >= 0 && age < 30
    }
    var readinessMatchesPreparation: Bool {
        guard let id = watch.preparedSessionID else { return false }
        return watch.readinessSessionID == id
    }
    var captureConfirmed: Bool {
        guard let id = watch.preparedSessionID else { return false }
        return readinessFresh && readinessMatchesPreparation && watch.confirmedCaptureSessionID == id
    }
    var captureTitle: String {
        if captureConfirmed { return String(localized: "Captura confirmada", bundle: .main) }
        if watch.captureAwaitingConfirmation && readinessMatchesPreparation {
            return String(localized: "Esperando confirmación", bundle: .main)
        }
        return String(localized: "Sin confirmación reciente", bundle: .main)
    }
    var readinessDetail: String {
        guard watch.readiness.updatedAt != .distantPast else {
            return String(localized: "Aún no se recibió un estado de sesión del Watch.", bundle: .main)
        }
        let time = watch.readiness.updatedAt.formatted(date: .omitted, time: .shortened)
        if !readinessFresh {
            return String(
                localized: "Último estado a las \(time), desactualizado; consulta el reloj.", bundle: .main)
        }
        guard watch.preparedSessionID != nil else {
            return String(
                localized: "Estado a las \(time); no hay una sesión preparada a la cual asociarlo.",
                bundle: .main)
        }
        if !readinessMatchesPreparation {
            return String(
                localized: "Estado a las \(time) de otra sesión; no confirma esta captura.", bundle: .main)
        }
        return String(localized: "Estado de esta sesión recibido a las \(time).", bundle: .main)
    }
    var orphanStateTitle: String {
        switch watch.orphanedPreparation?.state {
        case .prepared: String(localized: "Preparada", bundle: .main)
        case .preparing: String(localized: "En preparación", bundle: .main)
        case .conflict: String(localized: "En conflicto", bundle: .main)
        case .running: String(localized: "Con captura activa", bundle: .main)
        case .paused: String(localized: "Captura en pausa", bundle: .main)
        case .recovering: String(localized: "En recuperación", bundle: .main)
        case .ending: String(localized: "Finalizando", bundle: .main)
        case .ended: String(localized: "Finalizada", bundle: .main)
        case .accessNeeded: String(localized: "Requiere acceso", bundle: .main)
        case .failed: String(localized: "Falló", bundle: .main)
        case .idle: String(localized: "Inactiva", bundle: .main)
        case nil: String(localized: "Sin estado", bundle: .main)
        }
    }
}

struct WatchSetupView: View {
    @Environment(PhoneWatchService.self) private var watch
    @State private var showPairingHelp = false
    @State private var requesting = false
    @State private var resolving = false
    @State private var resolutionError: String?
    @State private var statusClock = Date()
    private var status: WatchStatusProjection {
        WatchStatusProjection(watch: watch, now: statusClock)
    }
    var body: some View {
        @Bindable var watch = watch
        ScreenContent {
            FitnessBrandHeader().frame(maxWidth: .infinity).padding(.top, 12)
            Text(String(localized: "Tu Watch,\ntu pulso.", bundle: .main)).font(
                FitnessType.title(34, relativeTo: .largeTitle))
            Text(
                String(
                    localized: "Consulta tu sesión en la muñeca y añade pulso y energía del Watch.",
                    bundle: .main)
            ).foregroundStyle(FitnessPalette.secondary)
            VStack(alignment: .leading, spacing: 18) {
                setupRow(
                    watch.isPaired
                        ? String(localized: "Emparejado con iOS", bundle: .main)
                        : String(localized: "Sin emparejar con iOS", bundle: .main), systemImage: "applewatch",
                    done: watch.isPaired,
                    detail: watch.isPaired
                        ? String(localized: "Apple Watch vinculado a este iPhone", bundle: .main)
                        : String(localized: "Empareja el reloj desde la app Watch de Apple.", bundle: .main))
                setupRow(
                    watch.isInstalled
                        ? String(localized: "VAGANCIA FITNESS instalada", bundle: .main)
                        : String(localized: "App pendiente de instalar", bundle: .main),
                    systemImage: "arrow.down.app", done: watch.isInstalled,
                    detail: watch.isInstalled
                        ? String(localized: "App complementaria instalada", bundle: .main)
                        : String(
                            localized: "Abre Watch → apps disponibles e instala VAGANCIA FITNESS.", bundle: .main)
                )
                setupRow(
                    status.accessReviewedTitle, systemImage: "heart.text.clipboard",
                    done: status.accessReviewed,
                    detail: String(
                        localized:
                            "Revisión de acceso en Watch · \(status.accessFreshness). Una lectura ausente no indica permiso denegado.",
                        bundle: .main)
                )
                .accessibilityIdentifier("watch-access-reviewed")
                setupRow(
                    status.canSaveTitle, systemImage: "heart.circle", done: status.canSaveWorkout,
                    detail: String(
                        localized:
                            "Capacidad de guardar entrenamientos informada por Watch · \(status.accessFreshness).",
                        bundle: .main)
                )
                .accessibilityIdentifier("watch-can-save-workout")
                setupRow(
                    watch.isReachable
                        ? String(localized: "Mensajes inmediatos disponibles", bundle: .main)
                        : String(localized: "Mensajes inmediatos pendientes", bundle: .main),
                    systemImage: "antenna.radiowaves.left.and.right", done: watch.isReachable,
                    detail: String(
                        localized: "Watch Connectivity puede entregar mensajes pendientes en segundo plano.",
                        bundle: .main))
                setupRow(
                    watch.mirrored
                        ? String(localized: "Sesión HealthKit reflejada", bundle: .main)
                        : String(localized: "Sin sesión HealthKit reflejada", bundle: .main),
                    systemImage: "heart.text.square", done: watch.mirrored,
                    detail: String(
                        localized:
                            "El enlace reflejado tiene un estado independiente de los mensajes inmediatos.",
                        bundle: .main))
                setupRow(
                    status.captureTitle, systemImage: "waveform.path.ecg", done: status.captureConfirmed,
                    detail: status.readinessDetail)
            }.padding(18).background(FitnessPalette.paper, in: RoundedRectangle(cornerRadius: 14))
            if let orphan = watch.orphanedPreparation {
                VStack(alignment: .leading, spacing: 10) {
                    #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("--ui-test-watch-conflict") {
                            Text(String(localized: "Escenario sintético de prueba", bundle: .main))
                                .font(FitnessType.metadata).foregroundStyle(FitnessPalette.secondary)
                        }
                    #endif
                    Label(
                        String(localized: "Preparación anterior en Watch", bundle: .main),
                        systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                    )
                    .font(FitnessType.body(.headline))
                    Text(
                        String(
                            localized: "Sesión \(String(orphan.id.prefix(8)))… · \(status.orphanStateTitle)",
                            bundle: .main)
                    )
                    .font(FitnessType.metadata).textSelection(.enabled)
                    if watch.readiness.blockingSessionID == orphan.id {
                        Text(
                            String(
                                localized:
                                    "Conflicto informado a las \(watch.readiness.updatedAt.formatted(date: .abbreviated, time: .shortened)).",
                                bundle: .main)
                        )
                        .font(FitnessType.body(.footnote)).foregroundStyle(FitnessPalette.secondary)
                    }
                    Text(FitnessText.watchPreparationMessage(orphan.message)).font(
                        FitnessType.body(.footnote)
                    ).foregroundStyle(FitnessPalette.secondary)
                    Text(
                        String(
                            localized:
                                "El Watch solo descartará esa preparación si no tiene una captura activa. Esta acción no inicia ni detiene la banda.",
                            bundle: .main)
                    )
                    .font(FitnessType.body(.footnote)).foregroundStyle(FitnessPalette.secondary)
                    Button(
                        resolving
                            ? String(localized: "Solicitando descarte…", bundle: .main)
                            : String(localized: "Descartar preparación anterior", bundle: .main)
                    ) {
                        resolving = true
                        resolutionError = nil
                        Task {
                            do { try await watch.resolveOrphanedPreparation() } catch {
                                resolutionError = error.localizedDescription
                            }
                            resolving = false
                        }
                    }
                    .disabled(resolving)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("watch-resolve-orphaned-preparation")
                    if let resolutionError {
                        Text(resolutionError).font(FitnessType.body(.footnote)).foregroundStyle(.orange)
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(FitnessPalette.paper, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("watch-orphaned-preparation")
            }
            if !watch.isPaired {
                Button(
                    String(localized: "Cómo emparejarlo", bundle: .main), systemImage: "arrow.up.forward.app"
                ) { showPairingHelp = true }
                .buttonStyle(.glassProminent).tint(FitnessPalette.text).foregroundStyle(
                    FitnessPalette.canvas
                ).frame(minHeight: 44)
            }
            Button {
                requesting = true
                Task {
                    await watch.reviewPhoneHealthAccess()
                    requesting = false
                }
            } label: {
                Label(
                    requesting
                        ? String(localized: "Revisando Salud…", bundle: .main)
                        : String(localized: "Revisar acceso a Salud en iPhone", bundle: .main),
                    systemImage: "heart.text.clipboard"
                )
                .frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(.glassProminent).tint(FitnessPalette.text).foregroundStyle(
                FitnessPalette.canvas
            )
            .disabled(requesting).accessibilityIdentifier("watch-review-health")
            Toggle(
                String(localized: "Usar el Watch en mis sesiones", bundle: .main), isOn: $watch.useWatch
            )
            .disabled(!watch.isPaired || !watch.isInstalled).accessibilityIdentifier("watch-enabled")
            Text(
                String(
                    localized:
                        "Prepara el reloj al elegir una sesión. Preparar no mueve la banda. Inicio y controles permanecen en el iPhone; puedes continuar sin Watch.",
                    bundle: .main)
            )
            .font(FitnessType.body(.footnote)).foregroundStyle(FitnessPalette.secondary)
            Text(
                String(
                    localized:
                        "Apple solicita acceso por tipo de dato. Una lectura ausente no significa permiso denegado.",
                    bundle: .main)
            )
            .font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
            if let message = watch.readiness.message {
                Label(FitnessText.watchPreparationMessage(message), systemImage: "info.circle").font(
                    FitnessType.body(.footnote))
            }
            if let error = watch.errorMessage {
                Label(FitnessText.watchPreparationMessage(error), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(FitnessType.body(.footnote))
            }
            Button(
                String(localized: "Comprobar disponibilidad", bundle: .main), systemImage: "arrow.clockwise"
            ) { watch.refreshAvailability() }.frame(minHeight: 44)
        }
        .navigationTitle("Apple Watch").navigationBarTitleDisplayMode(.inline)
        .onAppear { watch.refreshAvailability() }
        .task {
            while !Task.isCancelled {
                statusClock = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .sheet(isPresented: $showPairingHelp) {
            NavigationStack {
                ScreenContent {
                    Text(String(localized: "Empareja con tu iPhone", bundle: .main)).font(
                        FitnessType.title(28, relativeTo: .title))
                    Text(
                        String(
                            localized:
                                "Abre la app Watch de Apple en este iPhone y sigue sus instrucciones para añadir el reloj. Después vuelve aquí y comprueba la instalación de VAGANCIA FITNESS.",
                            bundle: .main))
                    Text(
                        String(
                            localized:
                                "Usamos el vínculo administrado por iOS; no buscamos el reloj por Bluetooth.",
                            bundle: .main)
                    ).foregroundStyle(FitnessPalette.secondary)
                }.toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Listo", bundle: .main)) { showPairingHelp = false }
                    }
                }
            }.presentationDetents([.medium, .large])
        }
    }
    private func setupRow(_ title: String, systemImage: String, done: Bool, detail: String)
        -> some View
    {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle" : systemImage).foregroundStyle(
                done ? .green : FitnessPalette.accent
            ).frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(FitnessType.body(.headline))
                Text(detail).font(FitnessType.body(.footnote)).foregroundStyle(FitnessPalette.secondary)
            }
        }.accessibilityElement(children: .combine)
    }
}

struct WatchPreparationPanel: View {
    @Environment(PhoneWatchService.self) private var watch
    @Bindable var coordinator: WorkoutCoordinator
    @State private var error: String?
    @State private var resolving = false
    var body: some View {
        if watch.useWatch, !coordinator.mockMode {
            VStack(alignment: .leading, spacing: 12) {
                Label(String(localized: "Tu Apple Watch", bundle: .main), systemImage: "applewatch").font(
                    FitnessType.body(.headline))
                Text(
                    coordinator.continueWithoutWatch
                        ? String(localized: "Esta sesión continuará sin métricas del Watch.", bundle: .main)
                        : coordinator.watchPrepared
                            ? String(localized: "Preparado · esperando tu confirmación de inicio.", bundle: .main)
                            : String(localized: "Prepara el reloj sin iniciar la banda.", bundle: .main)
                )
                .font(FitnessType.body(.subheadline)).foregroundStyle(FitnessPalette.secondary)
                if !coordinator.continueWithoutWatch {
                    Button {
                        Task {
                            do {
                                try await coordinator.prepareWatch()
                                error = nil
                            } catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        Label(
                            coordinator.isPreparingWatch
                                ? String(localized: "Preparando Watch…", bundle: .main)
                                : coordinator.watchPrepared
                                    ? String(localized: "Watch preparado", bundle: .main)
                                    : String(localized: "Preparar Watch", bundle: .main),
                            systemImage: coordinator.watchPrepared ? "checkmark.circle" : "applewatch"
                        )
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered).disabled(
                        coordinator.isPreparingWatch || coordinator.watchPrepared
                    )
                    .accessibilityIdentifier("prepare-watch")
                    Button(String(localized: "Continuar sin Watch", bundle: .main)) {
                        coordinator.chooseWithoutWatch()
                    }.frame(minHeight: 44).disabled(coordinator.isPreparingWatch)
                }
                if let orphan = watch.orphanedPreparation {
                    Label(
                        String(localized: "Preparación anterior en Watch", bundle: .main),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(FitnessType.body(.subheadline, weight: .semibold))
                    Text(
                        String(
                            localized:
                                "Sesión \(String(orphan.id.prefix(8)))… · \(FitnessText.watchPreparationMessage(orphan.message))",
                            bundle: .main)
                    )
                    .font(FitnessType.body(.footnote)).foregroundStyle(FitnessPalette.secondary)
                    Button(
                        resolving
                            ? String(localized: "Solicitando descarte…", bundle: .main)
                            : String(localized: "Descartar preparación anterior", bundle: .main)
                    ) {
                        resolving = true
                        Task {
                            do {
                                try await watch.resolveOrphanedPreparation()
                                error = nil
                            } catch { self.error = error.localizedDescription }
                            resolving = false
                        }
                    }
                    .disabled(resolving || coordinator.isPreparingWatch)
                    .frame(minHeight: 44)
                    Text(
                        String(
                            localized:
                                "El Watch solo descartará una preparación sin captura. Después puedes elegir Preparar Watch de nuevo; la banda no se mueve con esta acción.",
                            bundle: .main)
                    )
                    .font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
                }
                if let error { Text(error).font(FitnessType.body(.footnote)).foregroundStyle(.orange) }
            }.padding(18).background(FitnessPalette.paper, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct HealthSavePanel: View {
    @Environment(PhoneWatchService.self) private var watch
    let result: HealthSaveResult?
    let workoutID: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                String(localized: "Guardado localmente", bundle: .main), systemImage: "checkmark.circle"
            ).foregroundStyle(.green)
            if let result {
                Label(
                    title(result.state),
                    systemImage: result.state == .saved ? "heart.text.clipboard" : "clock.arrow.circlepath"
                )
                .foregroundStyle(result.state == .saved ? .green : .orange)
                if let message = result.message {
                    Text(FitnessText.watchPreparationMessage(message)).font(FitnessType.body(.footnote))
                        .foregroundStyle(FitnessPalette.secondary)
                }
                if result.state == .saved {
                    Text(
                        String(
                            localized: "Una entrada en Salud · distancia FTMS y métricas del Watch.",
                            bundle: .main)
                    ).font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
                }
                if let start = result.captureStartedAt, let end = result.captureEndedAt {
                    Text(
                        String(
                            localized:
                                "Captura del Watch: \(Int(max(0,end.timeIntervalSince(start)))) s. El tiempo operativo se conserva por separado.",
                            bundle: .main)
                    ).font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
                }
                if [.pending, .saving, .uncertain, .failed].contains(result.state) {
                    Button(String(localized: "Revisar resultado en Salud", bundle: .main)) {
                        watch.reconcile(id: workoutID)
                    }.frame(minHeight: 44)
                    Text(
                        String(
                            localized: "Se consulta el resultado existente; no se repite un guardado incierto.",
                            bundle: .main)
                    ).font(FitnessType.body(.caption2)).foregroundStyle(FitnessPalette.secondary)
                }
            } else {
                Text(
                    String(
                        localized: "Sin captura del Watch; no se envió este entrenamiento a Salud.",
                        bundle: .main)
                ).font(FitnessType.body(.footnote)).foregroundStyle(FitnessPalette.secondary)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(
            FitnessPalette.paper, in: RoundedRectangle(cornerRadius: 14)
        )
        .accessibilityIdentifier("health-save-result")
    }
    private func title(_ state: HealthSaveState) -> String {
        switch state {
        case .notRequested: String(localized: "Salud no solicitado", bundle: .main)
        case .pending: String(localized: "Pendiente de Salud", bundle: .main)
        case .saving: String(localized: "Guardando en Salud", bundle: .main)
        case .saved: String(localized: "Guardado en Salud", bundle: .main)
        case .failed: String(localized: "No se guardó en Salud", bundle: .main)
        case .uncertain: String(localized: "Resultado de Salud por confirmar", bundle: .main)
        case .discarded: String(localized: "Preparación descartada en Salud", bundle: .main)
        }
    }
}
