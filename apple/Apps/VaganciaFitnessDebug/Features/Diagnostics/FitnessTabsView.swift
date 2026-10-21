import Charts
import FitnessCore
import FitnessRuntime
import SwiftUI

// Direction: native iOS26 Liquid Glass for navigation and actions, readable
// metric content underneath. Standard components adapt on iOS18–25 as well.
struct FitnessTabsView: View {
    let store: SessionStore
    let explorer: BluetoothExplorer
    let metadata: AppMetadata
    @State private var selection =
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
            && !ProcessInfo.processInfo.arguments.contains("--start-on-live") ? 2 : 0
    @State private var lifecycleError: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selection) {
            Tab("Sesión", systemImage: "figure.walk", value: 0) {
                NavigationStack {
                    FitnessDashboard(store: store, explorer: explorer, openEquipment: { selection = 1 })
                }
            }
            Tab("Equipo", systemImage: "sensor", value: 1) {
                NavigationStack { BluetoothDiscoveryView(explorer: explorer, store: store) }.safeAreaInset(
                    edge: .bottom, spacing: 0
                ) { connectionStop }
            }
            Tab("Registro", systemImage: "list.bullet.rectangle", value: 2) {
                SessionView(store: store, bluetooth: explorer, metadata: metadata)
                    .safeAreaInset(edge: .bottom, spacing: 0) { connectionStop }
            }
        }
        .tint(.blue)
        .preferredColorScheme(
            ProcessInfo.processInfo.arguments.contains("--ui-testing")
                && ProcessInfo.processInfo.arguments.contains("--ui-testing-dark") ? .dark : nil
        )
        .task { explorer.autoConnectIfEnabled() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { explorer.backgrounded() }
            do {
                if phase == .background {
                    try store.recordLifecycle("background")
                } else if phase == .active {
                    try store.recordLifecycle("active")
                    explorer.autoConnectIfEnabled()
                }
            } catch { lifecycleError = error.localizedDescription }
        }
        .alert(
            "No se pudo guardar el estado",
            isPresented: Binding(get: { lifecycleError != nil }, set: { if !$0 { lifecycleError = nil } })
        ) {
            Button("Aceptar", role: .cancel) { lifecycleError = nil }
        } message: {
            Text(lifecycleError ?? "")
        }
    }

    @ViewBuilder private var connectionStop: some View {
        if explorer.hasConnection {
            VStack(spacing: 6) {
                StopBeltControl(explorer: explorer)
                Text("Ante emergencia, usa la consola física.").font(.caption).foregroundStyle(.secondary)
            }.modifier(NativeControlRail())
        }
    }
}

private struct FitnessDashboard: View {
    let store: SessionStore
    let explorer: BluetoothExplorer
    let openEquipment: () -> Void
    @State private var showingControl = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var speedSize = 88
    private var device: GATTDevice? { store.session?.device }
    private var connected: Bool { explorer.phase == .ready }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if device?.source == .synthetic {
                    Label("Datos sintéticos · sin hardware", systemImage: "testtube.2").font(.footnote)
                }
                if let error = explorer.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.primary)
                }
                if let device {
                    Label(
                        "\(device.advertisedName ?? "Caminadora") · \(connected ? "Conectada" : "Sin conexión")",
                        systemImage: "antenna.radiowaves.left.and.right"
                    )
                    .font(.subheadline).foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 28) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Velocidad informada").font(.headline)
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(
                                        device.telemetry?.speed.map {
                                            $0.value.formatted(.number.precision(.fractionLength(1...2)))
                                        } ?? "—"
                                    )
                                    .font(.system(size: speedSize, weight: .semibold, design: .rounded))
                                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.35)
                                    .accessibilityIdentifier("dashboardSpeed")
                                    Text("km/h").font(.title2).foregroundStyle(.secondary)
                                }
                                freshness(device.telemetry?.speed, at: context.date)
                            }
                            let layout =
                                typeSize.isAccessibilitySize
                                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                                : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                            layout {
                                distance(
                                    "Registrada en sesión", value: store.session?.distanceProgress?.metric,
                                    at: context.date, id: "dashboardSessionDistance")
                                distance(
                                    "Contador del equipo", value: device.telemetry?.distance, at: context.date,
                                    id: "dashboardCounter")
                            }
                        }
                    }
                    if let reception = device.reception, connected,
                        reception.streams.contains(where: \.silent)
                    {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Sin datos recientes", systemImage: "exclamationmark.triangle").font(.headline)
                            Text(
                                "\(reception.streams.filter(\.silent).map(\.channel).joined(separator: ", ")): más de 5 segundos sin mensajes. La conexión puede seguir activa."
                            )
                            Text("Si hay movimiento, usa la consola física. Después reconecta manualmente.").font(
                                .footnote)
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Velocidad recibida").font(.headline)
                        if explorer.livePoints.isEmpty {
                            Text("La gráfica aparecerá al recibir datos en esta conexión.").foregroundStyle(
                                .secondary)
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
                            .frame(height: 140).accessibilityLabel(
                                "Velocidad informada por FTMS, últimas muestras")
                        }
                        Text(
                            "La distancia de sesión conserva incrementos observados cuando el contador vuelve a cero. No estima lo recorrido durante cortes."
                        ).font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView(
                        "Tu caminadora, en vivo", systemImage: "figure.walk",
                        description: Text("Conecta el equipo para ver su velocidad y registrar distancia."))
                }
                if !connected {
                    Button {
                        if explorer.rememberedTreadmill != nil {
                            explorer.connectRemembered()
                        } else {
                            openEquipment()
                        }
                    } label: {
                        Label(
                            explorer.hasActivity ? "Conectando…" : "Conectar caminadora",
                            systemImage: "antenna.radiowaves.left.and.right"
                        ).frame(minHeight: 44)
                    }
                    .modifier(NativeGlassAction(prominent: true)).disabled(
                        explorer.hasActivity || !store.storageReady
                    ).accessibilityIdentifier("dashboardConnect")
                }
            }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 20)
        }
        .accessibilityIdentifier("liveMetricScroll")
        .navigationTitle("Sesión")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Mi caminadora", systemImage: "gearshape", action: openEquipment)
            }
            if typeSize.isAccessibilitySize {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Control FTMS", systemImage: "slider.horizontal.3") { showingControl = true }
                        .disabled(device == nil).accessibilityIdentifier("openNativeControl")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    if !typeSize.isAccessibilitySize {
                        Button("Control FTMS", systemImage: "slider.horizontal.3") { showingControl = true }
                            .modifier(NativeGlassAction(prominent: false)).disabled(device == nil)
                            .accessibilityIdentifier("openNativeControl")
                    }
                    StopBeltControl(explorer: explorer)
                }
                Text(
                    typeSize.isAccessibilitySize
                        ? "Emergencia: consola física." : "Ante emergencia, usa la llave o consola física."
                ).font(.caption).foregroundStyle(.secondary)
            }.modifier(NativeControlRail())
        }
        .sheet(isPresented: $showingControl) {
            NativeFTMSControlSheet(store: store, explorer: explorer)
        }
    }

    private func distance(_ title: String, value: FTMSMetric?, at date: Date, id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value.map { "\($0.value.formatted()) m" } ?? "Sin datos").font(.title2.bold())
                .monospacedDigit().accessibilityIdentifier(id)
            freshness(value, at: date)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func freshness(_ metric: FTMSMetric?, at date: Date) -> some View {
        if let metric {
            Text(
                !connected
                    ? "Último dato · desconectado"
                    : metric.isStale(at: date) ? "Dato desactualizado" : "Dato reciente"
            )
            .font(.footnote).foregroundStyle(.secondary)
            Text(metric.receivedAt, format: .dateTime.hour().minute().second()).font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Sin datos recibidos").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct StopBeltControl: View {
    let explorer: BluetoothExplorer
    var identifier = "nativeStopBelt"
    @Environment(\.dynamicTypeSize) private var typeSize
    private var disabled: Bool {
        let control = explorer.control
        return explorer.phase != .ready || explorer.selectedProtocol != .ftms || !control.canStop
            || control.pending?.action == .stop
            || (control.requiresReconnect && control.last?.action == .stop)
    }
    var body: some View {
        Button(
            typeSize.isAccessibilitySize ? "Parar" : "Parar banda", systemImage: "stop.fill",
            role: .destructive
        ) { explorer.execute(.stop) }
        .modifier(NativeGlassAction(prominent: true)).tint(.red).disabled(disabled).accessibilityLabel(
            "Parar banda"
        ).accessibilityIdentifier(identifier)
    }
}

// A full-width native bar keeps the warning readable while content scrolls
// underneath; safeAreaInset reserves the rail's measured Dynamic Type height.
private struct NativeControlRail: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
    }
}

private struct NativeGlassAction: ViewModifier {
    let prominent: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent).controlSize(.large)
            } else {
                content.buttonStyle(.glass).controlSize(.large)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                content.buttonStyle(.bordered).controlSize(.large)
            }
        }
    }
}

private struct NativeFTMSControlSheet: View {
    let store: SessionStore
    let explorer: BluetoothExplorer
    @State private var targetSpeed = 0.8
    @State private var confirmation: FTMSAction?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    private var connected: Bool { explorer.phase == .ready && explorer.selectedProtocol == .ftms }
    private var control: FTMSControl { explorer.control }
    private var speed: FTMSMetric? { store.session?.device?.telemetry?.speed }
    private var canStart: Bool {
        connected && scenePhase == .active && control.canStart && speed?.value == 0
            && speed?.isStale(at: Date()) == false
    }
    private var canSetSpeed: Bool {
        connected && scenePhase == .active && control.canStop && control.stopAccepted
            && !control.movementUncertain && !control.requiresReconnect && control.pending == nil
            && store.session?.device?.speedControlAdvertised == true
            && speed?.isStale(at: Date()) == false && (speed?.value ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                if store.session?.device?.source == .synthetic {
                    Section { Label("Datos sintéticos · sin hardware", systemImage: "testtube.2") }
                }
                Section("Preparación") {
                    Text(control.message)
                    if let error = explorer.errorMessage { Text(error) }
                    if explorer.selectedProtocol != .ftms {
                        Button("Usar FTMS") { explorer.selectProtocol(.ftms) }.disabled(
                            explorer.phase != .ready || !control.canSelectProtocol)
                    }
                    if !control.indicationReady {
                        Button("Preparar canal de control") { explorer.prepareControl() }.disabled(
                            !connected || control.requiresReconnect
                        ).accessibilityIdentifier("nativePrepareControl")
                    } else if !control.permission {
                        Button("Solicitar permiso FTMS") { explorer.execute(.requestControl) }.disabled(
                            !connected || control.pending != nil || control.requiresReconnect)
                    }
                    LabeledContent(
                        "Parada",
                        value: control.stopAccepted ? "Aceptada por FTMS" : "Prueba Parar antes de iniciar")
                    Text(
                        "Una respuesta aceptada no verifica ejecución física. Si el resultado es incierto, usa la consola y reconecta manualmente."
                    ).font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("Probar inicio…", systemImage: "play.fill") { confirmation = .start }.disabled(
                        !canStart
                    ).foregroundStyle(canStart ? Color.accentColor : Color.secondary).accessibilityIdentifier(
                        "nativeStartBelt")
                } footer: {
                    Text("Requiere parada aceptada y una velocidad reciente de cero.")
                }
                if let range = store.session?.device?.speedRange {
                    Section("Velocidad objetivo") {
                        Stepper(value: $targetSpeed, in: range.minimum...range.maximum, step: range.increment) {
                            Text("\(targetSpeed.formatted(.number.precision(.fractionLength(1...2)))) km/h").font(
                                .title2
                            ).monospacedDigit()
                        }.disabled(!canSetSpeed).opacity(canSetSpeed ? 1 : 0.5)
                        Text(
                            "Rango anunciado: \(range.minimum.formatted())–\(range.maximum.formatted()) km/h. Incremento: \(range.increment.formatted())."
                        ).font(.footnote).foregroundStyle(.secondary)
                        Button("Aplicar velocidad…") { confirmation = .speed }.disabled(!canSetSpeed)
                            .accessibilityIdentifier("nativeApplySpeed")
                    }
                }
            }
            .navigationTitle("Control FTMS").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar", systemImage: "xmark") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    StopBeltControl(explorer: explorer, identifier: "nativeSheetStopBelt")
                    Text(
                        typeSize.isAccessibilitySize
                            ? "Emergencia: consola física." : "La parada Bluetooth no es un paro de emergencia."
                    ).font(.caption).foregroundStyle(.secondary)
                }.modifier(NativeControlRail())
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
                    Button("Aplicar \(targetSpeed.formatted()) km/h") {
                        explorer.execute(.speed, speed: targetSpeed)
                        confirmation = nil
                    }
                }
                Button("Cancelar", role: .cancel) { confirmation = nil }
            } message: {
                Text(
                    "Acción explícita. Mantén accesibles los controles físicos. No hay reintentos automáticos."
                )
            }
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .onAppear {
            if let minimum = store.session?.device?.speedRange?.minimum { targetSpeed = minimum }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { confirmation = nil } }
    }
}
