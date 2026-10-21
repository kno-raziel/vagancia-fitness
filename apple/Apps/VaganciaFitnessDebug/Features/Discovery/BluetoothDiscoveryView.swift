import FitnessCore
import FitnessRuntime
import SwiftUI

struct BluetoothDiscoveryView: View {
    let explorer: BluetoothExplorer
    let store: SessionStore
    @State private var allDevices = false

    private var inventory: GATTDevice? { store.session?.device }

    var body: some View {
        List {
            Section {
                Text(
                    "Enciende la caminadora y cierra su conexión en FitShow antes de buscar. Selecciona el equipo que quieras explorar."
                )
                .foregroundStyle(Color.primary)
                Text(explorer.radioStatus).font(.footnote).foregroundStyle(Color.primary)
                if let error = explorer.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.primary).accessibilityIdentifier("bluetoothError")
                }
            }

            if let saved = explorer.rememberedTreadmill {
                Section("Mi caminadora") {
                    Text(saved.name ?? "Caminadora guardada").font(.headline)
                    Toggle(
                        "Conectar al abrir la app",
                        isOn: Binding(
                            get: { explorer.rememberedTreadmill?.connectOnOpen ?? false },
                            set: { explorer.setConnectOnOpen($0) })
                    )
                    .accessibilityIdentifier("connectOnOpen")
                    Button("Conectar equipo guardado") { explorer.connectRemembered() }
                        .disabled(explorer.hasActivity)
                    Button("Olvidar caminadora", role: .destructive) { explorer.forgetTreadmill() }
                        .disabled(explorer.hasActivity)
                    Text(
                        "Un intento al abrir; no reconecta tras un corte ni envía órdenes de motor. La conexión crea un registro si no hay uno abierto. Si falla, busca manualmente."
                    ).font(.footnote).foregroundStyle(Color.primary)
                }
            }

            Section {
                LabeledContent("Estado") { Text(explorer.phase.title).foregroundStyle(Color.primary) }
                if explorer.phase == .connecting || explorer.phase == .discovering
                    || explorer.waitingForPermission
                {
                    ProgressView(
                        explorer.waitingForPermission ? "Preparando Bluetooth…" : explorer.phase.title)
                }
                if explorer.hasConnection {
                    Button {
                        explorer.disconnect()
                    } label: {
                        Label(
                            explorer.phase == .connecting ? "Cancelar conexión" : "Desconectar",
                            systemImage: "xmark.circle"
                        ).frame(minHeight: 44)
                    }
                    .disabled(explorer.phase == .disconnecting)
                    .accessibilityIdentifier("disconnectDevice")
                } else {
                    Picker("Buscar", selection: $allDevices) {
                        Text("FTMS").tag(false)
                        Text("Todos").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(explorer.hasActivity)
                    if explorer.isScanning || explorer.waitingForPermission {
                        Button {
                            explorer.stopSearch()
                        } label: {
                            Label("Detener búsqueda", systemImage: "stop.circle").frame(minHeight: 44)
                        }
                    } else {
                        Button {
                            explorer.search(allDevices: allDevices)
                        } label: {
                            Label("Buscar caminadora", systemImage: "antenna.radiowaves.left.and.right").frame(
                                minHeight: 44)
                        }
                        .disabled(!store.storageReady)
                        .accessibilityIdentifier("scanDevices")
                    }
                }
            } header: {
                Text("Conexión")
            } footer: {
                Text(
                    "La búsqueda dura hasta 30 segundos. Si no aparece, elige Todos. Al buscar se inicia un registro si no hay una sesión abierta."
                ).foregroundStyle(Color.primary)
            }

            if inventory != nil {
                Section {
                    NavigationLink {
                        LiveDashboardView(explorer: explorer, store: store)
                    } label: {
                        Label("Panel y protocolos", systemImage: "slider.horizontal.3").frame(minHeight: 44)
                    }.accessibilityIdentifier("openLivePanel")
                }
            }

            if let inventory, inventory.containsFTMS {
                FTMSTelemetrySection(
                    device: inventory, connected: explorer.phase == .ready,
                    distanceProgress: store.session?.distanceProgress)
                Section {
                    NavigationLink {
                        FTMSDiagnosticsView(store: store)
                    } label: {
                        Label("Ver capacidades y rangos", systemImage: "list.bullet.rectangle").frame(
                            minHeight: 44)
                    }
                    .accessibilityIdentifier("openFTMSCapabilities")
                }
            }

            if !explorer.hasConnection {
                Section("Dispositivos encontrados · \(explorer.devices.count)") {
                    if explorer.devices.isEmpty {
                        Text(
                            explorer.isScanning
                                ? "Buscando cerca de ti…" : "Todavía no hay dispositivos. Pulsa Buscar caminadora."
                        ).foregroundStyle(Color.primary)
                    }
                    ForEach(explorer.devices) { device in
                        Button {
                            explorer.connect(device)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name ?? "Dispositivo sin nombre").font(.headline)
                                Text(device.advertisesFTMS ? "Anuncia FTMS" : "Protocolo por identificar").font(
                                    .subheadline)
                                Text(device.rssi.map { "Señal: \($0) dBm" } ?? "Señal no disponible").font(.caption)
                                Text(device.id.uuidString).font(.caption).textSelection(.enabled)
                                if !device.connectable { Text("No admite conexión en este anuncio").font(.caption) }
                            }
                            .foregroundStyle(Color.primary).padding(.vertical, 4)
                        }
                        .disabled(!device.connectable)
                    }
                }
            }

            if let inventory {
                Section {
                    if inventory.source == .synthetic {
                        Label("Inventario sintético · sin hardware", systemImage: "testtube.2").foregroundStyle(
                            Color.primary)
                    }
                    Text(inventory.advertisedName ?? "Dispositivo sin nombre").font(.headline)
                    LabeledContent("Servicios") {
                        Text("\(inventory.services.count)").foregroundStyle(Color.primary)
                    }
                    LabeledContent("Características") {
                        Text("\(inventory.characteristicCount)").foregroundStyle(Color.primary)
                    }
                    LabeledContent("FTMS") {
                        Text(inventory.containsFTMS ? "Servicio presente" : "No observado").foregroundStyle(
                            Color.primary)
                    }
                    LabeledContent("Exploración") {
                        Text(discoveryLabel(inventory.discoveryStatus)).foregroundStyle(Color.primary)
                    }
                    if let manufacturer = inventory.manufacturer {
                        LabeledContent("Fabricante") { Text(manufacturer).foregroundStyle(Color.primary) }
                    }
                    if let model = inventory.moduleModel {
                        LabeledContent("Modelo del módulo") { Text(model).foregroundStyle(Color.primary) }
                    }
                    if let firmware = inventory.firmware {
                        LabeledContent("Firmware") { Text(firmware).foregroundStyle(Color.primary) }
                    }
                    ForEach(inventory.services) { service in
                        NavigationLink {
                            GATTServiceView(service: service)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(GATTNames.name(service.uuid)).font(.headline)
                                if GATTNames.name(service.uuid) != service.uuid {
                                    Text(service.uuid).font(.caption)
                                }
                                Text(
                                    "\(service.characteristics.count) características · \(discoveryLabel(service.characteristicDiscovery))"
                                ).font(.subheadline)
                            }
                            .foregroundStyle(Color.primary).padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text(explorer.hasConnection ? "Inventario del equipo" : "Último inventario guardado")
                } footer: {
                    Text(
                        "Un servicio presente no confirma funciones físicas. Las pruebas de movimiento FTMS se preparan desde Panel y protocolos; FitShow permanece en exploración."
                    ).foregroundStyle(Color.primary)
                }
            }
        }
        .navigationTitle("Caminadora")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct GATTServiceView: View {
    let service: GATTService
    var body: some View {
        List {
            Section("Servicio") {
                Text(service.uuid).font(.footnote.monospaced()).textSelection(.enabled)
                LabeledContent("Tipo") {
                    Text(service.isPrimary ? "Primario" : "Secundario").foregroundStyle(Color.primary)
                }
                LabeledContent("Exploración") {
                    Text(discoveryLabel(service.characteristicDiscovery)).foregroundStyle(Color.primary)
                }
                if let error = service.error { Text(error.message).foregroundStyle(Color.primary) }
            }
            ForEach(service.characteristics) { characteristic in
                Section(GATTNames.name(characteristic.uuid)) {
                    Text(characteristic.uuid).font(.footnote.monospaced()).textSelection(.enabled)
                    Text(
                        characteristic.properties.isEmpty
                            ? "Sin propiedades declaradas" : characteristic.properties.joined(separator: ", ")
                    )
                    .font(.subheadline).foregroundStyle(Color.primary)
                    if let value = characteristic.textValue { Text(value).textSelection(.enabled) }
                    if let hex = characteristic.valueHex {
                        Text("Bytes: \(hex)").font(.footnote.monospaced()).textSelection(.enabled)
                    }
                    if let status = characteristic.readStatus {
                        LabeledContent("Lectura") {
                            Text(discoveryLabel(status)).foregroundStyle(Color.primary)
                        }
                    }
                    if let error = characteristic.readError {
                        Text(error.message).foregroundStyle(Color.primary)
                    }
                    if let error = characteristic.decodeError { Text(error).foregroundStyle(Color.primary) }
                    LabeledContent("Descriptores") {
                        Text(discoveryLabel(characteristic.descriptorDiscovery)).foregroundStyle(Color.primary)
                    }
                    if let error = characteristic.error { Text(error.message).foregroundStyle(Color.primary) }
                    ForEach(characteristic.descriptors) { descriptor in
                        Text(descriptor.uuid).font(.footnote.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle(GATTNames.name(service.uuid))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private func discoveryLabel(_ status: String) -> String {
    switch status {
    case "complete": "Completa"
    case "partial": "Parcial"
    case "failed": "Falló"
    case "timedOut": "Tiempo agotado"
    case "interrupted": "Interrumpida"
    case "invalidated": "Servicios cambiaron"
    default: "Pendiente"
    }
}
