import FitnessCore
import FitnessRuntime
import SwiftUI

struct FTMSTelemetrySection: View {
    let device: GATTDevice
    let connected: Bool
    var distanceProgress: FTMSDistanceProgress? = nil

    var body: some View {
        Section {
            if device.source == .synthetic {
                Label("Datos sintéticos · sin hardware", systemImage: "testtube.2").foregroundStyle(
                    Color.primary)
            }
            if let telemetry = device.telemetry {
                Text(subscriptionTitle(telemetry.subscriptionStatus)).font(.headline).foregroundStyle(
                    Color.primary)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 12) {
                        metric(
                            "Velocidad", telemetry.speed, at: context.date, active: connected, id: "speedMetric")
                        metric(
                            "Contador del equipo", telemetry.distance, at: context.date, active: connected,
                            id: "distanceMetric")
                        metric(
                            "Distancia registrada en sesión", distanceProgress?.metric, at: context.date,
                            active: connected, id: "sessionDistanceMetric")
                    }
                }
                LabeledContent("Paquetes válidos") {
                    Text("\(telemetry.validSampleCount)").foregroundStyle(Color.primary)
                }
                if let error = telemetry.lastDecodeError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(
                        Color.primary)
                }
                if let error = telemetry.error { Text(error.message).foregroundStyle(Color.primary) }
                if telemetry.notificationCount == 0 {
                    Text(
                        "Aún no llegaron datos. La caminadora puede transmitir solo al usar su consola física."
                    ).foregroundStyle(Color.primary)
                }
            } else {
                Text("Sin datos recibidos").foregroundStyle(Color.primary)
                Text(
                    "La suscripción se prepara al terminar la exploración si existe Treadmill Data con notificaciones."
                ).font(.footnote).foregroundStyle(Color.primary)
            }
        } header: {
            Text("Telemetría FTMS")
        } footer: {
            Text(
                "El contador es el valor original. La distancia de sesión suma incrementos observados desde el primer dato y conserva lo registrado al volver a cero; no estima distancia durante cortes. Datos de más de 5 segundos: desactualizados."
            ).foregroundStyle(Color.primary)
            if let progress = distanceProgress {
                Text(
                    "Reinicios a cero: \(progress.zeroResetCount). Discontinuidades: \(progress.discontinuityCount). La distancia registrada puede ser menor que la recorrida si faltaron datos."
                ).foregroundStyle(Color.primary)
            }
        }
    }

    private func metric(
        _ title: String, _ metric: FTMSMetric?, at date: Date, active: Bool, id: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                Text(
                    metric.map {
                        "\($0.value.formatted(.number.precision(.fractionLength(0...2)))) \($0.unit)"
                    } ?? "Sin datos"
                )
                .foregroundStyle(Color.primary).monospacedDigit()
            }
            .accessibilityIdentifier(id)
            if let metric {
                Text(
                    !active
                        ? "Último dato · desconectado"
                        : metric.isStale(at: date) ? "Dato desactualizado" : "Dato reciente"
                )
                .font(.footnote).foregroundStyle(Color.primary)
                Text("Recibido: \(metric.receivedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(Color.primary)
            }
        }
    }

    private func subscriptionTitle(_ state: String) -> String {
        switch state {
        case "active": "Suscripción activa"
        case "failed": "No se pudo activar la suscripción"
        case "timedOut": "Suscripción sin confirmar"
        case "interrupted": "Recepción interrumpida"
        default: "Preparando recepción…"
        }
    }
}

struct FTMSDiagnosticsView: View {
    let store: SessionStore

    private var services: [GATTService] {
        store.session?.device?.services.filter { $0.uuid == "1826" } ?? []
    }

    var body: some View {
        List {
            Section {
                Text(
                    "Estas capacidades y rangos son declaraciones del equipo. Los controles de velocidad e inclinación todavía no se han probado."
                ).foregroundStyle(Color.primary)
                if store.session?.device?.source == .synthetic {
                    Text("Inventario sintético · sin hardware").foregroundStyle(Color.primary)
                }
            }
            ForEach(services) { service in
                ForEach(readings(service)) { characteristic in
                    Section(GATTNames.name(characteristic.uuid)) {
                        if let features = characteristic.ftmsFeatures {
                            ForEach(Array(prioritized(features.capabilities).prefix(4))) { capability in
                                capabilityRow(capability)
                            }
                            DisclosureGroup("Otras capacidades") {
                                ForEach(Array(prioritized(features.capabilities).dropFirst(4))) { capability in
                                    capabilityRow(capability)
                                }
                            }
                            Text(
                                "Anunciada no significa verificada. No anunciada tampoco prueba imposibilidad por otros protocolos."
                            ).font(.footnote).foregroundStyle(Color.primary)
                        } else if let range = characteristic.ftmsRange {
                            LabeledContent("Mínimo") {
                                Text(value(range.minimum, range.unit)).foregroundStyle(Color.primary)
                            }
                            LabeledContent("Máximo") {
                                Text(value(range.maximum, range.unit)).foregroundStyle(Color.primary)
                            }
                            LabeledContent("Incremento") {
                                Text(value(range.increment, range.unit)).foregroundStyle(Color.primary)
                            }
                        } else {
                            Text(characteristic.readStatus == "pending" ? "Leyendo…" : "Sin valor interpretado")
                                .foregroundStyle(Color.primary)
                        }
                        if let error = characteristic.readError {
                            Text(error.message).foregroundStyle(Color.primary)
                        }
                        if let error = characteristic.decodeError {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Color.primary)
                        }
                        if let hex = characteristic.valueHex {
                            Text("Bytes: \(hex)").font(.footnote.monospaced()).textSelection(.enabled)
                        }
                        if characteristic.readStatus == nil {
                            Text("Lectura no disponible o no solicitada.").font(.footnote).foregroundStyle(
                                Color.primary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Capacidades FTMS")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func value(_ number: Double, _ unit: String) -> String {
        "\(number.formatted(.number.precision(.fractionLength(0...2)))) \(unit)"
    }

    private func capabilityRow(_ capability: FTMSCapability) -> some View {
        LabeledContent(capability.label) {
            Text(capability.declaration == "advertised" ? "Anunciada" : "No anunciada").foregroundStyle(
                Color.primary)
        }
    }

    private func readings(_ service: GATTService) -> [GATTCharacteristic] {
        let first = ["2AD4", "2AD5", "2ACC", "2AD7", "2AD8"]
        return service.characteristics.filter { FTMSDecoder.readableUUIDs.contains($0.uuid) }
            .sorted { (first.firstIndex(of: $0.uuid) ?? 99) < (first.firstIndex(of: $1.uuid) ?? 99) }
    }

    private func prioritized(_ capabilities: [FTMSCapability]) -> [FTMSCapability] {
        let first = ["speedTarget", "inclinationTarget", "totalDistance", "averageSpeed"]
        return capabilities.sorted {
            (first.firstIndex(of: $0.id) ?? 99, $0.id) < (first.firstIndex(of: $1.id) ?? 99, $1.id)
        }
    }
}
