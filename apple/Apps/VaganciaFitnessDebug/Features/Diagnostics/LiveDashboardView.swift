import Charts
import FitnessCore
import FitnessRuntime
import SwiftUI

// THESIS: operate the treadmill through explicit, evidenced experiments.
// OWN-WORLD: inherited native session journal, semantic iOS lists and teal actions.
// STORY: observe live values, prepare a stop, authorize one movement, compare channels.
// FIRST VIEWPORT: connection, FTMS speed/distance, native chart; stop remains pinned.
// FORM: extension of the incumbent Operate surface; no replacement visual world.
// FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance.
struct LiveDashboardView: View {
    let explorer: BluetoothExplorer
    let store: SessionStore
    @State private var targetSpeed = 0.8
    @State private var targetInclination = 0.0
    @State private var confirmation: FTMSAction?
    @Environment(\.scenePhase) private var scenePhase

    private var device: GATTDevice? { store.session?.device }
    private var evidence: InteractiveEvidence { device?.interactive ?? InteractiveEvidence() }
    private var connected: Bool { explorer.phase == .ready }
    private var control: FTMSControl { evidence.control }
    private var recentSpeed: FTMSMetric? { device?.telemetry?.speed }
    private var canQueryFitShow: Bool {
        connected && !explorer.fitShowQueryPending
            && evidence.fitShow.first { $0.channel == evidence.selectedProtocol }?.subscriptionStatus
                == "active"
    }
    private var canStart: Bool {
        connected && scenePhase == .active && evidence.selectedProtocol == .ftms && control.canStart
            && recentSpeed?.value == 0 && recentSpeed?.isStale(at: Date()) == false
    }
    private var canSetSpeed: Bool {
        connected && scenePhase == .active && evidence.selectedProtocol == .ftms && control.canStop
            && control.stopAccepted && !control.movementUncertain && !control.requiresReconnect
            && control.pending == nil && device?.speedControlAdvertised == true
            && recentSpeed?.isStale(at: Date()) == false && (recentSpeed?.value ?? 0) > 0
    }

    var body: some View {
        List {
            Section {
                valueRow("Conexión", value: connected ? "Conectado" : "Datos guardados · desconectado")
                if device?.source == .synthetic {
                    Label("Datos sintéticos · sin hardware", systemImage: "testtube.2")
                }
                Text("Recibe telemetría con la pantalla bloqueada. Prueba movimientos con la app visible.")
                    .font(.footnote).foregroundStyle(Color.primary)
                if let error = explorer.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Color.primary)
                }
            }
            if connected, let reception = device?.reception,
                reception.streams.contains(where: { $0.silent })
            {
                Section("Recepción sin datos recientes") {
                    ForEach(reception.streams.filter(\.silent), id: \.channel) { stream in
                        Text("\(stream.channel): más de 5 segundos sin mensajes.").foregroundStyle(
                            Color.primary)
                    }
                    Text(
                        "La conexión puede seguir activa. No se reintenta ni se envían órdenes. Si la banda se mueve, usa la consola física; después desconecta y vuelve a conectar para continuar."
                    ).foregroundStyle(Color.primary)
                }
            }
            if let device {
                FTMSTelemetrySection(
                    device: device, connected: connected, distanceProgress: store.session?.distanceProgress)
            }
            Section("Velocidad recibida · últimas muestras") {
                if explorer.livePoints.isEmpty {
                    Text(
                        "La gráfica aparecerá al recibir velocidad en esta conexión. El ZIP conserva los datos de toda la sesión."
                    ).foregroundStyle(Color.primary)
                } else {
                    Chart(explorer.livePoints) { point in
                        LineMark(x: .value("Hora", point.date), y: .value("km/h", point.speed))
                            .interpolationMethod(.stepEnd)
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 2)) {
                            AxisValueLabel(format: .dateTime.minute().second())
                        }
                    }
                    .chartYAxisLabel("km/h")
                    .frame(height: 150)
                    .accessibilityLabel("Gráfica de velocidad FTMS recibida, en kilómetros por hora")
                    Text(
                        "\(explorer.livePoints.count) muestras recientes; los saltos representan valores recibidos."
                    )
                    .font(.footnote).foregroundStyle(Color.primary)
                }
            }
            Section("Protocolo de la prueba") {
                Picker(
                    "Canal",
                    selection: Binding(
                        get: { evidence.selectedProtocol }, set: { explorer.selectProtocol($0) })
                ) {
                    ForEach(DiagnosticProtocol.allCases) { channel in Text(channel.title).tag(channel) }
                }
                .disabled(!connected || !control.canSelectProtocol)
                .accessibilityIdentifier("protocolSelector")
                Text(
                    "Cambiar de canal no envía movimiento. FTMS sigue recibiendo mientras escuchas FitShow. El control propietario permanece bloqueado hasta confirmar mensajes y variante."
                )
                .font(.footnote).foregroundStyle(Color.primary)
                if !control.canSelectProtocol {
                    Text(
                        control.requiresReconnect
                            ? "Hay un resultado incierto: desconecta y reconecta antes de cambiar de canal."
                            : "Termina la prueba y confirma parada antes de cambiar de canal."
                    )
                    .foregroundStyle(Color.primary)
                }
            }
            if evidence.selectedProtocol == .ftms { controlSection } else { fitShowActions }
            comparisonSection
            Section {
                NavigationLink {
                    FTMSDiagnosticsView(store: store)
                } label: {
                    Label("Capacidades y rangos FTMS", systemImage: "list.bullet.rectangle")
                }
                Text(
                    "Exporta el diagnóstico desde el registro de sesión. Incluye consultas, bytes, respuestas, errores, canal e identificadores de evidencia."
                )
                .font(.footnote).foregroundStyle(Color.primary)
            }
        }
        .navigationTitle("Panel y protocolos")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Button(role: .destructive) {
                    explorer.execute(.stop)
                } label: {
                    Label("Parar banda", systemImage: "stop.fill").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !connected || evidence.selectedProtocol != .ftms || !control.canStop
                        || control.pending?.action == .stop
                        || (control.requiresReconnect && control.last?.action == .stop)
                )
                .accessibilityIdentifier("stopBelt")
            }
            .padding().background(.bar)
        }
        .confirmationDialog(
            confirmation?.title ?? "Prueba de movimiento",
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            titleVisibility: .visible
        ) {
            if confirmation == .start {
                Button("Iniciar banda ahora") {
                    explorer.execute(.start)
                    confirmation = nil
                }
            } else if confirmation == .speed {
                Button("Aplicar \(targetSpeed.formatted(.number.precision(.fractionLength(1...2)))) km/h") {
                    explorer.execute(.speed, speed: targetSpeed)
                    confirmation = nil
                }
            } else if confirmation == .inclination {
                Button("Aplicar \(targetInclination.formatted()) %") {
                    explorer.execute(.inclination, inclination: targetInclination)
                    confirmation = nil
                }
            }
            Button("Cancelar", role: .cancel) { confirmation = nil }
        } message: {
            Text(
                "Prueba FTMS explícita. Mantén accesibles los controles físicos. Una respuesta aceptada no confirma el movimiento físico."
            )
        }
        .onAppear {
            if let minimum = device?.speedRange?.minimum { targetSpeed = minimum }
            if let minimum = device?.inclinationRange?.minimum { targetInclination = minimum }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { confirmation = nil } }
    }

    private var controlSection: some View {
        Section("Pruebas FTMS") {
            Text("Parada Bluetooth: usa la llave o consola física ante una emergencia.").font(.footnote)
                .foregroundStyle(Color.primary)
            Text(control.message).foregroundStyle(Color.primary).accessibilityIdentifier("controlMessage")
            if control.requiresReconnect {
                Text(
                    "Desconecta desde Caminadora y vuelve a conectar para preparar otra prueba. No se repetirán órdenes pendientes."
                ).foregroundStyle(Color.primary)
            }
            if !control.indicationReady {
                Button("Preparar canal de control") { explorer.prepareControl() }.frame(minHeight: 44)
                    .disabled(!connected || control.requiresReconnect).accessibilityIdentifier(
                        "prepareControl")
            } else if !control.permission {
                Button("Solicitar permiso FTMS") { explorer.execute(.requestControl) }.frame(minHeight: 44)
                    .disabled(!connected || control.pending != nil || control.requiresReconnect)
                    .accessibilityIdentifier("requestControl")
            }
            valueRow(
                "Parada",
                value: control.stopAccepted
                    ? "Aceptada por FTMS · físico por comprobar" : "Prueba Parar antes de iniciar")
            if let last = control.last {
                valueRow("Última prueba", value: last.action.title)
                valueRow("Resultado", value: resultTitle(last.result))
                if let code = last.responseCode { valueRow("Código FTMS", value: String(code)) }
                Text("Procedimiento: \(last.id)").font(.footnote.monospaced()).textSelection(.enabled)
            }
            Button {
                confirmation = .start
            } label: {
                Label("Probar inicio", systemImage: "play.fill").frame(minHeight: 44)
            }
            .disabled(!canStart).accessibilityIdentifier("startBelt")
            if let range = device?.speedRange {
                LabeledContent("Objetivo") {
                    Text("\(targetSpeed.formatted(.number.precision(.fractionLength(1...2)))) km/h")
                        .monospacedDigit()
                }
                Stepper(
                    "Ajustar objetivo", value: $targetSpeed, in: range.minimum...range.maximum,
                    step: range.increment
                )
                .disabled(!canSetSpeed).accessibilityIdentifier("speedStepper")
                Text(
                    "Rango anunciado: \(range.minimum.formatted())–\(range.maximum.formatted()) km/h; incremento \(range.increment.formatted())."
                )
                .font(.footnote).foregroundStyle(Color.primary)
                Button("Aplicar velocidad…") { confirmation = .speed }.frame(minHeight: 44)
                    .disabled(!canSetSpeed).accessibilityIdentifier("applySpeed")
            } else {
                Text("Sin rango de velocidad interpretable; no se habilita cambiar el objetivo.")
                    .foregroundStyle(Color.primary)
            }
            if let range = device?.inclinationRange, range.increment > 0, range.minimum <= range.maximum {
                LabeledContent("Objetivo de inclinación", value: "\(targetInclination.formatted()) %")
                Stepper(
                    "Ajustar inclinación", value: $targetInclination, in: range.minimum...range.maximum,
                    step: range.increment
                )
                .disabled(!canSetSpeed || device?.inclinationControlAdvertised != true)
                .accessibilityIdentifier("inclinationStepper")
                Button("Aplicar inclinación…") { confirmation = .inclination }
                    .frame(minHeight: 44)
                    .disabled(!canSetSpeed || device?.inclinationControlAdvertised != true)
                    .accessibilityIdentifier("applyInclination")
                Text(
                    "Inclinación anunciada: \(range.minimum.formatted())–\(range.maximum.formatted()) %; incremento \(range.increment.formatted()). Aceptación FTMS y medición se registran por separado."
                )
                .font(.footnote)
            }
            Text(
                "Preparar → solicitar permiso → probar Parar → esperar 0 km/h → probar inicio. Para cambiar velocidad, espera datos recientes en movimiento. No se aplican objetivos automáticamente al iniciar."
            )
            .font(.footnote).foregroundStyle(Color.primary)
        }
    }

    private var fitShowActions: some View {
        Section("Exploración FitShow") {
            Text(
                "Canal: \(evidence.selectedProtocol.writeUUID) escritura / \(evidence.selectedProtocol.notifyUUID) notificaciones."
            )
            .font(.footnote.monospaced()).foregroundStyle(Color.primary)
            Button("Escuchar canal") { explorer.listenFitShow() }.frame(minHeight: 44)
                .disabled(
                    !connected || evidence.fitShow.contains { $0.channel == evidence.selectedProtocol }
                )
                .accessibilityIdentifier("listenFitShow")
            Button("Consultar rango de velocidad") { explorer.queryFitShowRange() }.frame(minHeight: 44)
                .disabled(!canQueryFitShow)
            Text(
                "Estado: se observa desde los mensajes recibidos; no se envía la consulta 51, asociada a un corte en la captura anterior."
            ).foregroundStyle(Color.primary)
            if let status = evidence.fitShow.first(where: { $0.channel == evidence.selectedProtocol })?
                .machineStatusRaw
            {
                valueRow("Último código de estado recibido", value: String(status))
            }
            if explorer.fitShowQueryPending { ProgressView("Esperando respuesta; no se reintentará.") }
            Text(
                "Solo se consulta el rango. El estado se escucha de forma pasiva. No hay inicialización de usuario, sondeo ni reintentos automáticos. Un timeout no demuestra incompatibilidad."
            )
            .font(.footnote).foregroundStyle(Color.primary)
            Label("Control propietario bloqueado · compatibilidad pendiente", systemImage: "lock.fill")
                .foregroundStyle(Color.primary)
        }
    }

    private var comparisonSection: some View {
        Section("Registro comparativo") {
            valueRow("FTMS · muestras válidas", value: String(device?.telemetry?.validSampleCount ?? 0))
            ForEach(evidence.fitShow) { channel in
                VStack(alignment: .leading, spacing: 8) {
                    Text(channel.channel.title).font(.headline)
                    valueRow("Escucha", value: channel.subscriptionStatus)
                    valueRow(
                        "Tramas válidas / reconocidas",
                        value: "\(channel.validFrameCount) / \(channel.recognizedFrameCount)")
                    Text(
                        channel.compatibility == "messagesRecognizedUnitsUnconfirmed"
                            ? "Rango y estado reconocidos; unidades sin confirmar."
                            : channel.recognizedFrameCount > 0
                                ? "Mensajes parcialmente reconocidos; variante pendiente."
                                : "Todavía no hay mensajes reconocidos.")
                    if let speed = channel.speedTenthsRaw {
                        valueRow(
                            "Velocidad cruda ÷ 10",
                            value: "\((Double(speed) / 10).formatted()) · unidad pendiente")
                    }
                    if let distance = channel.distanceCounterRaw {
                        valueRow("Contador de distancia crudo", value: String(distance))
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("fitShowDistanceRaw")
                    }
                    if let at = channel.statusReceivedAt {
                        Text("Estado recibido: \(at.formatted(date: .omitted, time: .standard))").font(.caption)
                    }
                    if let at = channel.metricReceivedAt {
                        Text("Campos crudos recibidos: \(at.formatted(date: .omitted, time: .standard))").font(
                            .caption)
                    }
                    if let at = channel.lastReceivedAt {
                        Text("Último paquete: \(at.formatted(date: .omitted, time: .standard))").font(.caption)
                    }
                    if let error = channel.lastError { Text(error).font(.footnote) }
                    if let bytes = channel.lastHex {
                        Text(bytes).font(.footnote.monospaced()).textSelection(.enabled)
                    }
                }.foregroundStyle(Color.primary).padding(.vertical, 4)
            }
            if evidence.fitShow.isEmpty {
                Text("Selecciona un canal FitShow y activa su escucha para compararlo con FTMS.")
                    .foregroundStyle(Color.primary)
            }
            Text(
                "Se conservan fuentes y timestamps por separado. Reconocer un mensaje no verifica unidades, control ni calibración física."
            ).font(.footnote).foregroundStyle(Color.primary)
        }
    }

    private func valueRow(_ title: String, value: String) -> some View {
        LabeledContent(title) { Text(value).foregroundStyle(Color.primary) }
    }

    private func resultTitle(_ result: String) -> String {
        switch result {
        case "acceptedByProtocol": "Aceptado por protocolo"
        case "rejectedByProtocol": "Rechazado por protocolo"
        case "indeterminate": "Indeterminado"
        case "supersededByExplicitStop": "Interrumpido por parada explícita"
        default: "Pendiente"
        }
    }
}
