import CoreBluetooth
import FitnessCore
import Foundation
import Observation
import UIKit

public enum BluetoothPhase: String {
    case idle, scanning, connecting, discovering, ready, disconnecting, disconnected, failed

    public var title: String {
        localizedTitle()
    }
    public func localizedTitle(locale: Locale? = nil) -> String {
        FitnessText.string("bluetooth.phase.\(rawValue)", locale: locale)
    }
}

public struct DiscoveredDevice: Identifiable {
    public let id: UUID
    public var name: String?
    public var rssi: Int?
    public var connectable: Bool
    public var advertisement: [String: JSONValue]
    public var advertisesFTMS: Bool
}

// CoreBluetooth delivers every delegate callback on the main queue (queue: nil).
// @preconcurrency bridges its Objective-C delegate contracts into that isolation.
@MainActor @Observable
public final class BluetoothExplorer: NSObject, @preconcurrency CBCentralManagerDelegate,
    @preconcurrency CBPeripheralDelegate
{
    public private(set) var phase: BluetoothPhase = .idle
    public private(set) var devices: [DiscoveredDevice] = []
    public private(set) var radioStatus = "Bluetooth se activará al buscar."
    public private(set) var errorMessage: String?
    public private(set) var snapshot: GATTDevice?
    public private(set) var waitingForPermission = false
    public private(set) var livePoints: [LivePoint] = []
    public private(set) var rememberedTreadmill: RememberedTreadmill?
    public private(set) var rememberOnConnect = false
    var onTelemetry: (@MainActor (FTMSTelemetry) -> Void)?

    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var active: CBPeripheral?
    @ObservationIgnored private var pendingScan: Bool?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var operations: [ObjectIdentifier: String] = [:]
    @ObservationIgnored private var serviceIndices: [ObjectIdentifier: Int] = [:]
    @ObservationIgnored private var characteristicIndices: [ObjectIdentifier: (Int, Int)] = [:]
    @ObservationIgnored private var scanId: String?
    @ObservationIgnored private var snapshotSessionId: String?
    @ObservationIgnored private var subscriptionTask: Task<Void, Never>?
    @ObservationIgnored private var controlTask: Task<Void, Never>?
    @ObservationIgnored private var controlSubscriptionTask: Task<Void, Never>?
    @ObservationIgnored private var controlPoint: CBCharacteristic?
    @ObservationIgnored private var statusPoint: CBCharacteristic?
    @ObservationIgnored private var writeQueue: [(id: String, hex: String, protocolId: DiagnosticProtocol)] = []
    @ObservationIgnored private var fitShowAssemblers: [DiagnosticProtocol: FitShowAssembler] = [:]
    @ObservationIgnored private var fitShowQueries: [DiagnosticProtocol: (id: String, range: Bool, date: Date)] = [:]
    @ObservationIgnored private var fitShowTasks: [DiagnosticProtocol: Task<Void, Never>] = [:]
    @ObservationIgnored private var recordedProcedureTerminals: Set<String> = []
    @ObservationIgnored private var receptionTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRememberedConnection = false
    @ObservationIgnored private var programBackgroundLease = false
    @ObservationIgnored private var automaticConnection = ConnectOnOpenPolicy()
    @ObservationIgnored private var rememberedConnectionTrigger = "savedIdentifierExplicit"
    @ObservationIgnored private var rememberedStorage: RememberedTreadmillStorage

    public init(store: SessionStore) {
        self.store = store
        rememberedStorage = RememberedTreadmillStorage(
            url: store.directory.appendingPathComponent("remembered-treadmill.json"))
        super.init()
        store.onPersistenceFailure = { [weak self] message in
            self?.stopForPersistenceFailure(message)
        }
        do {
            rememberedTreadmill = try rememberedStorage.load()
            if rememberedTreadmill == nil,
                !FileManager.default.fileExists(atPath: rememberedStorage.url.path),
                let device = store.session?.device,
                device.source == .hardware, device.containsFTMS,
                let id = UUID(uuidString: device.localPeripheralIdentifier)
            {
                let saved = RememberedTreadmill(identifier: id, name: device.advertisedName)
                try rememberedStorage.save(saved)
                rememberedTreadmill = saved
            }
        } catch {
            errorMessage = "No se pudo leer la caminadora guardada: \(error.localizedDescription)"
        }
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
                store.session?.device?.source == .synthetic
            {
                livePoints = [
                    0.0, 0.8, 0.8, 2, 2, 4, 4, 2, store.session?.device?.telemetry?.speed?.value ?? 0,
                ].enumerated().map {
                    LivePoint(
                        id: "synthetic-\($0.offset)",
                        date: Date().addingTimeInterval(Double($0.offset - 8) * 10), speed: $0.element)
                }
            }
        #endif
    }

    public var hasActivity: Bool {
        active != nil || phase == .scanning || pendingScan != nil || pendingRememberedConnection
    }
    public var hasConnection: Bool { active != nil }
    public var isScanning: Bool { phase == .scanning }

    public func setConnectOnOpen(_ enabled: Bool) {
        guard var saved = rememberedTreadmill else { return }
        saved.connectOnOpen = enabled
        do {
            try rememberedStorage.save(saved)
            rememberedTreadmill = saved
        } catch { errorMessage = "No se pudo guardar la preferencia: \(error.localizedDescription)" }
    }

    public func forgetTreadmill() {
        guard !hasActivity else { return }
        do {
            try rememberedStorage.save(nil)
            rememberedTreadmill = nil
        } catch { errorMessage = "No se pudo olvidar el equipo: \(error.localizedDescription)" }
    }

    /// Remember the selected device only after an explicit operator opt-in.
    public func setRememberOnConnect(_ enabled: Bool) { rememberOnConnect = enabled }

    public func autoConnectIfEnabled() {
        guard !ProcessInfo.processInfo.arguments.contains("--ui-testing"),
            automaticConnection.claim(
                enabled: rememberedTreadmill?.connectOnOpen == true,
                foreground: UIApplication.shared.applicationState == .active, idle: !hasActivity)
        else { return }
        connectRemembered(trigger: "savedIdentifierOnOpen")
    }

    public func connectRemembered(trigger: String = "savedIdentifierExplicit") {
        guard !hasActivity, rememberedTreadmill != nil,
            UIApplication.shared.applicationState == .active
        else { return }
        do { if store.session?.isOpen != true { try store.startSession() } } catch {
            errorMessage = error.localizedDescription
            return
        }
        automaticConnection.suppress()
        rememberedConnectionTrigger = trigger
        guard
            record(
                "ble.saved.connection.requested",
                payload: [
                    "connectionTrigger": .string(trigger),
                    "savedIdentifier": .string(rememberedTreadmill!.identifier.uuidString),
                    "motorCommand": .bool(false),
                ])
        else { return }
        pendingRememberedConnection = true
        errorMessage = nil
        if central == nil {
            waitingForPermission = true
            central = CBCentralManager(delegate: self, queue: nil)
        } else {
            startRememberedConnection()
        }
    }

    private func startRememberedConnection() {
        guard pendingRememberedConnection, let central, let saved = rememberedTreadmill else { return }
        if central.state == .unknown || central.state == .resetting { return }
        pendingRememberedConnection = false
        waitingForPermission = false
        guard UIApplication.shared.applicationState == .active else { return }
        guard central.state == .poweredOn else {
            errorMessage = radioStatus
            return
        }
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [saved.identifier]).first
        else {
            errorMessage =
                "iOS no pudo recuperar el equipo guardado. Usa Buscar caminadora; no se elegirá otro equipo por su nombre."
            return
        }
        peripherals[peripheral.identifier] = peripheral
        let device = DiscoveredDevice(
            id: peripheral.identifier, name: saved.name, rssi: nil, connectable: true,
            advertisement: ["source": .string("savedCoreBluetoothIdentifier; not a new advertisement")],
            advertisesFTMS: false)
        connect(device, trigger: rememberedConnectionTrigger)
    }

    public func search(allDevices: Bool) {
        guard active == nil, !isScanning, pendingScan == nil, !pendingRememberedConnection else {
            return
        }
        errorMessage = nil
        automaticConnection.suppress()
        do {
            if store.session?.isOpen != true { try store.startSession() }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        pendingScan = allDevices
        if central == nil {
            waitingForPermission = true
            central = CBCentralManager(delegate: self, queue: nil)
        } else {
            startPendingScan()
        }
    }

    private func startPendingScan() {
        guard let central, let allDevices = pendingScan else { return }
        if central.state == .unknown || central.state == .resetting { return }
        waitingForPermission = false
        pendingScan = nil
        guard central.state == .poweredOn else {
            errorMessage = radioStatus
            return
        }
        peripherals.removeAll()
        devices.removeAll()
        scanId = UUID().uuidString
        guard
            record(
                "ble.scan.started",
                payload: [
                    "operationId": .string(scanId!), "mode": .string(allDevices ? "all" : "ftms"),
                    "durationSeconds": .number(30),
                ])
        else { return }
        phase = .scanning
        central.scanForPeripherals(
            withServices: allDevices ? nil : [CBUUID(string: "1826")],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.stopSearch(reason: "scanDeadline")
        }
    }

    public func stopSearch(reason: String = "operator") {
        waitingForPermission = false
        pendingScan = nil
        pendingRememberedConnection = false
        automaticConnection.suppress()
        scanTask?.cancel()
        guard isScanning else { return }
        central?.stopScan()
        phase = .idle
        _ = record(
            "ble.scan.stopped",
            payload: [
                "operationId": scanId.map(JSONValue.string) ?? .null, "reason": .string(reason),
                "deviceCount": .number(Double(devices.count)),
            ])
    }

    public func connect(_ device: DiscoveredDevice, trigger: String = "operatorSelection") {
        guard active == nil, let central, central.state == .poweredOn,
            let peripheral = peripherals[device.id]
        else { return }
        errorMessage = nil
        guard store.session?.isOpen == true else {
            errorMessage = "Inicia una sesión y busca de nuevo."
            return
        }
        if let previous = store.session?.device,
            previous.localPeripheralIdentifier != device.id.uuidString
        {
            errorMessage =
                "Esta sesión ya contiene otro equipo. Finalízala y crea otra sesión para probar este dispositivo."
            return
        }
        stopSearch(reason: "deviceSelected")
        snapshot = GATTDevice(
            localPeripheralIdentifier: device.id.uuidString, inspectionId: UUID().uuidString,
            advertisedName: device.name, advertisement: device.advertisement, selectedAt: Date())
        snapshotSessionId = store.session?.sessionId
        snapshot?.interactive = InteractiveEvidence()
        snapshot?.reception = ReceptionHealth()
        receptionTask?.cancel()
        controlTask?.cancel()
        controlSubscriptionTask?.cancel()
        controlPoint = nil
        statusPoint = nil
        writeQueue.removeAll()
        fitShowAssemblers.removeAll()
        fitShowQueries.removeAll()
        for task in fitShowTasks.values { task.cancel() }
        fitShowTasks.removeAll()
        recordedProcedureTerminals.removeAll()
        livePoints.removeAll()
        operations.removeAll()
        serviceIndices.removeAll()
        characteristicIndices.removeAll()
        guard
            record(
                "ble.connection.requested",
                payload: [
                    "reason": .string("Conexión sin órdenes de motor; permiso y procedimientos reiniciados."),
                    "connectionTrigger": .string(trigger),
                    "connectionOptions": .string("default; no reconnect loop"),
                ])
        else { return }
        active = peripheral
        peripheral.delegate = self
        phase = .connecting
        // AutoReconnect is opt-in. Even supplying its key with false can require
        // the newer timestamp/isReconnecting delegate. Use the default contract.
        central.connect(peripheral, options: nil)
        setDeadline(seconds: 15, stage: "connection")
    }

    public func disconnect(reason: String = "operator") {
        stopSearch(reason: reason)
        guard let active, phase != .disconnecting else { return }
        deadlineTask?.cancel()
        receptionTask?.cancel()
        subscriptionTask?.cancel()
        controlTask?.cancel()
        controlSubscriptionTask?.cancel()
        for task in fitShowTasks.values { task.cancel() }
        snapshot?.interruptTelemetry()
        snapshot?.endPendingDiscovery(as: "interrupted")
        snapshot?.connectionState = "disconnecting"
        phase = .disconnecting
        _ = record("ble.disconnection.requested", payload: ["reason": .string(reason)])
        central?.cancelPeripheralConnection(active)
    }

    public func backgrounded() {
        // Discovery stays operator-led in the foreground. An established passive
        // subscription keeps receiving callbacks via bluetooth-central when locked.
        stopSearch(reason: "appBackgrounded")
        if phase == .connecting || phase == .discovering {
            disconnect(reason: "backgroundedBeforeReady")
        }
    }

    /// Only the workout runtime grants this lease after an operator-confirmed
    /// program start. Diagnostic controls continue to require the foreground.
    func setProgramBackgroundLease(_ enabled: Bool) { programBackgroundLease = enabled }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: radioStatus = "Bluetooth disponible."
        case .poweredOff: radioStatus = "Bluetooth está apagado. Actívalo en Ajustes y vuelve a buscar."
        case .unauthorized:
            radioStatus =
                "Permiso Bluetooth denegado. Actívalo para VAGANCIA FITNESS en Ajustes → Privacidad y seguridad → Bluetooth."
        case .unsupported:
            radioStatus = "Este dispositivo no permite Bluetooth Low Energy. Usa tu iPhone físico."
        case .resetting:
            radioStatus = "Bluetooth se está reiniciando. Vuelve a buscar cuando esté disponible."
        case .unknown: radioStatus = "Preparando Bluetooth…"
        @unknown default: radioStatus = "Estado Bluetooth desconocido."
        }
        if central.state != .poweredOn && central.state != .unknown && central.state != .resetting {
            stopSearch(reason: "bluetoothUnavailable")
            if active != nil {
                deadlineTask?.cancel()
                snapshot?.connectionState = "disconnected"
                subscriptionTask?.cancel()
                snapshot?.interruptTelemetry()
                snapshot?.endPendingDiscovery(as: "interrupted")
                active?.delegate = nil
                active = nil
                phase = .disconnected
            }
        }
        if store.session?.isOpen == true {
            _ = record(
                "ble.radio.state",
                payload: ["state": .number(Double(central.state.rawValue)), "reason": .string(radioStatus)])
        }
        startPendingScan()
        startRememberedConnection()
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi signalStrength: NSNumber
    ) {
        guard isScanning else { return }
        let id = peripheral.identifier
        let advertised =
            (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let isConnectable =
            (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        let signal = signalStrength.intValue == 127 ? nil : signalStrength.intValue
        var ad: [String: JSONValue] = [
            "serviceUUIDs": .array(advertised.map { .string($0.uuidString) }),
            "isConnectable": .bool(isConnectable), "rssiDBm": signal.map { .number(Double($0)) } ?? .null,
        ]
        if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            ad["manufacturerDataHex"] = .string(hex(data))
        }
        if let data = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            ad["serviceDataHex"] = .object(
                Dictionary(uniqueKeysWithValues: data.map { ($0.key.uuidString, .string(hex($0.value))) }))
        }
        let device = DiscoveredDevice(
            id: id, name: name, rssi: signal, connectable: isConnectable, advertisement: ad,
            advertisesFTMS: advertised.contains(CBUUID(string: "1826")))
        peripherals[id] = peripheral
        if let index = devices.firstIndex(where: { $0.id == id }) {
            devices[index] = device
            return
        }
        guard devices.count < 100 else {
            stopSearch(reason: "deviceLimit100")
            return
        }
        devices.append(device)
        _ = record(
            "ble.device.discovered", source: .hardware,
            payload: [
                "localPeripheralIdentifier": .string(id.uuidString),
                "name": name.map(JSONValue.string) ?? .null, "advertisement": .object(ad),
            ])
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard active === peripheral else { return }
        guard phase == .connecting else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        deadlineTask?.cancel()
        snapshot?.connectedAt = Date()
        snapshot?.connectionState = "connected"
        phase = .discovering
        guard
            record(
                "ble.connected", source: .hardware,
                payload: [
                    "reason": .string("CoreBluetooth confirmó la conexión; no verifica funciones del motor.")
                ])
        else { return }
        operations[ObjectIdentifier(peripheral)] = UUID().uuidString
        guard recordRequest("services", object: peripheral) else { return }
        peripheral.discoverServices(nil)
        setDeadline(seconds: 30, stage: "gattDiscovery")
    }

    public func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?
    ) {
        guard active === peripheral else { return }
        deadlineTask?.cancel()
        snapshot?.connectionState = "failed"
        snapshot?.endPendingDiscovery(as: "interrupted")
        snapshot?.error = error.map(BLEFailure.init)
        errorMessage =
            error?.localizedDescription
            ?? "No se pudo conectar. Cierra FitShow y vuelve a intentarlo cerca de la caminadora."
        active?.delegate = nil
        active = nil
        phase = .failed
        _ = record("ble.connection.failed", source: .hardware, payload: failurePayload(error))
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        guard active === peripheral else { return }
        deadlineTask?.cancel()
        snapshot?.connectionState = "disconnected"
        subscriptionTask?.cancel()
        snapshot?.interruptTelemetry()
        snapshot?.endPendingDiscovery(as: "interrupted")
        peripheral.delegate = nil
        active = nil
        phase = .disconnected
        if let error { errorMessage = "Se perdió la conexión: \(error.localizedDescription)" }
        _ = record("ble.disconnected", source: .hardware, payload: failurePayload(error))
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard accepts(peripheral),
            let operation = operations.removeValue(forKey: ObjectIdentifier(peripheral))
        else { return }
        snapshot?.serviceDiscovery = error == nil ? "complete" : "failed"
        snapshot?.error = error.map(BLEFailure.init)
        let services = error == nil ? peripheral.services ?? [] : []
        snapshot?.services = services.map {
            GATTService(id: UUID().uuidString, uuid: $0.uuid.uuidString, isPrimary: $0.isPrimary)
        }
        guard
            record(
                "ble.services.discovered", source: .hardware,
                payload: failurePayload(error).merging(
                    ["operationId": .string(operation), "count": .number(Double(services.count))],
                    uniquingKeysWith: { _, new in new }))
        else { return }
        for (index, service) in services.enumerated() {
            serviceIndices[ObjectIdentifier(service)] = index
            operations[ObjectIdentifier(service)] = UUID().uuidString
            guard
                recordRequest(
                    "characteristics", object: service,
                    reference: [
                        "serviceId": .string(snapshot!.services[index].id),
                        "serviceUUID": .string(service.uuid.uuidString),
                    ])
            else { return }
            peripheral.discoverCharacteristics(nil, for: service)
        }
        finishIfComplete()
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        guard accepts(peripheral), let s = serviceIndices[ObjectIdentifier(service)],
            let operation = operations.removeValue(forKey: ObjectIdentifier(service))
        else { return }
        snapshot?.services[s].characteristicDiscovery = error == nil ? "complete" : "failed"
        snapshot?.services[s].error = error.map(BLEFailure.init)
        let characteristics = error == nil ? service.characteristics ?? [] : []
        snapshot?.services[s].characteristics = characteristics.map {
            GATTCharacteristic(
                id: UUID().uuidString, uuid: $0.uuid.uuidString, properties: properties($0.properties),
                rawProperties: $0.properties.rawValue)
        }
        guard
            record(
                "ble.characteristics.discovered", source: .hardware,
                payload: failurePayload(error).merging(
                    [
                        "operationId": .string(operation), "serviceId": .string(snapshot!.services[s].id),
                        "count": .number(Double(characteristics.count)),
                    ], uniquingKeysWith: { _, new in new }))
        else { return }
        for (c, characteristic) in characteristics.enumerated() {
            characteristicIndices[ObjectIdentifier(characteristic)] = (s, c)
            operations[ObjectIdentifier(characteristic)] = UUID().uuidString
            guard recordRequest("descriptors", object: characteristic, reference: reference(s, c)) else {
                return
            }
            peripheral.discoverDescriptors(for: characteristic)
        }
        finishIfComplete()
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard accepts(peripheral), let (s, c) = characteristicIndices[ObjectIdentifier(characteristic)],
            let operation = operations.removeValue(forKey: ObjectIdentifier(characteristic))
        else { return }
        snapshot?.services[s].characteristics[c].descriptorDiscovery =
            error == nil ? "complete" : "failed"
        snapshot?.services[s].characteristics[c].error = error.map(BLEFailure.init)
        snapshot?.services[s].characteristics[c].descriptors =
            (error == nil ? characteristic.descriptors ?? [] : []).map {
                GATTDescriptor(id: UUID().uuidString, uuid: $0.uuid.uuidString)
            }
        var payload = reference(s, c).merging(
            failurePayload(error), uniquingKeysWith: { _, new in new })
        payload["operationId"] = .string(operation)
        guard record("ble.descriptors.discovered", source: .hardware, payload: payload) else { return }
        let identity =
            snapshot?.services[s].uuid == "180A"
            && GATTDevice.identityUUIDs.contains(characteristic.uuid.uuidString)
        let ftms =
            snapshot?.services[s].uuid == "1826"
            && FTMSDecoder.readableUUIDs.contains(characteristic.uuid.uuidString)
        if identity || ftms, characteristic.properties.contains(.read) {
            snapshot?.services[s].characteristics[c].readStatus = "pending"
            operations[ObjectIdentifier(characteristic)] = UUID().uuidString
            guard
                recordRequest(
                    ftms ? "readFTMS" : "readIdentity", object: characteristic, reference: reference(s, c))
            else { return }
            peripheral.readValue(for: characteristic)
        }
        finishIfComplete()
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if active === peripheral, phase == .ready, handleInteractiveValue(characteristic, error: error) {
            return
        }
        if active === peripheral, phase == .ready,
            let (s, c) = characteristicIndices[ObjectIdentifier(characteristic)],
            snapshot?.telemetry?.characteristicId == snapshot?.services[s].characteristics[c].id
        {
            receiveTelemetry(characteristic, service: s, index: c, error: error)
            return
        }
        guard accepts(peripheral), let (s, c) = characteristicIndices[ObjectIdentifier(characteristic)],
            snapshot?.services[s].characteristics[c].readStatus == "pending",
            let operation = operations.removeValue(forKey: ObjectIdentifier(characteristic))
        else { return }
        let bytes = error == nil ? characteristic.value : nil
        snapshot?.services[s].characteristics[c].readStatus =
            error == nil && bytes != nil ? "complete" : "failed"
        snapshot?.services[s].characteristics[c].valueHex = bytes.map(hex)
        let isFTMS = snapshot?.services[s].uuid == "1826"
        snapshot?.services[s].characteristics[c].textValue =
            isFTMS ? nil : bytes.flatMap { String(data: $0, encoding: .utf8) }
        snapshot?.services[s].characteristics[c].readError = error.map(BLEFailure.init)
        snapshot?.services[s].characteristics[c].readAt = Date()
        let eventId = UUID().uuidString.lowercased()
        snapshot?.services[s].characteristics[c].valueEventId = eventId
        if isFTMS, let bytes {
            do {
                if characteristic.uuid.uuidString == "2ACC" {
                    snapshot?.services[s].characteristics[c].ftmsFeatures = try FTMSDecoder.features(bytes)
                } else {
                    snapshot?.services[s].characteristics[c].ftmsRange = try FTMSDecoder.range(
                        bytes, uuid: characteristic.uuid.uuidString)
                }
            } catch {
                snapshot?.services[s].characteristics[c].decodeError = error.localizedDescription
            }
        }
        var payload = reference(s, c).merging(
            failurePayload(error), uniquingKeysWith: { _, new in new })
        payload["operationId"] = .string(operation)
        payload["direction"] = .string("received")
        payload["valueHex"] = bytes.map { .string(hex($0)) } ?? .null
        payload["textUTF8"] =
            snapshot?.services[s].characteristics[c].textValue.map(JSONValue.string) ?? .null
        if isFTMS {
            payload["decoderId"] = .string(FTMSDecoder.identifier)
            payload["features"] = json(snapshot?.services[s].characteristics[c].ftmsFeatures)
            payload["range"] = json(snapshot?.services[s].characteristics[c].ftmsRange)
            payload["decodeError"] =
                snapshot?.services[s].characteristics[c].decodeError.map(JSONValue.string) ?? .null
        }
        guard
            record(
                isFTMS ? "ftms.value.read" : "ble.identity.read", source: .hardware, payload: payload,
                eventId: eventId)
        else { return }
        finishIfComplete()
    }

    private func beginTelemetry() {
        guard let active, let services = active.services else { return }
        for service in services where service.uuid == CBUUID(string: "1826") {
            for characteristic in service.characteristics ?? []
            where characteristic.uuid == CBUUID(string: "2ACD")
                && characteristic.properties.contains(.notify)
            {
                guard let (s, c) = characteristicIndices[ObjectIdentifier(characteristic)], let snapshot
                else { return }
                let operation = UUID().uuidString.lowercased()
                self.snapshot?.telemetry = FTMSTelemetry(
                    serviceId: snapshot.services[s].id,
                    characteristicId: snapshot.services[s].characteristics[c].id, startedAt: Date(),
                    subscriptionOperationId: operation)
                var payload = reference(s, c)
                payload["operationId"] = .string(operation)
                payload["reason"] = .string(
                    "Suscripción pasiva a Treadmill Data; no envía comandos de motor.")
                guard record("ftms.subscription.requested", payload: payload) else { return }
                active.setNotifyValue(true, for: characteristic)
                subscriptionTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard let self, self.phase == .ready,
                        self.snapshot?.telemetry?.subscriptionStatus == "pending"
                    else { return }
                    self.snapshot?.telemetry?.subscriptionStatus = "timedOut"
                    _ = self.record(
                        "ftms.subscription.timeout",
                        payload: [
                            "operationId": .string(operation),
                            "reason": .string(
                                "CoreBluetooth no confirmó la suscripción en 10 segundos. No se reintenta automáticamente."
                            ),
                        ])
                }
                return  // One explicit metric source; never combine duplicate instances.
            }
        }
        _ = record(
            "ftms.telemetry.unavailable",
            payload: [
                "reason": .string(
                    "No se observó Treadmill Data con propiedad notify. No demuestra ausencia de otros protocolos."
                )
            ])
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if active === peripheral, phase == .ready,
            handleInteractiveSubscription(characteristic, error: error)
        {
            return
        }
        guard active === peripheral, phase == .ready,
            let (s, c) = characteristicIndices[ObjectIdentifier(characteristic)],
            let telemetry = snapshot?.telemetry,
            telemetry.characteristicId == snapshot?.services[s].characteristics[c].id
        else { return }
        subscriptionTask?.cancel()
        snapshot?.telemetry?.subscriptionStatus =
            error == nil && characteristic.isNotifying ? "active" : "failed"
        snapshot?.telemetry?.error = error.map(BLEFailure.init)
        if error == nil && characteristic.isNotifying {
            snapshot?.reception?.subscribe("FTMS", at: Date())
        }
        var payload = reference(s, c).merging(
            failurePayload(error), uniquingKeysWith: { _, new in new })
        payload["operationId"] = .string(telemetry.subscriptionOperationId)
        payload["isNotifying"] = .bool(characteristic.isNotifying)
        _ = record("ftms.subscription.updated", source: .hardware, payload: payload)
    }

    private func receiveTelemetry(
        _ characteristic: CBCharacteristic, service s: Int, index c: Int, error: (any Error)?
    ) {
        let eventId = UUID().uuidString.lowercased()
        let resumed =
            error == nil && characteristic.value != nil
            && observeReception("FTMS", at: Date(), eventId: eventId)
        var payload = reference(s, c).merging(
            failurePayload(error), uniquingKeysWith: { _, new in new })
        if resumed {
            payload["receptionResumed"] = .bool(true)
            payload["reception"] = json(snapshot?.reception)
        }
        payload["direction"] = .string("received")
        payload["decoderId"] = .string(FTMSDecoder.identifier)
        payload["valueHex"] = characteristic.value.map { .string(hex($0)) } ?? .null
        if let error {
            snapshot?.telemetry?.error = BLEFailure(error)
        } else if let bytes = characteristic.value {
            snapshot?.telemetry?.error = nil
            do {
                let sample = try snapshot?.telemetry?.receive(bytes, at: Date(), eventId: eventId)
                payload["sample"] = json(sample)
                if let speed = sample?.speedKilometersPerHour {
                    let metric = snapshot?.telemetry?.speed
                    snapshot?.interactive?.control.observed(metric)
                    livePoints.append(LivePoint(id: eventId, date: Date(), speed: speed))
                    if livePoints.count > 300 { livePoints.removeFirst(livePoints.count - 300) }
                }
            } catch {
                payload["decodeError"] = .string(error.localizedDescription)
            }
        } else {
            payload["decodeError"] = .string("CoreBluetooth no entregó bytes.")
        }
        _ = record("ftms.treadmill.received", source: .hardware, payload: payload, eventId: eventId)
        if let telemetry = snapshot?.telemetry { onTelemetry?(telemetry) }
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]
    ) {
        guard active === peripheral else { return }
        snapshot?.discoveryStatus = "invalidated"
        _ = record(
            "ble.services.invalidated", source: .hardware,
            payload: ["serviceUUIDs": .array(invalidatedServices.map { .string($0.uuid.uuidString) })])
        errorMessage =
            "El equipo cambió sus servicios. Desconecta y vuelve a conectar para obtener un inventario nuevo."
        disconnect(reason: "servicesInvalidated")
    }

    private func accepts(_ peripheral: CBPeripheral) -> Bool {
        active === peripheral && phase == .discovering
    }

    private func finishIfComplete() {
        guard operations.isEmpty, phase == .discovering else { return }
        deadlineTask?.cancel()
        let partial =
            snapshot?.serviceDiscovery != "complete"
            || snapshot?.services.contains { service in
                service.characteristicDiscovery != "complete"
                    || service.characteristics.contains {
                        $0.descriptorDiscovery != "complete" || $0.readStatus == "failed"
                    }
            } == true
        snapshot?.discoveryStatus = partial ? "partial" : "complete"
        phase = .ready
        guard
            record(
                "ble.discovery.finished",
                payload: [
                    "reason": .string(
                        partial
                            ? "Inventario parcial: consulta los errores por operación."
                            : "Inventario GATT completado. Las funciones de la caminadora aún no se han probado.")
                ])
        else { return }
        beginTelemetry()
        if rememberOnConnect, let active, snapshot?.containsFTMS == true {
            let saved = RememberedTreadmill(
                identifier: active.identifier, name: snapshot?.advertisedName,
                connectOnOpen: rememberedTreadmill?.identifier == active.identifier
                    && rememberedTreadmill?.connectOnOpen == true)
            do {
                try rememberedStorage.save(saved)
                rememberedTreadmill = saved
            } catch {
                errorMessage =
                    "Conectado, pero no se pudo recordar el equipo: \(error.localizedDescription)"
            }
        }
        receptionTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.phase == .ready else { return }
                self.checkReception()
            }
        }
    }

    private func observeReception(_ channel: String, at date: Date, eventId: String) -> Bool {
        snapshot?.reception?.received(channel, at: date, eventId: eventId) == true
    }

    private func checkReception() {
        guard phase == .ready, let active else { return }
        let silent = snapshot?.reception?.check(at: Date()) ?? []
        guard !silent.isEmpty else { return }
        var payload: [String: JSONValue] = [
            "channels": .array(silent.map(JSONValue.string)), "reception": json(snapshot?.reception),
            "appState": .number(Double(UIApplication.shared.applicationState.rawValue)),
            "peripheralState": .number(Double(active.state.rawValue)),
            "reason": .string(
                "Más de 5 segundos sin notificaciones. Suscripción activa no garantiza recepción. No se atribuye la causa ni se envían comandos automáticamente."
            ),
        ]
        payload["subscriptions"] = .array(
            (active.services ?? []).flatMap { service in
                (service.characteristics ?? []).filter {
                    $0.properties.contains(.notify) || $0.properties.contains(.indicate)
                }.map {
                    .object([
                        "serviceUUID": .string(service.uuid.uuidString),
                        "characteristicUUID": .string($0.uuid.uuidString), "isNotifying": .bool($0.isNotifying),
                    ])
                }
            })
        _ = record("diagnostic.reception.silent", payload: payload)
    }

    private func setDeadline(seconds: Int, stage: String) {
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.active != nil else { return }
            self.snapshot?.endPendingDiscovery(as: "timedOut")
            self.errorMessage =
                "Se agotó el tiempo de \(stage == "connection" ? "conexión" : "exploración"). Se conserva el resultado parcial; puedes desconectar y volver a intentar."
            _ = self.record(
                "ble.operation.timeout",
                payload: [
                    "stage": .string(stage),
                    "pendingOperationIds": .array(self.operations.values.map(JSONValue.string)),
                ])
            self.disconnect(reason: "timeout")
        }
    }

    @discardableResult
    private func record(
        _ kind: String, source: EvidenceSource = .application, payload: [String: JSONValue],
        eventId: String = UUID().uuidString.lowercased()
    ) -> Bool {
        var payload = payload
        if kind.hasPrefix("ftms.") { payload["protocol"] = .string("FTMS") }
        if kind.hasPrefix("fitshow.") {
            payload["protocol"] = payload["protocol"] ?? .string("FitShow")
        }
        if snapshotSessionId != store.session?.sessionId { snapshot = nil }
        if let snapshot, !kind.hasPrefix("ble.scan."), kind != "ble.device.discovered",
            kind != "ble.radio.state"
        {
            payload["localPeripheralIdentifier"] =
                payload["localPeripheralIdentifier"] ?? .string(snapshot.localPeripheralIdentifier)
            payload["inspectionId"] = .string(snapshot.inspectionId)
        }
        // Every terminal transition uses the same path, including malformed
        // responses, BLE failures, permission loss and disconnect. Embed it in
        // the causal event's transaction instead of a second fallible write.
        let terminal = snapshot?.interactive?.control.last
        let newTerminal = terminal.flatMap {
            recordedProcedureTerminals.contains($0.id) ? nil : $0.terminalEvidence
        }
        if let newTerminal { payload["procedureTerminal"] = .object(newTerminal) }
        do {
            try store.record(
                kind: kind, source: source, payload: payload, device: snapshot, eventId: eventId)
            if newTerminal != nil, let terminal { recordedProcedureTerminals.insert(terminal.id) }
            return true
        } catch {
            stopForPersistenceFailure(error.localizedDescription)
            return false
        }
    }

    private func stopForPersistenceFailure(_ message: String) {
        errorMessage = "No se pudo guardar la evidencia: \(message). La exploración se detuvo."
        scanTask?.cancel()
        deadlineTask?.cancel()
        subscriptionTask?.cancel()
        central?.stopScan()
        pendingScan = nil
        waitingForPermission = false
        if let active {
            central?.cancelPeripheralConnection(active)
            phase = .disconnecting
        } else {
            phase = .failed
        }
    }

    private func recordRequest(
        _ operation: String, object: AnyObject, reference: [String: JSONValue] = [:]
    ) -> Bool {
        var payload = reference
        payload["operation"] = .string(operation)
        payload["operationId"] = operations[ObjectIdentifier(object)].map(JSONValue.string) ?? .null
        return record("ble.operation.requested", payload: payload)
    }

    private func reference(_ s: Int, _ c: Int) -> [String: JSONValue] {
        guard let service = snapshot?.services[s] else { return [:] }
        let characteristic = service.characteristics[c]
        return [
            "serviceId": .string(service.id), "serviceUUID": .string(service.uuid),
            "characteristicId": .string(characteristic.id),
            "characteristicUUID": .string(characteristic.uuid),
        ]
    }

    private func failurePayload(_ error: (any Error)?) -> [String: JSONValue] {
        guard let error else { return ["error": .null] }
        let failure = BLEFailure(error)
        return [
            "error": .object([
                "domain": .string(failure.domain), "code": .number(Double(failure.code)),
                "message": .string(failure.message),
            ])
        ]
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined() }

    private func json<T: Encodable>(_ value: T?) -> JSONValue {
        guard let value, let bytes = try? EvidenceJSON.encoder().encode(value),
            let decoded = try? EvidenceJSON.decoder().decode(JSONValue.self, from: bytes)
        else { return .null }
        return decoded
    }

    private func properties(_ p: CBCharacteristicProperties) -> [String] {
        let values: [(CBCharacteristicProperties, String)] = [
            (.broadcast, "broadcast"), (.read, "read"), (.writeWithoutResponse, "writeWithoutResponse"),
            (.write, "write"), (.notify, "notify"), (.indicate, "indicate"),
            (.authenticatedSignedWrites, "authenticatedSignedWrites"),
            (.extendedProperties, "extendedProperties"),
            (.notifyEncryptionRequired, "notifyEncryptionRequired"),
            (.indicateEncryptionRequired, "indicateEncryptionRequired"),
        ]
        return values.filter { p.contains($0.0) }.map(\.1)
    }
}

// Interactive operations share the same peripheral/connection and evidence log.
// There is no second controller, movement queue, auto-start, or retry loop.
extension BluetoothExplorer {
    public var selectedProtocol: DiagnosticProtocol {
        snapshot?.interactive?.selectedProtocol ?? .ftms
    }
    public var control: FTMSControl { snapshot?.interactive?.control ?? FTMSControl() }
    public var fitShowQueryPending: Bool { fitShowQueries[selectedProtocol] != nil }

    public func selectProtocol(_ value: DiagnosticProtocol) {
        guard phase == .ready, control.canSelectProtocol else {
            errorMessage = "Termina la prueba pendiente y confirma parada antes de cambiar de protocolo."
            return
        }
        guard selectedProtocol != value else { return }
        snapshot?.interactive?.selectedProtocol = value
        // Switching never transfers control authority to another protocol.
        snapshot?.interactive?.control = FTMSControl()
        snapshot?.interactive?.control.indicationReady =
            controlPoint?.isNotifying == true && statusPoint?.isNotifying == true
        _ = record(
            "diagnostic.protocol.selected",
            payload: [
                "protocol": .string(value.title),
                "reason": .string(
                    "Selección explícita; no se envía movimiento ni se transfiere permiso de control."),
            ])
    }

    public func prepareControl() {
        guard phase == .ready, selectedProtocol == .ftms, let active,
            !control.requiresReconnect, control.pending == nil
        else { return }
        errorMessage = nil
        guard let cp = knownCharacteristic(service: "1826", uuid: "2AD9"),
            cp.properties.contains(.write), cp.properties.contains(.indicate),
            let status = knownCharacteristic(service: "1826", uuid: "2ADA"),
            status.properties.contains(.notify)
        else {
            errorMessage =
                "Se necesitan Control Point con write/indicate y Fitness Machine Status con notify."
            return
        }
        controlPoint = cp
        statusPoint = status
        guard
            record(
                "ftms.control.subscription.requested",
                payload: channelReference(cp).merging(
                    [
                        "statusCharacteristicUUID": .string("2ADA"),
                        "reason": .string("Preparar respuestas y pérdida de permiso; no envía movimiento."),
                    ], uniquingKeysWith: { _, new in new }))
        else { return }
        active.setNotifyValue(true, for: cp)
        active.setNotifyValue(true, for: status)
        controlSubscriptionTask?.cancel()
        controlSubscriptionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.phase == .ready, !self.control.indicationReady else { return }
            self.snapshot?.interactive?.control.fail("Suscripciones de control sin confirmar.")
            _ = self.record(
                "ftms.control.subscription.timeout",
                payload: ["reason": .string("Sin confirmación en diez segundos; no se reintenta.")])
        }
    }

    public func prepareControlAndWait(timeout: Duration = .seconds(10)) async throws {
        guard phase == .ready, hasConnection, selectedProtocol == .ftms,
            control.pending == nil, !control.requiresReconnect
        else {
            throw ControlError.blocked("No hay conexión FTMS lista para preparar el control.")
        }
        if control.indicationReady, controlPoint?.isNotifying == true, statusPoint?.isNotifying == true {
            return
        }
        prepareControl()
        guard phase == .ready, hasConnection, controlPoint != nil, statusPoint != nil,
            !control.requiresReconnect
        else {
            throw ControlError.blocked(errorMessage ?? "No se pudo preparar el canal FTMS.")
        }
        try await ControlPreparationGate.wait(
            timeout: timeout,
            ready: { [weak self] in
                guard let self else { return false }
                return self.control.indicationReady && self.controlPoint?.isNotifying == true
                    && self.statusPoint?.isNotifying == true
            },
            available: { [weak self] in
                guard let self else { return false }
                return self.phase == .ready && !self.control.requiresReconnect && self.hasConnection
            })
    }

    /// Serial runtime command helper. It returns only after both the BLE write
    /// callback and the matching FTMS response; no timeout or disconnect retries.
    public func executeAndWait(
        _ action: FTMSAction, speed: Double? = nil,
        inclination: Double? = nil, allowProgramBackground: Bool = false,
        timeout: Duration = .seconds(10)
    ) async throws -> FTMSProcedure {
        let foreground = UIApplication.shared.applicationState == .active
        guard phase == .ready, selectedProtocol == .ftms, hasConnection,
            foreground || (allowProgramBackground && programBackgroundLease)
        else {
            throw ControlError.blocked("El canal FTMS no está disponible para esta acción.")
        }
        let procedure = try await submitControl(
            action, speed: speed, inclination: inclination,
            allowProgramBackground: allowProgramBackground)
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            guard let pending = control.pending, pending.id == procedure.id else {
                if let last = control.last, last.id == procedure.id {
                    if last.writeStatus == "pending" {
                        try await Task.sleep(for: .milliseconds(50))
                        continue
                    }
                    guard last.writeStatus == "acknowledgedByBLE" else {
                        throw ControlError.blocked(
                            "La escritura BLE falló; el resultado físico se conserva como incierto.")
                    }
                    guard last.result == "acceptedByProtocol" else {
                        throw ControlError.blocked("FTMS rechazó \(action.title); no se reintenta.")
                    }
                    return last
                }
                throw ControlError.blocked("El procedimiento quedó indeterminado; no se reintenta.")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ControlError.blocked("FTMS no respondió a \(action.title); no se reintenta.")
    }

    public func execute(_ action: FTMSAction, speed: Double? = nil, inclination: Double? = nil) {
        guard phase == .ready, selectedProtocol == .ftms, active != nil, controlPoint != nil,
            UIApplication.shared.applicationState == .active
        else {
            errorMessage = "Conecta y mantén la app visible para una prueba de control."
            return
        }
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.submitControl(action, speed: speed, inclination: inclination)
            } catch {
                self.errorMessage = error.localizedDescription
                _ = self.record(
                    "ftms.control.blocked",
                    payload: [
                        "action": .string(action.rawValue), "reason": .string(error.localizedDescription),
                        "operatorAuthorized": .bool(true),
                    ])
            }
        }
    }

    private func submitControl(
        _ action: FTMSAction, speed: Double? = nil, inclination: Double? = nil,
        allowProgramBackground: Bool = false
    ) async throws -> FTMSProcedure {
        guard let active, let controlPoint else {
            throw ControlError.blocked("Prepara primero el canal FTMS.")
        }
        var next = control
        let previous = next.pending
        let procedure = try next.begin(
            action, authorized: true, speed: speed, range: snapshot?.speedRange,
            speedAdvertised: snapshot?.speedControlAdvertised ?? false,
            inclination: inclination, inclinationRange: snapshot?.inclinationRange,
            inclinationAdvertised: snapshot?.inclinationControlAdvertised ?? false,
            observedSpeed: snapshot?.telemetry?.speed)
        snapshot?.interactive?.control = next
        if let previous, action == .stop {
            try await store.recordDurably(
                kind: "ftms.control.superseded",
                payload: [
                    "procedureId": .string(previous.id),
                    "reason": .string(
                        "Parada explícita priorizada; el procedimiento anterior queda indeterminado."),
                ], device: snapshot)
        }
        let payload = channelReference(controlPoint).merging(
            [
                "procedureId": .string(procedure.id), "action": .string(action.rawValue),
                "opcode": .number(Double(action.opcode)), "direction": .string("sent"),
                "writeType": .string("withResponse"), "valueHex": .string(procedure.valueHex),
                "requestedSpeedKilometersPerHour": speed.map(JSONValue.number) ?? .null,
                "requestedInclinationPercent": inclination.map(JSONValue.number) ?? .null,
                "operatorAuthorized": .bool(true),
            ], uniquingKeysWith: { _, new in new })
        guard let bytes = Data(hex: procedure.valueHex) else {
            snapshot?.interactive?.control.fail(
                procedureId: procedure.id, reason: "No se pudo registrar la solicitud antes de escribir.")
            throw ControlError.blocked("No se pudo conservar la solicitud. No se envió el comando.")
        }
        do {
            var evidence = payload
            evidence["protocol"] = .string("FTMS")
            if let snapshot {
                evidence["localPeripheralIdentifier"] = .string(snapshot.localPeripheralIdentifier)
                evidence["inspectionId"] = .string(snapshot.inspectionId)
            }
            try await store.recordDurably(
                kind: "ftms.control.requested", payload: evidence, device: snapshot)
        } catch {
            snapshot?.interactive?.control.fail(
                procedureId: procedure.id, reason: "No se pudo registrar la solicitud antes de escribir.")
            throw ControlError.blocked(
                "No se pudo conservar la solicitud. No se envió el comando: \(error.localizedDescription)")
        }
        try Task.checkCancellation()
        guard phase == .ready, hasConnection, self.active === active,
            self.controlPoint === controlPoint,
            control.pending?.id == procedure.id, !control.requiresReconnect,
            UIApplication.shared.applicationState == .active
                || (allowProgramBackground && programBackgroundLease)
        else {
            snapshot?.interactive?.control.fail(
                procedureId: procedure.id, reason: "El canal cambió antes de escribir.")
            throw ControlError.blocked("El canal cambió antes de escribir; no se envió el comando.")
        }
        writeQueue.append((procedure.id, procedure.valueHex, .ftms))
        active.writeValue(bytes, for: controlPoint, type: .withResponse)
        controlTask?.cancel()
        controlTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.control.pending?.id == procedure.id else { return }
            self.snapshot?.interactive?.control.fail(
                procedureId: procedure.id, reason: "Respuesta FTMS sin confirmar en diez segundos.")
            _ = self.record(
                "ftms.control.timeout",
                payload: [
                    "procedureId": .string(procedure.id),
                    "reason": .string("Resultado indeterminado; sin reintento ni movimiento en cola."),
                ])
        }
        return procedure
    }

    public func listenFitShow() {
        let channel = selectedProtocol
        guard channel != .ftms, phase == .ready, let active,
            let rx = knownCharacteristic(service: channel.serviceUUID, uuid: channel.notifyUUID),
            rx.properties.contains(.notify),
            let tx = knownCharacteristic(service: channel.serviceUUID, uuid: channel.writeUUID),
            tx.properties.contains(.write) || tx.properties.contains(.writeWithoutResponse),
            let (s, c) = characteristicIndices[ObjectIdentifier(rx)],
            let (txService, w) = characteristicIndices[ObjectIdentifier(tx)], txService == s
        else {
            errorMessage = "El canal seleccionado no tiene el par conocido de escritura y notificaciones."
            return
        }
        if snapshot?.interactive?.fitShow.contains(where: { $0.channel == channel }) == true { return }
        let observed = FitShowObservation(
            channel: channel, serviceId: snapshot!.services[s].id,
            writeCharacteristicId: snapshot!.services[s].characteristics[w].id,
            notifyCharacteristicId: snapshot!.services[s].characteristics[c].id)
        snapshot?.interactive?.fitShow.append(observed)
        fitShowAssemblers[channel] = FitShowAssembler()
        guard
            record(
                "fitshow.subscription.requested",
                payload: channelReference(rx).merging(
                    [
                        "protocol": .string(channel.title),
                        "reason": .string(
                            "Escucha pasiva de un canal conocido de QZ; control propietario deshabilitado."),
                    ], uniquingKeysWith: { _, new in new }))
        else { return }
        active.setNotifyValue(true, for: rx)
        fitShowTasks[channel] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, let index = self.fitShowIndex(channel),
                self.snapshot?.interactive?.fitShow[index].subscriptionStatus == "pending"
            else { return }
            self.snapshot?.interactive?.fitShow[index].subscriptionStatus = "timedOut"
            _ = self.record(
                "fitshow.subscription.timeout",
                payload: [
                    "protocol": .string(channel.title),
                    "reason": .string("Escucha sin confirmar; sin reintento automático."),
                ])
        }
    }

    public func queryFitShowRange() {
        let channel = selectedProtocol
        guard channel != .ftms, phase == .ready, let active, let index = fitShowIndex(channel),
            snapshot?.interactive?.fitShow[index].subscriptionStatus == "active",
            let tx = knownCharacteristic(service: channel.serviceUUID, uuid: channel.writeUUID),
            fitShowQueries[channel] == nil, UIApplication.shared.applicationState == .active
        else {
            errorMessage = "Activa la escucha del canal y espera la consulta anterior antes de consultar."
            return
        }
        let type: CBCharacteristicWriteType =
            tx.properties.contains(.write) ? .withResponse : .withoutResponse
        guard type == .withResponse || active.canSendWriteWithoutResponse else {
            errorMessage =
                "Bluetooth no admite otra escritura ahora. No se encola ni reintenta la consulta."
            return
        }
        let bytes = FitShowProtocol.speedRangeQuery()
        let id = UUID().uuidString.lowercased()
        let now = Date()
        fitShowQueries[channel] = (id, true, now)
        snapshot?.reception?.lastQueryId = id
        snapshot?.reception?.lastQueryAt = now
        snapshot?.reception?.lastQueryHex = bytes.hex
        snapshot?.reception?.lastQueryChannel = channel.title
        guard
            record(
                "fitshow.query.requested",
                payload: channelReference(tx).merging(
                    [
                        "protocol": .string(channel.title), "queryId": .string(id),
                        "direction": .string("sent"),
                        "valueHex": .string(bytes.hex),
                        "writeType": .string(type == .withResponse ? "withResponse" : "withoutResponse"),
                        "query": .string("speedRange"), "operatorAuthorized": .bool(true),
                        "referenceRevision": .string(FitShowProtocol.referenceRevision),
                        "motorCommand": .bool(false),
                    ], uniquingKeysWith: { _, new in new }))
        else { return }
        if type == .withResponse { writeQueue.append((id, bytes.hex, channel)) }
        active.writeValue(bytes, for: tx, type: type)
        fitShowTasks[channel]?.cancel()
        fitShowTasks[channel] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.fitShowQueries[channel]?.id == id else { return }
            self.fitShowQueries.removeValue(forKey: channel)
            _ = self.record(
                "fitshow.query.timeout",
                payload: [
                    "protocol": .string(channel.title), "queryId": .string(id),
                    "reason": .string("Sin respuesta compatible; no se reintenta ni inicializa el motor."),
                ])
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard active === peripheral,
            let channel = DiagnosticProtocol.allCases.first(where: {
                $0.writeUUID == characteristic.uuid.uuidString
                    && $0.serviceUUID == characteristic.service?.uuid.uuidString
            }),
            let queueIndex = writeQueue.firstIndex(where: { $0.protocolId == channel })
        else { return }
        let first = writeQueue.remove(at: queueIndex)
        if channel == .ftms {
            snapshot?.interactive?.control.written(
                procedureId: first.id, error: error?.localizedDescription)
        }
        if channel != .ftms, error != nil { fitShowQueries.removeValue(forKey: channel) }
        _ = record(
            channel == .ftms ? "ftms.control.written" : "fitshow.query.written", source: .hardware,
            payload: channelReference(characteristic).merging(
                [
                    "protocol": .string(channel.title), "operationId": .string(first.id),
                    "valueHex": .string(first.hex),
                    "error": error.map { .string($0.localizedDescription) } ?? .null,
                    "reason": .string("Confirmación BLE; no confirma ejecución física."),
                ], uniquingKeysWith: { _, new in new }))
    }

    private func handleInteractiveSubscription(
        _ characteristic: CBCharacteristic, error: (any Error)?
    ) -> Bool {
        if characteristic === controlPoint || characteristic === statusPoint {
            snapshot?.interactive?.control.indicationReady =
                error == nil && controlPoint?.isNotifying == true && statusPoint?.isNotifying == true
            if error != nil || !characteristic.isNotifying {
                snapshot?.interactive?.control.permissionLost()
            }
            if control.indicationReady { controlSubscriptionTask?.cancel() }
            _ = record(
                "ftms.control.subscription.updated", source: .hardware,
                payload: channelReference(characteristic).merging(
                    [
                        "isNotifying": .bool(characteristic.isNotifying),
                        "error": error.map { .string($0.localizedDescription) } ?? .null,
                    ], uniquingKeysWith: { _, new in new }))
            return true
        }
        guard let channel = fitShowChannel(characteristic), let index = fitShowIndex(channel) else {
            return false
        }
        snapshot?.interactive?.fitShow[index].subscriptionStatus =
            error == nil && characteristic.isNotifying ? "active" : "failed"
        if error == nil && characteristic.isNotifying {
            snapshot?.reception?.subscribe(channel.title, at: Date())
        }
        fitShowTasks[channel]?.cancel()
        _ = record(
            "fitshow.subscription.updated", source: .hardware,
            payload: channelReference(characteristic).merging(
                [
                    "protocol": .string(channel.title), "isNotifying": .bool(characteristic.isNotifying),
                    "error": error.map { .string($0.localizedDescription) } ?? .null,
                ], uniquingKeysWith: { _, new in new }))
        return true
    }

    private func handleInteractiveValue(_ characteristic: CBCharacteristic, error: (any Error)?)
        -> Bool
    {
        if characteristic === controlPoint || characteristic === statusPoint {
            let id = UUID().uuidString.lowercased()
            var payload = channelReference(characteristic).merging(
                failurePayload(error), uniquingKeysWith: { _, new in new })
            payload["direction"] = .string("received")
            payload["valueHex"] = characteristic.value.map { .string($0.hex) } ?? .null
            if characteristic === controlPoint {
                let pending = control.pending
                do {
                    if let error {
                        snapshot?.interactive?.control.fail(error.localizedDescription)
                    } else if let data = characteristic.value {
                        let matched = try snapshot?.interactive?.control.response(data, eventId: id) ?? false
                        payload["matchedPendingProcedure"] = .bool(matched)
                        payload["procedureId"] = matched ? pending.map { .string($0.id) } ?? .null : .null
                        if matched { controlTask?.cancel() }
                    }
                } catch { payload["decodeError"] = .string(error.localizedDescription) }
            } else if let data = characteristic.value, data.first == 0xFF {
                snapshot?.interactive?.control.permissionLost()
                controlTask?.cancel()
                payload["reason"] = .string("Control Permission Lost; se invalida autorización.")
            }
            _ = record(
                characteristic === controlPoint ? "ftms.control.response" : "ftms.machine.status",
                source: .hardware, payload: payload, eventId: id)
            return true
        }
        guard let channel = fitShowChannel(characteristic), let index = fitShowIndex(channel) else {
            return false
        }
        let id = UUID().uuidString.lowercased()
        let date = Date()
        let resumed =
            error == nil && characteristic.value != nil
            && observeReception(channel.title, at: date, eventId: id)
        snapshot?.interactive?.fitShow[index].notificationCount += 1
        snapshot?.interactive?.fitShow[index].lastReceivedAt = date
        snapshot?.interactive?.fitShow[index].lastHex = characteristic.value?.hex
        var payload = channelReference(characteristic).merging(
            failurePayload(error), uniquingKeysWith: { _, new in new })
        if resumed {
            payload["receptionResumed"] = .bool(true)
            payload["reception"] = json(snapshot?.reception)
        }
        payload["protocol"] = .string(channel.title)
        payload["direction"] = .string("received")
        payload["valueHex"] = characteristic.value.map { .string($0.hex) } ?? .null
        payload["decoderId"] = .string(FitShowProtocol.decoderId)
        do {
            if let error { throw error }
            guard let data = characteristic.value else { throw FitShowError.invalidFrame }
            let messages = try fitShowAssemblers[channel, default: FitShowAssembler()].receive(data)
            if !messages.isEmpty { snapshot?.interactive?.fitShow[index].lastError = nil }
            payload["messages"] = json(messages)
            payload["waitingForFragment"] = .bool(messages.isEmpty)
            for message in messages {
                let query = fitShowQueries[channel]
                let matched =
                    query != nil && (0...5).contains(date.timeIntervalSince(query!.date))
                    && (query!.range
                        ? message.family == 0x50 && message.parameter == 2 && message.recognized
                        : message.family == 0x51 && message.recognized)
                snapshot?.interactive?.fitShow[index].observe(
                    message, eventId: id, matchedRangeQuery: matched && query?.range == true, at: date)
                if matched {
                    payload["queryId"] = .string(query!.id)
                    fitShowQueries.removeValue(forKey: channel)
                    fitShowTasks[channel]?.cancel()
                }
            }
        } catch {
            snapshot?.interactive?.fitShow[index].rejectedCount += 1
            snapshot?.interactive?.fitShow[index].lastError = error.localizedDescription
            payload["decodeError"] = .string(error.localizedDescription)
        }
        _ = record("fitshow.notification.received", source: .hardware, payload: payload, eventId: id)
        return true
    }

    private func knownCharacteristic(service uuid: String, uuid characteristicUUID: String)
        -> CBCharacteristic?
    {
        let candidates = (active?.services ?? []).filter { $0.uuid.uuidString == uuid }
            .flatMap { $0.characteristics ?? [] }.filter { $0.uuid.uuidString == characteristicUUID }
        // Duplicate UUID instances are ambiguous; never choose one silently.
        return candidates.count == 1 ? candidates[0] : nil
    }
    private func channelReference(_ characteristic: CBCharacteristic) -> [String: JSONValue] {
        guard let (s, c) = characteristicIndices[ObjectIdentifier(characteristic)] else { return [:] }
        return reference(s, c)
    }
    private func fitShowChannel(_ characteristic: CBCharacteristic) -> DiagnosticProtocol? {
        DiagnosticProtocol.allCases.first {
            $0 != .ftms && $0.notifyUUID == characteristic.uuid.uuidString
                && $0.serviceUUID == characteristic.service?.uuid.uuidString
        }
    }
    private func fitShowIndex(_ channel: DiagnosticProtocol) -> Int? {
        snapshot?.interactive?.fitShow.firstIndex { $0.channel == channel }
    }
}

/// The BLE delegate owns the readiness flag. Check it before the deadline so
/// an acknowledgement delivered at the boundary is not reported as a timeout.
enum ControlPreparationGate {
    @MainActor static func wait(
        timeout: Duration,
        ready: @escaping @MainActor () -> Bool,
        available: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if ready() { return }
            guard available() else {
                throw ControlError.blocked("Se perdió la conexión mientras se preparaba el control.")
            }
            guard clock.now < deadline else {
                throw ControlError.blocked(
                    "No se confirmaron las suscripciones FTMS dentro del plazo solicitado.")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
