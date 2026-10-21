import FitnessCore
import FitnessRuntime
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(PhoneWatchService.self) private var watch
    @Bindable var coordinator: WorkoutCoordinator
    let showMessage: (String) -> Void
    #if DEBUG
        var diagnosticFixtureControl: ((Bool) -> Void)? = nil
        @State private var diagnosticFixtureRunning = false
    #endif
    @State private var showClear = false
    @State private var diagnosticExport: DiagnosticExport?
    @State private var showDiagnosticExportOptions = false
    @State private var diagnosticWriteState = String(localized: "Al día", bundle: .main)
    @State private var statusClock = Date()

    private var watchStatusProjection: WatchStatusProjection {
        WatchStatusProjection(watch: watch, now: statusClock)
    }

    var body: some View {
        Form {
            Section(String(localized: "Equipo", bundle: .main)) {
                NavigationLink {
                    DeviceSettingsView(coordinator: coordinator)
                } label: {
                    LabeledContent(
                        String(localized: "Conexión del equipo", bundle: .main), value: deviceStatus)
                }.accessibilityIdentifier("settings-device")
                NavigationLink {
                    WatchSetupView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Apple Watch")
                            Text(watchStatus)
                                .font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
                        }
                    } icon: {
                        Image(systemName: "applewatch").foregroundStyle(FitnessPalette.accent)
                    }
                }.accessibilityIdentifier("settings-watch")
                if watch.isPaired {
                    LabeledContent(
                        String(localized: "Mensajería inmediata", bundle: .main),
                        value: watch.isReachable
                            ? String(localized: "Disponible", bundle: .main)
                            : String(localized: "Sin enlace ahora", bundle: .main))
                    LabeledContent(
                        String(localized: "Sesión de Salud", bundle: .main),
                        value: watch.mirrored
                            ? String(localized: "Reflejada", bundle: .main)
                            : String(localized: "Sin sesión reflejada", bundle: .main))
                    LabeledContent(
                        String(localized: "Captura de Salud", bundle: .main),
                        value: watchStatusProjection.captureTitle)
                }
                LabeledContent("Unidades", value: String(localized: "km · km/h · %", bundle: .main))
                Toggle(
                    String(localized: "Modo de demostración", bundle: .main),
                    isOn: Binding(get: { coordinator.mockMode }, set: { coordinator.setMockMode($0) })
                )
                .disabled(!coordinator.canClearHistory)
                .accessibilityIdentifier("settings-mock-mode")
                Toggle(
                    String(localized: "Métricas de ejemplo", bundle: .main),
                    isOn: Binding(
                        get: { coordinator.mockMetricsEnabled }, set: { coordinator.setMockMetricsEnabled($0) })
                )
                .accessibilityIdentifier("settings-mock-metrics")
                Text(
                    String(
                        localized:
                            "El modo de demostración de caminadora y las métricas de ejemplo son ajustes independientes. Los datos simulados siempre se identifican; habilitarlos no inicia Bluetooth.",
                        bundle: .main)
                ).font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
            }
            Section {
                LabeledContent(
                    String(localized: "Almacenamiento", bundle: .main),
                    value: String(localized: "Solo en este dispositivo", bundle: .main))
                LabeledContent(
                    String(localized: "Registro diagnóstico", bundle: .main), value: diagnosticWriteState
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Registro diagnóstico", bundle: .main))
                .accessibilityValue(diagnosticWriteState)
                .accessibilityIdentifier("settings-write-state")
                #if DEBUG
                    if let diagnosticFixtureControl,
                        ProcessInfo.processInfo.arguments.contains("--ui-test-settings-writes-4hz")
                    {
                        Button(
                            diagnosticFixtureRunning
                                ? String(localized: "Detener carga sintética", bundle: .main)
                                : String(localized: "Iniciar carga sintética", bundle: .main)
                        ) {
                            diagnosticFixtureRunning.toggle()
                            diagnosticFixtureControl(diagnosticFixtureRunning)
                        }
                        .accessibilityIdentifier("settings-toggle-diagnostic-fixture")
                    }
                #endif
                if let persistenceError = coordinator.store.persistenceError {
                    Text(
                        String(localized: "Error al guardar el diagnóstico: \(persistenceError)", bundle: .main)
                    )
                    .font(FitnessType.body(.footnote)).foregroundStyle(.red)
                }
                Button {
                    showDiagnosticExportOptions = true
                } label: {
                    Label(
                        String(localized: "Exportar diagnóstico ZIP", bundle: .main),
                        systemImage: "square.and.arrow.up")
                }
                .disabled(coordinator.store.session == nil)
                .accessibilityIdentifier("settings-export-diagnostic")
                Button(String(localized: "Borrar historial…", bundle: .main), role: .destructive) {
                    showClear = true
                }
                .disabled(!coordinator.canClearHistory)
                .accessibilityIdentifier("clear-app-data")
            } header: {
                Text(String(localized: "Tus datos", bundle: .main))
            } footer: {
                Text(
                    String(
                        localized:
                            "El historial de entrenamientos se borra del dispositivo. Los programas, el equipo recordado y los límites guardados permanecen. No está disponible mientras una sesión permanece activa.",
                        bundle: .main))
            }
            Section(String(localized: "Acerca de", bundle: .main)) {
                HStack(spacing: 12) {
                    Image("FitnessMark").resizable().scaledToFit().frame(width: 38, height: 38)
                        .accessibilityHidden(true)
                    Text("VAGANCIA FITNESS").font(FitnessType.title(18, relativeTo: .headline))
                }
                LabeledContent(
                    String(localized: "Versión", bundle: .main),
                    value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.6.0")
                Text(
                    String(
                        localized: "Una propuesta independiente para entrenar con más claridad y control.",
                        bundle: .main)
                ).font(FitnessType.body(.subheadline))
                Text(String(localized: "Sin afiliación con FitShow ni Apple.", bundle: .main)).font(
                    FitnessType.body(.caption)
                ).foregroundStyle(FitnessPalette.secondary)
            }
        }
        .fitnessSurface()
        .navigationTitle(String(localized: "Ajustes", bundle: .main))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                diagnosticWriteState =
                    coordinator.store.pendingEventCount > 0
                    ? String(localized: "Guardando", bundle: .main)
                    : String(localized: "Al día", bundle: .main)
                statusClock = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onDisappear {
            #if DEBUG
                if diagnosticFixtureRunning {
                    diagnosticFixtureRunning = false
                    diagnosticFixtureControl?(false)
                }
            #endif
        }
        .confirmationDialog(
            String(localized: "¿Borrar el historial?", bundle: .main), isPresented: $showClear,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Borrar historial", bundle: .main), role: .destructive) {
                clearData()
            }
            Button(String(localized: "Cancelar", bundle: .main), role: .cancel) {}
        } message: {
            Text(String(localized: "Esta acción no se puede deshacer.", bundle: .main))
        }
        .confirmationDialog(
            String(localized: "Perfil de exportación", bundle: .main),
            isPresented: $showDiagnosticExportOptions, titleVisibility: .visible
        ) {
            Button(String(localized: "Exportación completa", bundle: .main)) {
                Task { await exportDiagnostic(profile: .complete) }
            }
            .accessibilityIdentifier("export-diagnostic-complete")
            Button(String(localized: "Soporte público", bundle: .main)) {
                Task { await exportDiagnostic(profile: .publicSupport) }
            }
            .accessibilityIdentifier("export-diagnostic-public")
            Button(String(localized: "Cancelar", bundle: .main), role: .cancel) {}
        } message: {
            Text(
                String(
                    localized:
                        "La exportación completa incluye el registro original. Soporte público omite notas, identidad, Salud y cargas útiles desconocidas.",
                    bundle: .main))
        }
        .sheet(item: $diagnosticExport) { export in
            WorkoutSystemShareSheet(url: export.archiveURL, identifier: "share-diagnostic-zip")
                .accessibilityIdentifier("share-diagnostic-zip")
        }
    }

    private var deviceStatus: String {
        switch coordinator.bluetooth.phase {
        case .connecting, .discovering, .disconnecting, .scanning:
            return coordinator.bluetooth.phase.title
        case .failed:
            return String(localized: "Falló la conexión", bundle: .main)
        case .ready:
            let name =
                coordinator.bluetooth.rememberedTreadmill?.name
                ?? String(localized: "Conectado", bundle: .main)
            return coordinator.bluetooth.selectedProtocol == .ftms
                ? String(localized: "\(name) · FTMS listo", bundle: .main) : name
        default:
            return coordinator.bluetooth.rememberedTreadmill != nil
                ? String(localized: "Equipo recordado", bundle: .main)
                : String(localized: "Sin conexión", bundle: .main)
        }
    }
    private var watchStatus: String {
        guard watch.isPaired else {
            return String(localized: "Configurar pulso y Salud", bundle: .main)
        }
        guard watch.isInstalled else {
            return String(localized: "Instalar app complementaria", bundle: .main)
        }
        if watchStatusProjection.captureConfirmed {
            return String(localized: "Captura de Salud confirmada", bundle: .main)
        }
        if watch.mirrored { return String(localized: "Sesión de Salud reflejada", bundle: .main) }
        if watch.isReachable {
            return String(localized: "Mensajería inmediata disponible", bundle: .main)
        }
        return String(localized: "Instalada · sin mensajería inmediata", bundle: .main)
    }
    private func clearData() {
        do {
            try coordinator.clearHistory()
            coordinator.refresh()
            showMessage(String(localized: "Se borró el historial local.", bundle: .main))
        } catch {
            showMessage(
                String(
                    localized: "No se pudieron borrar los datos: \(error.localizedDescription)", bundle: .main
                ))
        }
    }
    @MainActor private func exportDiagnostic(profile: DiagnosticExportProfile) async {
        do {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.8.0"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "13"
            let metadata = AppMetadata(
                version: version, build: build,
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                deviceModel: UIDevice.current.model)
            diagnosticExport = try await coordinator.exportDiagnostic(
                metadata: metadata, profile: profile)
        } catch {
            showMessage(
                String(
                    localized: "No se pudo exportar el diagnóstico: \(error.localizedDescription)",
                    bundle: .main))
        }
    }
}

struct DeviceSettingsView: View {
    @Bindable var coordinator: WorkoutCoordinator
    @State private var remember = true
    @State private var showForget = false

    var body: some View {
        Form {
            Section(String(localized: "Equipo recordado", bundle: .main)) {
                if let remembered = coordinator.bluetooth.rememberedTreadmill {
                    LabeledContent(
                        String(localized: "Nombre", bundle: .main),
                        value: remembered.name ?? String(localized: "Caminadora", bundle: .main))
                    LabeledContent("Identificador", value: remembered.identifier.uuidString)
                    Toggle(
                        String(localized: "Conectar al abrir la app", bundle: .main),
                        isOn: Binding(
                            get: { remembered.connectOnOpen }, set: { coordinator.setConnectOnOpen($0) })
                    )
                    .accessibilityIdentifier("connect-on-open")
                    Button {
                        coordinator.connectRemembered()
                    } label: {
                        Label(
                            String(localized: "Conectar al equipo recordado", bundle: .main),
                            systemImage: "bolt.horizontal.circle")
                    }
                    .disabled(coordinator.bluetooth.hasActivity || coordinator.mockMode)
                    .accessibilityIdentifier("connect-remembered")
                    Button(String(localized: "Olvidar equipo", bundle: .main), role: .destructive) {
                        showForget = true
                    }
                    .disabled(coordinator.bluetooth.hasActivity).accessibilityIdentifier("forget-treadmill")
                } else {
                    Text(String(localized: "Aún no hay un equipo recordado.", bundle: .main)).foregroundStyle(
                        FitnessPalette.secondary)
                }
            }
            Section {
                Toggle(String(localized: "Recordar el equipo seleccionado", bundle: .main), isOn: $remember)
                    .accessibilityIdentifier("remember-selected-device")
                Text(
                    String(
                        localized:
                            "Su identificador se guarda solo para facilitar conexiones futuras. Puedes olvidar el equipo en cualquier momento.",
                        bundle: .main)
                ).font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
                Button {
                    if coordinator.bluetooth.isScanning {
                        coordinator.bluetooth.stopSearch()
                    } else {
                        coordinator.searchDevices(allDevices: false)
                    }
                } label: {
                    Label(
                        coordinator.bluetooth.isScanning
                            ? String(localized: "Detener búsqueda", bundle: .main)
                            : String(localized: "Buscar caminadora", bundle: .main),
                        systemImage: "magnifyingglass")
                }.disabled(
                    (coordinator.bluetooth.hasActivity && !coordinator.bluetooth.isScanning)
                        || coordinator.mockMode
                ).accessibilityIdentifier("search-treadmill")
                ForEach(coordinator.bluetooth.devices) { device in
                    Button {
                        coordinator.connect(device, remember: remember)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.name ?? String(localized: "Equipo Bluetooth", bundle: .main)).font(
                                    FitnessType.body(.subheadline, weight: .semibold))
                                Text(
                                    device.advertisesFTMS
                                        ? String(
                                            localized: "Anuncia FTMS · requiere validar funcionamiento", bundle: .main)
                                        : String(localized: "Sin FTMS anunciado", bundle: .main)
                                ).font(FitnessType.body(.caption)).foregroundStyle(FitnessPalette.secondary)
                            }
                            Spacer()
                            Text(device.rssi.map { String(localized: "\($0) dBm", bundle: .main) } ?? "").font(
                                .caption.monospacedDigit()
                            ).foregroundStyle(FitnessPalette.secondary)
                        }
                    }.disabled(
                        coordinator.mockMode
                            || (!coordinator.bluetooth.isScanning && coordinator.bluetooth.hasActivity)
                    ).accessibilityIdentifier("device-\(device.id.uuidString)")
                }
            } header: {
                Text(
                    coordinator.bluetooth.rememberedTreadmill == nil
                        ? String(localized: "Buscar equipo", bundle: .main)
                        : String(localized: "Buscar otro equipo", bundle: .main))
            }
            Section {
                Text(
                    String(
                        localized:
                            "Ver servicios o recibir FTMS no demuestra que la banda se mueva. Ninguna acción de conexión envía comandos de motor.",
                        bundle: .main))
            }
            if coordinator.bluetooth.hasActivity {
                Section(String(localized: "Estado", bundle: .main)) {
                    LabeledContent(
                        String(localized: "Bluetooth", bundle: .main), value: coordinator.bluetooth.phase.title)
                    if let error = coordinator.bluetooth.errorMessage {
                        Text(error).font(FitnessType.body(.footnote)).foregroundStyle(.red)
                    }
                    if coordinator.bluetooth.hasConnection {
                        Button("Desconectar", role: .destructive) { coordinator.bluetooth.disconnect() }
                    }
                }
            }
        }
        .fitnessSurface()
        .navigationTitle(String(localized: "Tu equipo", bundle: .main))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            String(localized: "¿Olvidar el equipo?", bundle: .main), isPresented: $showForget,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Olvidar equipo", bundle: .main), role: .destructive) {
                coordinator.forgetTreadmill()
            }
            Button(String(localized: "Cancelar", bundle: .main), role: .cancel) {}
        } message: {
            Text(
                String(
                    localized: "Tendrás que buscarlo y seleccionarlo de nuevo para conectarte.", bundle: .main
                ))
        }
        .refreshable { coordinator.refresh() }
    }
}
