import FitnessCore
import SwiftUI

enum WatchBrand {
    static let canvas = Color(red: 8 / 255, green: 8 / 255, blue: 8 / 255)
    static let ivory = Color(red: 230 / 255, green: 227 / 255, blue: 223 / 255)
    static let fire = Color(red: 1, green: 98 / 255, blue: 71 / 255)
    static let red = Color(red: 240 / 255, green: 45 / 255, blue: 42 / 255)
}

struct WatchRootView: View {
    @Bindable var service: WatchWorkoutService
    @State private var requesting = false
    @State private var resolving = false
    @State private var finishingRecovered = false
    @State private var recoveredFinishError: String?
    @State private var resolutionError: String?
    @State private var selectedPage = 0
    @ScaledMetric(relativeTo: .caption2) private var captionSize: CGFloat = 11
    @ScaledMetric(relativeTo: .largeTitle) private var pulseSize: CGFloat = 36
    var body: some View {
        NavigationStack {
            if let record = service.current, record.captureStartedAt != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    TabView(selection: $selectedPage) {
                        pulsePage(record, now: context.date).tag(0)
                        machinePage(record, now: context.date).tag(1)
                        intervalPage(record).tag(2)
                        energyPage(record, now: context.date).tag(3)
                        if record.captureState == .ended || record.health.state == .saved
                            || record.view.endedAt != nil
                        {
                            summaryPage(record).tag(4)
                            healthPage(record).tag(5)
                        }
                    }.tabViewStyle(.verticalPage)
                }
            } else {
                setup
            }
        }.foregroundStyle(WatchBrand.ivory).background(WatchBrand.canvas).containerBackground(
            WatchBrand.canvas, for: .navigation
        )
        .onChange(of: service.current?.id) { _, _ in selectedPage = previewPage(or: 0) }
        .onChange(of: service.current?.captureState) { _, state in
            if state == .ended { selectedPage = previewPage(or: 4) }
        }
        .onAppear {
            #if DEBUG
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("--watch-ui-preview"),
                    let index = arguments.firstIndex(of: "--watch-ui-page"),
                    arguments.indices.contains(index + 1), let page = Int(arguments[index + 1])
                {
                    selectedPage = page
                }
            #endif
        }
    }

    private var setup: some View {
        ScrollView {
            VStack(spacing: 12) {
                if service.orphanedPreparation == nil {
                    Image("FitnessMark").resizable().scaledToFit().frame(width: 36, height: 36)
                        .accessibilityHidden(true)
                    Image("FitnessWordmark").resizable().scaledToFit().frame(width: 104, height: 36)
                        .accessibilityLabel("VAGANCIA FITNESS")
                }
                if let orphan = service.orphanedPreparation {
                    Label("Preparación anterior", systemImage: "exclamationmark.triangle").foregroundStyle(
                        .orange
                    ).font(.headline)
                    Text(
                        WatchText.format(
                            "Sesión %@… · %@", String(orphan.id.prefix(8)), preparationStateTitle(orphan.state))
                    ).font(.caption2)
                    Text("Sin captura activa").font(.footnote).foregroundStyle(.secondary)
                    Button(WatchText.string(resolving ? "Resolviendo…" : "Descartar esta preparación")) {
                        resolving = true
                        resolutionError = nil
                        Task {
                            do { try await service.resolveOrphanedPreparation() } catch {
                                resolutionError = error.localizedDescription
                            }
                            resolving = false
                        }
                    }.buttonStyle(.glassProminent).tint(WatchBrand.fire).disabled(resolving)
                        .accessibilityIdentifier("watch-resolve-orphaned-preparation")
                    if service.current?.view.synthetic == true {
                        Text("Ejemplo · sin hardware").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(FitnessText.watchPreparationMessage(orphan.message)).font(.footnote)
                        .multilineTextAlignment(.center)
                    Text("Solo descarta esta preparación sin captura. La banda se controla desde el iPhone.")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let resolutionError {
                        Text(resolutionError).font(.footnote).foregroundStyle(.orange)
                            .accessibilityIdentifier("watch-resolution-error")
                    }
                } else if service.readiness.state == .prepared {
                    Label("Listo para entrenar", systemImage: "checkmark.circle").foregroundStyle(.green)
                        .font(.headline)
                    Text("Confirma el inicio en tu iPhone.").font(.footnote).multilineTextAlignment(.center)
                    Text("Preparación sin movimiento").font(.caption2).foregroundStyle(.green)
                    if !service.phoneReachable {
                        Label("Sin enlace inmediato con iPhone", systemImage: "iphone.slash")
                            .font(.caption2).foregroundStyle(.orange)
                        Button("Comprobar conexión") { service.refreshConnection() }.frame(minHeight: 44)
                    }
                } else if service.readiness.state == .preparing {
                    ProgressView("Preparando…")
                } else {
                    Text(
                        WatchText.string(
                            service.phoneReachable ? "iPhone disponible" : "Abre la app en tu iPhone.")
                    ).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button {
                        requesting = true
                        Task {
                            await service.requestHealthAccess()
                            requesting = false
                        }
                    } label: {
                        Text(WatchText.string(requesting ? "Revisando…" : "Revisar acceso a Salud")).frame(
                            minHeight: 36)
                    }
                    .buttonStyle(.glassProminent).tint(WatchBrand.ivory).foregroundStyle(WatchBrand.canvas)
                    .disabled(requesting)
                    .accessibilityIdentifier("watch-health-access")
                    Text("Pulso, energía y guardado de la sesión. Apple muestra los permisos.").font(
                        .caption2
                    ).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Comprobar conexión") { service.refreshConnection() }.frame(minHeight: 44)
                    Text("El inicio y los controles están en el iPhone.").font(.caption2).foregroundStyle(
                        .secondary
                    ).multilineTextAlignment(.center)
                }
                if service.readiness.state != .prepared, let text = service.readiness.message {
                    Text(FitnessText.watchPreparationMessage(text)).font(.footnote).foregroundStyle(
                        service.readiness.state == .conflict ? .orange : .secondary
                    ).multilineTextAlignment(.center)
                }
                if service.readiness.state != .prepared, let error = service.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
            }.padding(.horizontal, 4).padding(.bottom, 12)
        }.toolbar(.hidden, for: .navigationBar)
    }

    private func page<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image("FitnessMark").resizable().scaledToFit().frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    Text(title).font(.caption2).foregroundStyle(.secondary)
                }
                content()
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4).padding(.bottom, 10)
        }
    }

    private func preparationStateTitle(_ state: WatchCaptureState) -> String {
        switch state {
        case .preparing: WatchText.string("Preparando")
        case .prepared: WatchText.string("Preparada")
        case .failed: WatchText.string("Interrumpida")
        case .recovering: WatchText.string("Recuperando")
        case .conflict: WatchText.string("Pendiente de resolver")
        default: WatchText.string("Sin captura")
        }
    }

    private func pulsePage(_ record: WatchSessionRecord, now: Date) -> some View {
        let pulse = record.samples.filter { $0.metric == "heartRateBPM" }.max {
            $0.sampledAt < $1.sampledAt
        }
        let speed = record.view.metrics["speedKPH"]
        let distance = record.view.metrics["sessionDistanceMeters"]
        let speedDate = speed.map { $0.sampledAt ?? $0.receivedAt }
        let distanceDate = distance.map { $0.sampledAt ?? $0.receivedAt }
        let grouped =
            speedDate != nil && distanceDate != nil
            && abs(speedDate!.timeIntervalSince(distanceDate!)) <= 2
        let groupedDate = grouped ? min(speedDate!, distanceDate!) : nil
        let latestMetricDate = [speedDate, distanceDate].compactMap { $0 }.max()
        let remoteOld =
            now.timeIntervalSince(record.view.generatedAt) > 10
            && (latestMetricDate == nil
                || latestMetricDate!.timeIntervalSince(record.view.generatedAt) > 5)
        return page(
            record.view.synthetic
                ? WatchText.format("Ejemplo · %@", stateTitle(record)) : stateTitle(record)
        ) {
            if !service.phoneReachable {
                Text("iPhone · sin enlace inmediato").font(.system(size: captionSize)).foregroundStyle(
                    .orange)
            } else if remoteOld {
                Text(
                    WatchText.format(
                        "Vista del iPhone · %@", age(record.view.generatedAt, now: now, threshold: 10))
                )
                .font(.system(size: captionSize)).foregroundStyle(.orange)
            }
            Label("Pulso", systemImage: "heart.fill").foregroundStyle(WatchBrand.red).font(
                .system(size: captionSize + 2))
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(pulse.map { $0.value.formatted(.number.precision(.fractionLength(0))) } ?? "—")
                    .font(.system(size: pulseSize, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(
                        pulse.map { now.timeIntervalSince($0.sampledAt) > 15 } == true
                            ? Color.secondary : WatchBrand.ivory)
                Text("lpm").font(.footnote).foregroundStyle(.secondary)
            }
            Text(
                pulse.map {
                    WatchText.format(
                        record.view.synthetic ? "Simulada · %@" : "HealthKit · %@",
                        age($0.sampledAt, now: now, threshold: 15))
                } ?? WatchText.string("Sin muestras del Watch")
            )
            .font(.system(size: captionSize)).foregroundStyle(pulse == nil ? .orange : .secondary)
            if service.canFinishRecoveredCapture {
                Text("Captura propia recuperada. La banda se controla desde el iPhone.")
                    .font(.caption2).foregroundStyle(.orange)
                Button(WatchText.string(finishingRecovered ? "Guardando…" : "Finalizar captura en Salud")) {
                    finishingRecovered = true
                    recoveredFinishError = nil
                    Task {
                        do { try await service.finishRecoveredCapture() } catch {
                            recoveredFinishError = error.localizedDescription
                        }
                        finishingRecovered = false
                    }
                }.disabled(finishingRecovered)
                    .accessibilityIdentifier("watch-finish-recovered-capture")
                if let recoveredFinishError {
                    Text(recoveredFinishError).font(.caption2).foregroundStyle(.orange)
                }
            } else if record.captureState == .failed || record.captureState == .recovering,
                let error = service.errorMessage
            {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
            Divider()
            if let groupedDate, now.timeIntervalSince(groupedDate) > 5 {
                Text(
                    WatchText.format("Datos de la caminadora · %@", age(groupedDate, now: now, threshold: 5))
                )
                .font(.system(size: captionSize)).foregroundStyle(.orange)
                .accessibilityIdentifier("watch-machine-freshness")
            }
            HStack {
                compactMetric(speed, unit: "km/h", divisor: 1, now: now, showAge: !grouped)
                Spacer(minLength: 4)
                compactMetric(distance, unit: "km", divisor: 1_000, now: now, showAge: !grouped)
            }
            HStack {
                Text(duration(record.view.snapshot.activeElapsedSeconds ?? 0)).monospacedDigit().font(
                    .title3)
                Text("activos").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func machinePage(_ record: WatchSessionRecord, now: Date) -> some View {
        page(WatchText.string(record.view.synthetic ? "Ejemplo · Caminadora" : "Caminadora")) {
            compactMetric(record.view.metrics["speedKPH"], unit: "km/h", divisor: 1, now: now)
            Divider()
            compactMetric(
                record.view.metrics["sessionDistanceMeters"], unit: "km", divisor: 1_000, now: now)
            compactMetric(record.view.metrics["inclinationPercent"], unit: "%", divisor: 1, now: now)
            Text("Inicio, ajustes y parada: iPhone.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func intervalPage(_ record: WatchSessionRecord) -> some View {
        let view = record.view.snapshot
        let nextIndex = view.intervalIndex + 1
        return page(WatchText.string(record.view.synthetic ? "Ejemplo · Programa" : "Programa")) {
            Text(
                WatchText.format("Etapa %ld de %ld", view.intervalIndex + 1, view.program.intervals.count)
            ).font(.caption2).foregroundStyle(WatchBrand.fire)
            Text(phase(view.phase)).font(.title3.weight(.semibold))
            Text(
                duration(max(0, Double(view.currentInterval.durationSeconds) - view.phaseElapsedSeconds))
            ).font(.title2.monospacedDigit())
            if view.program.intervals.indices.contains(nextIndex) {
                Text(WatchText.format("Después · %@", phase(view.program.intervals[nextIndex].phase))).font(
                    .footnote
                ).foregroundStyle(.secondary)
            }
            Divider()
            Text(
                WatchText.format(
                    "Plan: %@ km/h · %@ %%", number(view.currentInterval.targetSpeedKPH),
                    number(view.currentInterval.targetInclinationPercent))
            ).font(.caption2)
            Text(
                WatchText.format(
                    "Efectivo: %@ km/h · %@ %%", number(view.effectiveSpeedKPH),
                    number(view.effectiveInclinationPercent))
            ).font(.caption2)
            Text("Etapas confirmadas por el iPhone").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func energyPage(_ record: WatchSessionRecord, now: Date) -> some View {
        let energy = record.samples.filter { $0.metric == "energyKilocalories" }.max {
            $0.sampledAt < $1.sampledAt
        }
        return page(WatchText.string(record.view.synthetic ? "Ejemplo · Watch" : "Watch")) {
            Text("Energía activa").font(.headline)
            Text(
                energy.map {
                    WatchText.format("%@ kcal", $0.value.formatted(.number.precision(.fractionLength(0))))
                } ?? WatchText.string("— kcal")
            ).font(.title.weight(.semibold).monospacedDigit())
            Text("Estimación del Watch").font(.caption2).foregroundStyle(.secondary)
            Text(
                energy.map {
                    WatchText.format("HealthKit · %@", age($0.sampledAt, now: now, threshold: 30))
                } ?? WatchText.string("Sin muestras de energía")
            ).font(.caption2).foregroundStyle(.secondary)
            if let error = service.errorMessage { Text(error).font(.footnote).foregroundStyle(.orange) }
        }
    }

    private func summaryPage(_ record: WatchSessionRecord) -> some View {
        let pulseSamples = record.samples.filter { $0.metric == "heartRateBPM" }
        let raw = pulseSamples.filter { $0.aggregation == "rawHealthKit" }
        let pulses = (raw.isEmpty ? pulseSamples : raw).map(\.value)
        return page(WatchText.string(record.view.synthetic ? "Ejemplo · Tu vuelta" : "Tu vuelta")) {
            Text(duration(record.view.snapshot.activeElapsedSeconds ?? 0)).font(.title2.monospacedDigit())
            Text(
                WatchText.format(
                    "%@ km",
                    number(record.view.metrics["sessionDistanceMeters"].map { $0.value / 1_000 }, digits: 2))
            ).font(.title3.monospacedDigit())
            Text(
                WatchText.format(
                    "Distancia · %@", metricSource(record.view.metrics["sessionDistanceMeters"]))
            ).font(.caption2).foregroundStyle(.secondary)
            Divider()
            Text(
                WatchText.format(
                    "Medio: %@ lpm",
                    number(
                        record.health.heartRateAverageBPM
                            ?? (pulses.isEmpty ? nil : pulses.reduce(0, +) / Double(pulses.count)), digits: 0))
            ).font(.footnote)
            Text(
                WatchText.format(
                    "Máximo: %@ lpm", number(record.health.heartRateMaximumBPM ?? pulses.max(), digits: 0))
            ).font(.footnote)
            Text("Registro completo y ZIP en iPhone.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func healthPage(_ record: WatchSessionRecord) -> some View {
        page(WatchText.string("Salud")) {
            Image(
                systemName: record.health.state == .saved ? "checkmark.circle" : "clock.arrow.circlepath"
            )
            .font(.largeTitle).foregroundStyle(record.health.state == .saved ? .green : .orange)
            Text(healthTitle(record.health.state)).font(.title3.weight(.semibold))
            Text(
                record.health.message.map { FitnessText.watchPreparationMessage($0) }
                    ?? WatchText.string(
                        record.health.state == .saved
                            ? "Una entrada en Salud. El registro local está en el iPhone."
                            : "El registro local se conserva en el iPhone.")
            )
            .font(.footnote).foregroundStyle(.secondary)
            if record.health.state != .saved {
                Button("Revisar resultado") { Task { await service.reconcile() } }.frame(minHeight: 44)
            }
        }
    }

    private func compactMetric(
        _ sample: WorkoutSample?, unit: String, divisor: Double, now: Date, showAge: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(number(sample.map { $0.value / divisor }, digits: divisor == 1_000 ? 2 : 1)).font(
                .title3.weight(.semibold).monospacedDigit()
            )
            .foregroundStyle(
                sample.map { now.timeIntervalSince($0.sampledAt ?? $0.receivedAt) > 5 } == true
                    ? Color.secondary : WatchBrand.ivory)
            Text(WatchText.format("%@ · %@", unit, metricSource(sample))).font(.system(size: captionSize))
                .foregroundStyle(.secondary)
            if showAge {
                if let sample {
                    Text(age(sample.sampledAt ?? sample.receivedAt, now: now, threshold: 5)).font(
                        .system(size: captionSize)
                    ).foregroundStyle(
                        now.timeIntervalSince(sample.sampledAt ?? sample.receivedAt) > 5 ? .orange : .secondary)
                } else {
                    Text("Sin lectura").font(.system(size: captionSize)).foregroundStyle(.secondary)
                }
            }
        }.accessibilityElement(children: .combine)
    }
    private func metricSource(_ sample: WorkoutSample?) -> String {
        guard let sample else { return WatchText.string("Sin lectura") }
        switch sample.source {
        case .machineFTMS: return "FTMS"
        case .derived: return WatchText.string("Derivada de FTMS")
        case .watchHealthKit: return "HealthKit"
        case .mock: return WatchText.string("Ejemplo")
        case .unknown: return WatchText.string("Origen desconocido")
        }
    }
    private func previewPage(or fallback: Int) -> Int {
        #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--watch-ui-preview"), let i = args.firstIndex(of: "--watch-ui-page"),
                args.indices.contains(i + 1), let page = Int(args[i + 1])
            {
                return page
            }
        #endif
        return fallback
    }
    private func number(_ value: Double?, digits: Int = 1) -> String {
        value?.formatted(.number.precision(.fractionLength(digits))) ?? "—"
    }
    private func duration(_ value: TimeInterval) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    private func age(_ date: Date, now: Date, threshold: Int) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        guard seconds > threshold else { return WatchText.string("ahora") }
        if seconds < 60 {
            return WatchText.format(seconds == 1 ? "hace %ld segundo" : "hace %ld segundos", seconds)
        }
        let minutes = seconds / 60
        return WatchText.format(minutes == 1 ? "hace %ld minuto" : "hace %ld minutos", minutes)
    }
    private func phase(_ phase: WorkoutPhase) -> String {
        switch phase {
        case .warmup: WatchText.string("Calentamiento")
        case .work: WatchText.string("Esfuerzo")
        case .recovery: WatchText.string("Recuperación")
        case .cooldown: WatchText.string("Enfriamiento")
        case .steady: WatchText.string("Continuo")
        }
    }
    private func stateTitle(_ record: WatchSessionRecord) -> String {
        if record.captureState == .failed { return WatchText.string("Captura interrumpida") }
        return switch record.view.snapshot.state {
        case .pausing, .finishing: WatchText.string("Parando · sin confirmar")
        case .paused: WatchText.string("En pausa")
        case .manual: WatchText.string("Control suspendido · revisa iPhone")
        case .completed: WatchText.string("Completado")
        case .interrupted: WatchText.string("Interrumpido · parada sin confirmar")
        default: WatchText.string("En curso")
        }
    }
    private func healthTitle(_ state: HealthSaveState) -> String {
        switch state {
        case .saved: WatchText.string("Guardado en Salud")
        case .failed: WatchText.string("No se guardó en Salud")
        case .uncertain: WatchText.string("Resultado por confirmar")
        case .discarded: WatchText.string("Preparación descartada")
        default: WatchText.string("Pendiente de Salud")
        }
    }
}
