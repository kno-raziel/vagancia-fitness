import FitnessCore
import Foundation

public struct AppMetadata: Sendable {
    public let version: String
    public let build: String
    public let osVersion: String
    public let deviceModel: String

    public init(version: String, build: String, osVersion: String, deviceModel: String) {
        self.version = version
        self.build = build
        self.osVersion = osVersion
        self.deviceModel = deviceModel
    }
}

public struct DiagnosticExport: Identifiable, Sendable {
    public let id: UUID
    public let archiveURL: URL
    public let fileURLs: [URL]
}

/// `.complete` preserves the established evidence contract. `.publicSupport`
/// emits a conservative, allowlisted projection for sharing with maintainers.
public enum DiagnosticExportProfile: String, Sendable, CaseIterable, Identifiable {
    case complete
    case publicSupport
    public var id: String { rawValue }
}

enum DiagnosticExporter {
    static func export(
        session: DiagnosticSession, metadata: AppMetadata, directory: URL, workout: JSONValue? = nil,
        watchDiagnostics: WatchDiagnosticExportSnapshot? = nil,
        profile: DiagnosticExportProfile = .complete
    ) throws -> DiagnosticExport {
        let exportId = UUID()
        let destination = directory.appendingPathComponent(exportId.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            let entries =
                try profile == .complete
                ? files(
                    session: session, metadata: metadata, workout: workout, watchDiagnostics: watchDiagnostics
                )
                : publicSupportFiles(
                    session: session, metadata: metadata, workout: workout, watchDiagnostics: watchDiagnostics
                )
            for entry in entries {
                try entry.data.write(to: destination.appendingPathComponent(entry.name), options: .atomic)
            }
            let prefix = workout == nil ? "vagancia-fitness-diagnostic" : "vagancia-fitness-workout"
            let archiveIdentity = profile == .complete ? session.sessionId : "session-1"
            let archiveURL = destination.appendingPathComponent("\(prefix)-\(archiveIdentity).zip")
            try StoredZIP.archive(entries).write(to: archiveURL, options: .atomic)
            return DiagnosticExport(
                id: exportId, archiveURL: archiveURL,
                fileURLs: entries.map { destination.appendingPathComponent($0.name) })
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Public-support output is built from an explicit allowlist. Unknown event
    /// payloads, free text, HealthKit values, persistent identities and Watch
    /// blobs are omitted instead of being presented as sanitized.
    private static func publicSupportFiles(
        session: DiagnosticSession, metadata: AppMetadata, workout: JSONValue?,
        watchDiagnostics: WatchDiagnosticExportSnapshot?
    ) throws -> [StoredZIP.Entry] {
        let exportSessionID = "session-1"
        let origin = session.startedAt
        func elapsed(_ date: Date?) -> JSONValue {
            guard let date else { return .null }
            return .number(max(0, date.timeIntervalSince(origin)))
        }
        let events = session.events.map { event -> JSONValue in
            .object([
                "eventId": .string("event-\(event.sequence)"),
                "sequence": .number(Double(event.sequence)),
                "elapsedSeconds": elapsed(event.timestamp),
                "kind": .string(publicEventKind(event.kind)),
                "source": .string(event.source.rawValue),
                "payload": .object([:]),
                "omission": .string(
                    "payload omitted in public-support profile; may contain free text, identifiers, health data, or encoded originals"
                ),
            ])
        }
        var lines = Data()
        for event in events {
            lines.append(try EvidenceJSON.encoder().encode(event))
            lines.append(0x0a)
        }
        let watchCount = watchDiagnostics?.entries.count ?? 0
        let safeAppMetadata = [
            "version": metadata.version.range(
                of: #"^[0-9]+(?:\.[0-9]+){0,3}$"#, options: .regularExpression) != nil
                ? JSONValue.string(metadata.version) : nil,
            "build": metadata.build.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil
                ? JSONValue.string(metadata.build) : nil,
        ].compactMapValues { $0 }
        let safeServices = (session.device?.services ?? []).compactMap { service -> JSONValue? in
            guard let uuid = publicServiceUUID(service.uuid) else { return nil }
            let characteristics = service.characteristics.compactMap {
                publicCharacteristicUUID($0.uuid).map(JSONValue.string)
            }
            return .object(["uuid": .string(uuid), "characteristicUUIDs": .array(characteristics)])
        }
        let manifest: [String: JSONValue] = [
            "schemaVersion": .string("1.0"),
            "profile": .string(DiagnosticExportProfile.publicSupport.rawValue),
            "sessionId": .string(exportSessionID), "source": .string("application"),
            "startedAtElapsedSeconds": .number(0), "endedAtElapsedSeconds": elapsed(session.endedAt),
            "exportedAtElapsedSeconds": .number(Date().timeIntervalSince(origin)),
            "isOpen": .bool(session.isOpen),
            "app": .object(safeAppMetadata),
            "capture": .object([
                "truncated": .bool(session.droppedEventCount > 0),
                "droppedEventCount": .number(Double(session.droppedEventCount)),
                "totalEventCount": .number(Double(session.totalEventCount)),
                "timeBasis": .string("secondsSinceSessionStart"),
            ]),
            "files": .array(
                ["device.json", "results.json", "events.jsonl", "summary.txt"].map(JSONValue.string)),
            "omissions": .object([
                "eventPayloads": .string("all omitted"), "deviceIdentity": .string("omitted"),
                "healthData": .string("omitted"), "operatorNotes": .string("omitted"),
                "watchRawEntries": .string("omitted; only received count and sync status retained"),
                "invalidAppMetadata": .number(Double(2 - safeAppMetadata.count)),
                "unrecognizedServiceUUIDs": .number(
                    Double(
                        (session.device?.services ?? []).filter { publicServiceUUID($0.uuid) == nil }.count)),
                "unrecognizedCharacteristicUUIDs": .number(
                    Double(
                        (session.device?.services ?? []).flatMap(\.characteristics).filter {
                            publicCharacteristicUUID($0.uuid) == nil
                        }.count)),
            ]),
            "watchDiagnostics": watchDiagnostics.map {
                .object([
                    "receivedEntryCount": .number(Double(watchCount)),
                    "syncStatus": .string($0.syncStatus.rawValue),
                    "allWatchRejectionsReceived": $0.syncStatus == .snapshotConfirmed ? .bool(true) : .null,
                    "coverage": .string(
                        "Raw Watch entries, including other sessions and encoded bytes, were omitted."),
                ])
            } ?? .null,
        ]
        let device: [String: JSONValue] = [
            "sessionId": .string(exportSessionID), "source": .string("application"),
            "identity": .string("omitted"), "services": .array(safeServices),
        ]
        let result: [String: JSONValue] = [
            "sessionId": .string(exportSessionID), "source": .string("application"),
            "status": .string("notRun"),
            "eventCount": .number(Double(session.totalEventCount)),
            "droppedEventCount": .number(Double(session.droppedEventCount)),
            "bleObserved": .bool(session.bleObserved ?? false),
            "workoutPresentBeforeOmission": .bool(workout != nil), "workoutIncluded": .bool(false),
            "workoutOmission": workout == nil
                ? .null
                : .string(
                    "workout payload omitted in public-support profile because it may contain HealthKit samples and free text"
                ),
            "watchReceivedEntryCount": .number(Double(watchCount)),
            "reason": .string(
                "This profile contains event metadata only. Payloads were omitted to prevent disclosure of unknown or encoded data."
            ),
        ]
        let summary =
            "VAGANCIA FITNESS — public support export\nSession: session-1\nDuration seconds: \(session.endedAt.map { max(0, $0.timeIntervalSince(origin)) } ?? max(0, Date().timeIntervalSince(origin)))\nEvents: \(session.totalEventCount) (dropped: \(session.droppedEventCount))\nWatch rejection entries received: \(watchCount)\nRaw event payloads, operator notes, device identity, health data, workout details, and Watch bytes omitted.\n"
        return [
            .init(name: "manifest.json", data: try EvidenceJSON.encoder(pretty: true).encode(manifest)),
            .init(name: "device.json", data: try EvidenceJSON.encoder(pretty: true).encode(device)),
            .init(name: "results.json", data: try EvidenceJSON.encoder(pretty: true).encode(result)),
            .init(name: "events.jsonl", data: lines),
            .init(name: "summary.txt", data: Data(summary.utf8)),
        ]
    }

    private static func publicEventKind(_ value: String) -> String {
        let known: Set<String> = [
            "session.created", "session.closed", "session.restored", "operator.note",
            "app.backgrounded", "app.activated", "ble.scan.started", "ble.scan.stopped",
            "ble.device.discovered",
            "ble.connection.started", "ble.connection.ready", "ble.connection.failed",
            "ble.connection.disconnected",
            "ble.gatt.discovery.started", "ble.gatt.discovery.completed", "ftms.control.requested",
            "ftms.control.response",
            "ftms.control.timeout", "ftms.control.superseded", "ftms.treadmill.received",
            "ble.connected", "ble.disconnected", "ble.connection.requested",
            "ble.disconnection.requested",
            "ble.radio.state", "ble.saved.connection.requested", "ble.services.discovered",
            "ble.characteristics.discovered", "ble.descriptors.discovered", "ble.discovery.finished",
            "ble.services.invalidated", "ble.identity.read", "ble.operation.requested",
            "ble.operation.timeout",
            "ftms.value.read", "ftms.telemetry.unavailable", "ftms.machine.status",
            "ftms.subscription.requested", "ftms.subscription.timeout", "ftms.subscription.updated",
            "ftms.control.blocked", "ftms.control.written", "ftms.control.subscription.requested",
            "ftms.control.subscription.timeout", "ftms.control.subscription.updated",
            "fitshow.notification.received", "fitshow.query.requested", "fitshow.query.timeout",
            "fitshow.query.written", "fitshow.subscription.requested", "fitshow.subscription.timeout",
            "fitshow.subscription.updated",
        ]
        return known.contains(value) ? value : "other"
    }

    private static func publicServiceUUID(_ value: String) -> String? {
        let standardServices: Set<String> = ["1800", "1801", "180A", "180D", "180F", "1826"]
        return validPublicBluetoothUUIDSyntax(value) && standardServices.contains(value.uppercased())
            ? value.lowercased() : nil
    }

    private static func publicCharacteristicUUID(_ value: String) -> String? {
        let standardCharacteristics: Set<String> = [
            "2ACC", "2ACD", "2AD3", "2AD4", "2AD5", "2AD7", "2AD8", "2AD9", "2ADA",
            "2A19", "2A24", "2A26", "2A27", "2A28", "2A29", "2A37",
        ]
        return validPublicBluetoothUUIDSyntax(value)
            && standardCharacteristics.contains(value.uppercased()) ? value.lowercased() : nil
    }

    private static func validPublicBluetoothUUIDSyntax(_ value: String) -> Bool {
        let pattern =
            #"^(?:[0-9A-Fa-f]{4}|[0-9A-Fa-f]{8}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func files(
        session: DiagnosticSession, metadata: AppMetadata, workout: JSONValue?,
        watchDiagnostics: WatchDiagnosticExportSnapshot?
    ) throws -> [StoredZIP.Entry] {
        let filenames = ["manifest.json", "device.json", "results.json", "events.jsonl", "summary.txt"]
        let hasBLE =
            session.bleObserved == true || session.device != nil
            || session.events.contains { $0.kind.hasPrefix("ble.") }
        var companionEvents: [JSONValue] = []
        var workoutVersion = "1.0"
        if case .object(let body) = workout, case .object(let record) = body["record"] {
            if case .number(let version) = record["schemaVersion"] {
                workoutVersion = "\(Int(version)).0"
            }
            if record["healthSave"] != nil, case .array(let values) = body["events"] {
                companionEvents = values
            }
        }
        var manifest: [String: JSONValue] = [
            "schemaVersion": .string("1.0"),
            "sessionId": .string(session.sessionId),
            "source": .string("application"),
            "captureMode": .string(
                session.device?.telemetry != nil
                    ? "ftmsTelemetry"
                    : session.device != nil ? "bluetoothDiscovery" : hasBLE ? "bluetoothScan" : "sessionOnly"),
            "evidenceSources": .array(
                Set(session.events.map { $0.source.rawValue }).sorted().map(JSONValue.string)),
            "startedAt": .string(EvidenceJSON.timestamp(session.startedAt)),
            "endedAt": session.endedAt.map { .string(EvidenceJSON.timestamp($0)) } ?? .null,
            "exportedAt": .string(EvidenceJSON.timestamp(Date())),
            "isOpen": .bool(session.isOpen),
            "app": .object(["version": .string(metadata.version), "build": .string(metadata.build)]),
            "host": .object([
                "platform": .string("iOS"), "osVersion": .string(metadata.osVersion),
                "deviceModel": .string(metadata.deviceModel),
            ]),
            "capture": .object([
                "truncated": .bool(session.droppedEventCount > 0),
                "droppedEventCount": .number(Double(session.droppedEventCount)),
                "totalEventCount": .number(Double(session.totalEventCount)),
                "elapsedTimeBasis": .string("monotonicWithinProcessExcludingRelaunchGaps"),
                "gaps": .array(
                    session.gaps.map {
                        .object([
                            "from": .string(EvidenceJSON.timestamp($0.from)),
                            "to": .string(EvidenceJSON.timestamp($0.to)), "reason": .string($0.reason),
                        ])
                    }),
            ]),
            "files": .array(filenames.filter { $0 != "manifest.json" }.map { .string($0) }),
            "notes": .string(
                hasBLE
                    ? "Diagnóstico Bluetooth. Consultar los eventos ftms.control para saber qué comandos se solicitaron y respondieron; aceptación por protocolo no verifica movimiento físico. El control propietario FitShow permanece deshabilitado."
                    : "Registro real de la aplicación. Sin conexión BLE, telemetría ni comandos de movimiento."
            ),
        ]
        if workout != nil {
            manifest["workoutSchemaVersion"] = .string(workoutVersion)
            manifest["workoutLocation"] = .string("results.json#/workout")
            manifest["metricSourcePolicy"] = .string(
                "Each workout metric carries its source; mock values are not hardware measurements.")
        }
        if !companionEvents.isEmpty {
            manifest["companionSchemaVersion"] = .number(1)
            manifest["eventStreams"] = .array([.string("diagnostic"), .string("workout")])
            manifest["diagnosticEventCount"] = .number(Double(session.events.count))
            manifest["workoutEventCount"] = .number(Double(companionEvents.count))
            manifest["jsonlEventCount"] = .number(Double(session.events.count + companionEvents.count))
            manifest["metricSourcePolicy"] = .string(
                "FTMS measurements, cumulative distance, HealthKit samples and synthetic values retain per-metric origin, sample/receive times and aggregation. Health save and physical stop are independent."
            )
        }
        let watchFiles = try watchDiagnostics?.files() ?? []
        if let watchDiagnostics {
            manifest["watchDiagnostics"] = watchDiagnostics.manifestValue
            manifest["files"] = .array(
                (filenames.filter { $0 != "manifest.json" } + watchFiles.map(\.name)).map(JSONValue.string))
            manifest["eventStreams"] = .array(
                (["diagnostic"] + (companionEvents.isEmpty ? [] : ["workout"]) + ["watchRejections"]).map(
                    JSONValue.string))
        }
        var device: [String: JSONValue] = [
            "sessionId": .string(session.sessionId), "source": .string("application"),
            "localPeripheralIdentifier": .null, "advertisedName": .null, "reportedIdentity": .null,
            "readIdentity": .object(["manufacturer": .null, "moduleModel": .null, "firmware": .null]),
            "services": .array([]), "candidateProfiles": .array([]),
        ]
        if let observed = session.device {
            device["source"] = .string(observed.source.rawValue)
            device["localPeripheralIdentifier"] = .string(observed.localPeripheralIdentifier)
            device["advertisedName"] = observed.advertisedName.map(JSONValue.string) ?? .null
            device["readIdentity"] = .object([
                "manufacturer": observed.manufacturer.map(JSONValue.string) ?? .null,
                "moduleModel": observed.moduleModel.map(JSONValue.string) ?? .null,
                "firmware": observed.firmware.map(JSONValue.string) ?? .null,
            ])
            device["services"] = try EvidenceJSON.decoder().decode(
                JSONValue.self, from: EvidenceJSON.encoder().encode(observed.services))
            device["inspection"] = try EvidenceJSON.decoder().decode(
                JSONValue.self, from: EvidenceJSON.encoder().encode(observed))
            device["candidateProfiles"] = .array(
                observed.containsFTMS
                    ? [
                        .object([
                            "protocol": .string("FTMS"),
                            "reason": .string("Servicio 1826 observado; capacidades y controles no verificados."),
                        ])
                    ] : [])
        }
        var results: [String: JSONValue] = [
            "sessionId": .string(session.sessionId), "source": .string("application"),
            "capabilities": .array([]), "tests": .array([]),
            "status": .string("notRun"),
            "reason": .string(
                "Lecturas, procedimientos y respuestas se describen por separado. No acreditan por sí solos ejecución física; consultar pruebas y notas del operador."
            ),
        ]
        results["distanceProgress"] = try json(session.distanceProgress)
        if let workout { results["workout"] = workout }
        // Procedures remain application/protocol evidence, not physical passes.
        results["tests"] = .array(
            session.events.filter { $0.kind == "ftms.control.requested" }.map { request in
                let id = request.payload["procedureId"]?.text
                let response = session.events.last {
                    $0.kind == "ftms.control.response" && $0.payload["procedureId"]?.text == id
                }
                let terminal = session.events.last {
                    ["ftms.control.timeout", "ftms.control.superseded"].contains($0.kind)
                        && $0.payload["procedureId"]?.text == id
                }
                let canonical = session.events.last { event in
                    guard case .object(let value) = event.payload["procedureTerminal"] else { return false }
                    return value["procedureId"]?.text == id
                }
                let canonicalResult: String?
                if case .object(let value) = canonical?.payload["procedureTerminal"] {
                    canonicalResult = value["result"]?.text
                } else {
                    canonicalResult = nil
                }
                let protocolResult: String
                switch canonicalResult {
                case "acceptedByProtocol": protocolResult = "accepted"
                case "rejectedByProtocol": protocolResult = "rejected"
                case "indeterminate", "supersededByExplicitStop": protocolResult = "indeterminate"
                default:
                    protocolResult =
                        response?.payload["valueHex"]?.text.flatMap { Data(hex: $0) }.flatMap {
                            $0.count == 3 ? ($0[2] == 1 ? "accepted" : "rejected") : nil
                        } ?? (terminal == nil ? "pendingOrInterrupted" : "indeterminate")
                }
                return .object([
                    "procedureId": id.map(JSONValue.string) ?? .null,
                    "protocol": .string("FTMS"), "action": request.payload["action"] ?? .null,
                    "requestEventId": .string(request.eventId),
                    "responseEventId": response.map { .string($0.eventId) } ?? .null,
                    "terminalEventId": (canonical ?? terminal).map { .string($0.eventId) } ?? .null,
                    "protocolResult": .string(protocolResult),
                    "physicalVerification": .string("notRun"),
                ])
            })
        if let observed = session.device {
            results["gattDiscovery"] = .object([
                "status": .string(observed.discoveryStatus), "inspectionId": .string(observed.inspectionId),
                "connectedAt": observed.connectedAt.map { .string(EvidenceJSON.timestamp($0)) } ?? .null,
                "serviceCount": .number(Double(observed.services.count)),
                "characteristicCount": .number(Double(observed.characteristicCount)),
            ])
            var capabilities: [JSONValue] = []
            var readings: [JSONValue] = []
            for service in observed.services where service.uuid == "1826" {
                for characteristic in service.characteristics
                where FTMSDecoder.readableUUIDs.contains(characteristic.uuid) {
                    readings.append(
                        .object([
                            "serviceId": .string(service.id), "characteristicId": .string(characteristic.id),
                            "uuid": .string(characteristic.uuid),
                            "readStatus": characteristic.readStatus.map(JSONValue.string) ?? .string("notRead"),
                            "valueHex": characteristic.valueHex.map(JSONValue.string) ?? .null,
                            "evidenceEventId": characteristic.valueEventId.map(JSONValue.string) ?? .null,
                            "decoderId": .string(FTMSDecoder.identifier),
                            "decodeError": characteristic.decodeError.map(JSONValue.string) ?? .null,
                            "features": try json(characteristic.ftmsFeatures),
                            "range": try json(characteristic.ftmsRange),
                        ]))
                    if let features = characteristic.ftmsFeatures {
                        capabilities += features.capabilities.map { capability in
                            .object([
                                "id": .string(capability.id), "label": .string(capability.label),
                                "declaration": .string(capability.declaration),
                                "verification": .string(capability.verification),
                                "evidenceEventId": characteristic.valueEventId.map(JSONValue.string) ?? .null,
                                "serviceId": .string(service.id), "characteristicId": .string(characteristic.id),
                            ])
                        }
                    }
                }
            }
            results["capabilities"] = .array(capabilities)
            results["ftmsReadings"] = .array(readings)
            results["telemetry"] = try json(observed.telemetry)
            results["reception"] = try json(observed.reception)
            results["interactive"] = try json(observed.interactive)
            results["comparison"] = .object([
                "ftmsSpeed": try json(observed.telemetry?.speed),
                "ftmsDistance": try json(observed.telemetry?.distance),
                "fitShowChannels": try json(observed.interactive?.fitShow),
                "fitShowControlEnabled": .bool(false),
                "fitShowCompatibility": .array(
                    observed.interactive?.fitShow.map { channel in
                        .object([
                            "channel": .string(channel.channel.title),
                            "messageCompatibility": .string(channel.compatibility),
                            "controlEnabled": .bool(false), "units": .string("unconfirmed"),
                            "referenceRevision": .string(FitShowProtocol.referenceRevision),
                        ])
                    } ?? []),
                "unitEquivalence": .string("unconfirmed"),
                "physicalVerification": .string("notRun"),
            ])
            results["telemetryObservation"] = .object([
                "speed": .string(observed.telemetry?.speed == nil ? "notReceived" : "receivedAndDecoded"),
                "distance": .string(
                    observed.telemetry?.distance == nil ? "notReceived" : "receivedAndDecoded"),
                "physicalCalibration": .string("notRun"),
            ])
        }
        var events = Data()
        for event in session.events {
            events.append(try EvidenceJSON.encoder().encode(event))
            events.append(0x0a)
        }
        // Workout stream includes late HealthKit results after the diagnostic
        // capture closed. Keep namespaces explicit instead of losing those events.
        for (index, value) in companionEvents.enumerated() {
            let event = DiagnosticEvent(
                eventId: "workout-export-\(session.sessionId)-\(index)",
                sequence: (session.events.last?.sequence ?? 0) + index + 1,
                timestamp: Date(), elapsedMilliseconds: 0, kind: "workout.evidence", source: .application,
                payload: [
                    "stream": .string("workout"), "event": value,
                    "timingPolicy": .string(
                        "Original occurrence and sequence are inside event; outer timestamp is export time."),
                ])
            events.append(try EvidenceJSON.encoder().encode(event))
            events.append(0x0a)
        }
        let summary = """
            \(workout == nil ? "VAGANCIA FITNESS Debug" : "VAGANCIA FITNESS") — registro de sesión
            Sesión: \(session.sessionId)
            Inicio (UTC): \(EvidenceJSON.timestamp(session.startedAt))
            Fin (UTC): \(session.endedAt.map(EvidenceJSON.timestamp) ?? "Sesión abierta")
            App: \(metadata.version) (\(metadata.build))
            iOS: \(metadata.osVersion)
            Equipo seleccionado: \(session.device?.advertisedName ?? "Ninguno o nombre desconocido")
            Conexión BLE observada: \(session.device?.connectedAt.map(EvidenceJSON.timestamp) ?? "No confirmada")
            Inventario GATT: \(session.device?.discoveryStatus ?? "No ejecutado")
            Servicios: \(session.device?.services.count ?? 0)
            Paquetes FTMS válidos: \(session.device?.telemetry?.validSampleCount ?? 0)
            Paquetes FTMS inválidos: \(session.device?.telemetry?.invalidSampleCount ?? 0)
            Última velocidad informada: \(session.device?.telemetry?.speed.map { "\($0.value) \($0.unit) a \(EvidenceJSON.timestamp($0.receivedAt))" } ?? "Sin datos")
            Última distancia informada: \(session.device?.telemetry?.distance.map { "\($0.value) \($0.unit) a \(EvidenceJSON.timestamp($0.receivedAt))" } ?? "Sin datos")
            Distancia registrada en sesión: \(session.distanceProgress.map { "\($0.accumulatedMeters) m; reinicios a cero: \($0.zeroResetCount); discontinuidades: \($0.discontinuityCount)" } ?? "Sin acumulado; captura anterior o sin muestras")
            Último procedimiento FTMS: \(session.device?.interactive?.control.last?.action.rawValue ?? "No ejecutado")
            Resultado del procedimiento: \(session.device?.interactive?.control.last?.result ?? "notRun")
            Control propietario FitShow: deshabilitado; mensajes/unidades pendientes de confirmación
            Verificación física y calibración: no ejecutadas por la app; consultar notas del operador
            Eventos conservados: \(session.events.count)
            Eventos descartados por límite: \(session.droppedEventCount)
            Intervalos sin captura entre aperturas: \(session.gaps.count)
            Procedencia: cada evento distingue aplicación, Bluetooth observado y notas del operador.
            Las notas no verifican por sí solas capacidades de la caminadora.
            \(session.droppedEventCount > 0 ? "Captura truncada: se conservaron los eventos más recientes." : "No se descartaron eventos por límite de almacenamiento.")
            """ + "\n"
            + (workout == nil
                ? ""
                : "Entrenamiento: consultar results.json → workout para programa, muestras, objetivos, fuentes y excepciones. Los datos mock están identificados por métrica.\n")
            + (companionEvents.isEmpty
                ? ""
                : "Watch y Salud: results.json → workout.record.healthSave y workout.samples. events.jsonl incluye el stream workout con eventos tardíos; cada evento conserva fecha y secuencia originales dentro de payload.event.\n")
            + (watchDiagnostics == nil
                ? ""
                : "Mensajes rechazados en Watch: watch-rejected-envelopes.json y .jsonl. Bytes completos en Base64 y hexadecimal. El manifiesto declara cobertura y sincronización; un registro local vacío no prueba que el reloj no tenga errores pendientes. Incluye rechazos de configuración y otras sesiones.\n")
        return [
            StoredZIP.Entry(
                name: "manifest.json", data: try EvidenceJSON.encoder(pretty: true).encode(manifest)),
            StoredZIP.Entry(
                name: "device.json", data: try EvidenceJSON.encoder(pretty: true).encode(device)),
            StoredZIP.Entry(
                name: "results.json", data: try EvidenceJSON.encoder(pretty: true).encode(results)),
            StoredZIP.Entry(name: "events.jsonl", data: events),
            StoredZIP.Entry(name: "summary.txt", data: Data(summary.utf8)),
        ] + watchFiles
    }

    private static func json<T: Encodable>(_ value: T?) throws -> JSONValue {
        guard let value else { return .null }
        return try EvidenceJSON.decoder().decode(
            JSONValue.self, from: EvidenceJSON.encoder().encode(value))
    }
}
