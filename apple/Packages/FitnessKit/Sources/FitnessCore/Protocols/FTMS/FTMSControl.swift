import Foundation

public enum FTMSAction: String, Codable, Sendable {
    case requestControl, start, stop, speed, inclination
    public var opcode: UInt8 {
        switch self {
        case .requestControl: 0
        case .start: 7
        case .stop: 8
        case .speed: 2
        case .inclination: 3
        }
    }
    public var title: String {
        localizedTitle()
    }
    public func localizedTitle(locale: Locale? = nil) -> String {
        FitnessText.string("ftms.action.\(rawValue)", locale: locale)
    }
    fileprivate var evidenceTitle: String {
        switch self {
        case .requestControl: "Solicitar control"
        case .start: "Iniciar banda"
        case .stop: "Parar banda"
        case .speed: "Cambiar velocidad"
        case .inclination: "Cambiar inclinación"
        }
    }
}

public struct FTMSProcedure: Codable, Equatable, Sendable {
    public let id: String
    public let action: FTMSAction
    public let requestedAt: Date
    public let valueHex: String
    public var writeStatus = "pending"
    public var result = "pending"
    public var responseCode: UInt8?
    public var responseEventId: String?

    public var terminalEvidence: [String: JSONValue]? {
        guard result != "pending" else { return nil }
        return [
            "procedureId": .string(id), "action": .string(action.rawValue),
            "result": .string(result), "interpretationSource": .string("application"),
            "requestValueHex": .string(valueHex), "writeStatus": .string(writeStatus),
            "responseCode": responseCode.map { .number(Double($0)) } ?? .null,
            "responseEventId": responseEventId.map(JSONValue.string) ?? .null,
        ]
    }

    public init(
        id: String,
        action: FTMSAction,
        requestedAt: Date,
        valueHex: String,
        writeStatus: String = "pending",
        result: String = "pending",
        responseCode: UInt8? = nil,
        responseEventId: String? = nil
    ) {
        self.id = id
        self.action = action
        self.requestedAt = requestedAt
        self.valueHex = valueHex
        self.writeStatus = writeStatus
        self.result = result
        self.responseCode = responseCode
        self.responseEventId = responseEventId
    }
}

public enum ControlError: LocalizedError {
    case blocked(String)
    public var errorDescription: String? {
        if case .blocked(let message) = self { FitnessText.controlMessage(message) } else { nil }
    }
}

/// FTMS 1.0 §§4.16–4.17. No Bluetooth/UI, timers, queues, retries or side effects.
public struct FTMSControl: Codable, Equatable, Sendable {
    public var indicationReady = false
    public var permission = false
    public var stopAccepted = false
    public var requiresReconnect = false
    public var movementUncertain = false
    public var movementOutstanding = false
    /// A zero observed after the current Stop request belongs to this connection,
    /// even when its indication has not arrived yet.
    public private(set) var connectionGeneration = 0
    public private(set) var stopZeroObservedAt: Date?
    public private(set) var stopZeroGeneration: Int?
    public var pending: FTMSProcedure?
    public var last: FTMSProcedure?
    public var message = "Prepara el canal de control. No se enviará movimiento."
    public func localizedMessage(locale: Locale? = nil) -> String {
        FitnessText.controlMessage(message, locale: locale)
    }

    public var canStop: Bool { indicationReady && permission }
    public var canStart: Bool {
        canStop && stopAccepted && !requiresReconnect && pending == nil && !movementUncertain
    }
    public var canSelectProtocol: Bool {
        pending == nil && !movementUncertain && !movementOutstanding && !requiresReconnect
    }

    private enum CodingKeys: String, CodingKey {
        case indicationReady, permission, stopAccepted, requiresReconnect, movementUncertain
        case movementOutstanding, pending, last, message
        case connectionGeneration, stopZeroObservedAt, stopZeroGeneration
    }

    /// Sessions saved before the Stop ordering fix have no connection epoch or
    /// qualifying zero. Preserve their historical state without inventing one.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        indicationReady = try values.decode(Bool.self, forKey: .indicationReady)
        permission = try values.decode(Bool.self, forKey: .permission)
        stopAccepted = try values.decode(Bool.self, forKey: .stopAccepted)
        requiresReconnect = try values.decode(Bool.self, forKey: .requiresReconnect)
        movementUncertain = try values.decode(Bool.self, forKey: .movementUncertain)
        movementOutstanding = try values.decode(Bool.self, forKey: .movementOutstanding)
        pending = try values.decodeIfPresent(FTMSProcedure.self, forKey: .pending)
        last = try values.decodeIfPresent(FTMSProcedure.self, forKey: .last)
        message = try values.decode(String.self, forKey: .message)
        connectionGeneration = try values.decodeIfPresent(Int.self, forKey: .connectionGeneration) ?? 0
        stopZeroObservedAt = try values.decodeIfPresent(Date.self, forKey: .stopZeroObservedAt)
        stopZeroGeneration = try values.decodeIfPresent(Int.self, forKey: .stopZeroGeneration)
    }

    public mutating func begin(
        _ action: FTMSAction, authorized: Bool, speed: Double? = nil,
        range: FTMSRange? = nil, speedAdvertised: Bool = false,
        inclination: Double? = nil, inclinationRange: FTMSRange? = nil,
        inclinationAdvertised: Bool = false,
        observedSpeed: FTMSMetric? = nil, at now: Date = Date()
    ) throws -> FTMSProcedure {
        guard authorized else {
            throw ControlError.blocked("La prueba necesita una acción explícita del operador.")
        }
        guard indicationReady else {
            throw ControlError.blocked("Primero prepara las indicaciones FTMS.")
        }
        if action != .stop {
            guard pending == nil, !requiresReconnect else {
                throw ControlError.blocked(
                    "Hay una respuesta pendiente o incierta. Desconecta y prepara una conexión nueva.")
            }
        } else {
            guard canStop else {
                throw ControlError.blocked("La parada Bluetooth no está preparada. Usa la consola física.")
            }
            if requiresReconnect && last?.action == .stop {
                throw ControlError.blocked(
                    "La parada anterior quedó incierta. Usa la consola física; reconecta antes de otra prueba Bluetooth."
                )
            }
            if pending?.action == .stop {
                throw ControlError.blocked("La parada ya está pendiente; no se reenvía automáticamente.")
            }
            if var interrupted = pending {
                interrupted.result = "supersededByExplicitStop"
                last = interrupted
                pending = nil
                requiresReconnect = true
            }
        }
        if action != .requestControl {
            guard permission else {
                throw ControlError.blocked("La máquina todavía no concedió control FTMS.")
            }
        }
        var data = Data([action.opcode])
        switch action {
        case .requestControl: break
        case .stop: data.append(1)  // Stop, never Pause.
        case .start:
            guard canStart, let observedSpeed, !observedSpeed.isStale(at: now), observedSpeed.value == 0,
                stopZeroGeneration == connectionGeneration,
                let stopZeroObservedAt, observedSpeed.receivedAt >= stopZeroObservedAt
            else {
                throw ControlError.blocked(
                    "Prueba primero Parar y espera una velocidad reciente de 0 km/h.")
            }
        case .speed:
            guard stopAccepted, !movementUncertain, let observedSpeed, !observedSpeed.isStale(at: now),
                observedSpeed.value > 0
            else {
                throw ControlError.blocked(
                    "Espera velocidad reciente en movimiento antes de cambiar el objetivo.")
            }
            guard speedAdvertised, let range, range.unit == "km/h", range.increment.isFinite,
                range.increment > 0,
                let speed, speed.isFinite, speed >= range.minimum, speed <= range.maximum,
                speed * 100 <= Double(UInt16.max), speed >= 0
            else {
                throw ControlError.blocked(
                    "Objetivo fuera del rango de velocidad anunciado o rango no disponible.")
            }
            let steps = (speed - range.minimum) / range.increment
            guard abs(steps - steps.rounded()) < 0.000_01,
                abs(speed * 100 - (speed * 100).rounded()) < 0.000_01
            else {
                throw ControlError.blocked(
                    "El objetivo debe respetar el incremento anunciado; no se redondea silenciosamente.")
            }
            let value = UInt16((speed * 100).rounded())
            data.append(UInt8(value & 255))
            data.append(UInt8(value >> 8))
        case .inclination:
            guard stopAccepted, !movementUncertain, let observedSpeed, !observedSpeed.isStale(at: now),
                observedSpeed.value > 0
            else {
                throw ControlError.blocked(
                    "Espera velocidad reciente en movimiento antes de cambiar la inclinación.")
            }
            guard inclinationAdvertised, let range = inclinationRange, range.unit == "%",
                range.increment.isFinite,
                range.increment > 0, let inclination, inclination.isFinite,
                inclination >= range.minimum, inclination <= range.maximum,
                inclination * 10 >= Double(Int16.min), inclination * 10 <= Double(Int16.max)
            else {
                throw ControlError.blocked(
                    "Objetivo fuera del rango de inclinación anunciado o rango no disponible.")
            }
            let steps = (inclination - range.minimum) / range.increment
            guard abs(steps - steps.rounded()) < 0.000_01,
                abs(inclination * 10 - (inclination * 10).rounded()) < 0.000_01
            else {
                throw ControlError.blocked(
                    "El objetivo debe respetar el incremento anunciado; no se redondea silenciosamente.")
            }
            let value = UInt16(bitPattern: Int16((inclination * 10).rounded()))
            data.append(UInt8(value & 255))
            data.append(UInt8(value >> 8))
        }
        let procedure = FTMSProcedure(
            id: UUID().uuidString.lowercased(), action: action, requestedAt: now, valueHex: data.hex)
        pending = procedure
        if action == .stop {
            stopAccepted = false
            stopZeroObservedAt = nil
            stopZeroGeneration = nil
        } else if action == .start {
            stopZeroObservedAt = nil
            stopZeroGeneration = nil
        }
        if action == .start || action == .stop { movementUncertain = true }
        if action == .start || action == .speed || action == .inclination { movementOutstanding = true }
        message = "\(action.evidenceTitle): esperando respuesta del procedimiento."
        return procedure
    }

    public mutating func written(error: String?) {
        guard let id = pending?.id else { return }
        written(procedureId: id, error: error)
    }

    /// BLE write callbacks and FTMS indications are delivered independently.
    /// A fast indication may complete the procedure before CoreBluetooth reports
    /// the write callback; update the matching terminal procedure without losing
    /// its protocol response.
    public mutating func written(procedureId: String, error: String?) {
        if pending?.id == procedureId {
            pending?.writeStatus = error == nil ? "acknowledgedByBLE" : "failed"
            if let error { fail("Escritura fallida: \(error)") }
            return
        }
        guard var completed = last, completed.id == procedureId else { return }
        completed.writeStatus = error == nil ? "acknowledgedByBLE" : "failed"
        last = completed
        if let error {
            message =
                "La escritura BLE informó un error después de recibirse la respuesta FTMS: \(error). Se conserva la respuesta del protocolo."
        }
    }

    /// Returns false for uncorrelated/late indications; no command is retried.
    public mutating func response(_ bytes: Data, eventId: String) throws -> Bool {
        guard bytes.count == 3, bytes[0] == 0x80, (1...5).contains(bytes[2]) else {
            if pending != nil { fail("Respuesta FTMS malformada; resultado incierto.") }
            throw ControlError.blocked("Respuesta FTMS inválida. Se conservaron sus bytes.")
        }
        guard var procedure = pending, bytes[1] == procedure.action.opcode else { return false }
        procedure.responseCode = bytes[2]
        procedure.responseEventId = eventId
        procedure.result = bytes[2] == 1 ? "acceptedByProtocol" : "rejectedByProtocol"
        last = procedure
        pending = nil
        if bytes[2] == 1 {
            if procedure.action == .requestControl { permission = true }
            if procedure.action == .stop {
                stopAccepted = true
                if stopZeroGeneration == connectionGeneration, stopZeroObservedAt != nil {
                    movementUncertain = false
                    movementOutstanding = false
                }
            }
            message =
                "\(procedure.action.evidenceTitle): aceptado por FTMS; comprueba la respuesta de la banda."
        } else {
            if bytes[2] == 5 {
                permission = false
                stopAccepted = false
            }
            if procedure.action == .stop {
                stopAccepted = false
                stopZeroObservedAt = nil
                stopZeroGeneration = nil
            }
            message =
                "\(procedure.action.evidenceTitle): rechazado (código \(bytes[2])). No se reintenta."
            // Explicit rejection of Start means no start was accepted, but an
            // observed non-zero speed can still come from the physical console.
            if procedure.action == .start {
                movementUncertain = false
                movementOutstanding = false
            }
        }
        return true
    }

    public mutating func observed(_ speed: FTMSMetric?, at now: Date = Date()) {
        guard let speed, !speed.isStale(at: now) else { return }
        if let pending {
            if pending.action == .stop, speed.receivedAt > pending.requestedAt {
                if speed.value == 0 {
                    stopZeroObservedAt = speed.receivedAt
                    stopZeroGeneration = connectionGeneration
                } else {
                    stopZeroObservedAt = nil
                    stopZeroGeneration = nil
                }
            }
            return
        }
        if let last, speed.receivedAt <= last.requestedAt { return }
        // A START ack does not establish RUNNING. A fresh nonzero value does.
        if last?.action == .start && last?.result == "acceptedByProtocol" {
            if speed.value > 0 {
                movementUncertain = false
            } else if !movementUncertain {
                movementOutstanding = false
            }
        } else if last?.action == .stop, last?.result == "acceptedByProtocol" {
            if speed.value == 0 {
                stopZeroObservedAt = speed.receivedAt
                stopZeroGeneration = connectionGeneration
                movementUncertain = false
                movementOutstanding = false
            } else {
                stopZeroObservedAt = nil
                stopZeroGeneration = nil
                movementUncertain = true
            }
        } else if speed.value == 0 {
            movementUncertain = false
            movementOutstanding = false
        }
    }

    public mutating func fail(_ reason: String) {
        if var procedure = pending {
            procedure.result = "indeterminate"
            last = procedure
        }
        pending = nil
        requiresReconnect = true
        stopZeroObservedAt = nil
        stopZeroGeneration = nil
        message = reason + " No se reenvía; usa los controles físicos y reconecta para continuar."
    }

    /// An asynchronous completion for a superseded request must not invalidate
    /// a newer explicit Stop that is still awaiting its own durable write.
    @discardableResult
    public mutating func fail(procedureId: String, reason: String) -> Bool {
        guard pending?.id == procedureId else { return false }
        fail(reason)
        return true
    }

    public mutating func permissionLost() {
        fail("La máquina retiró el permiso de control.")
        permission = false
        stopAccepted = false
    }

    public mutating func disconnected() {
        if pending != nil { fail("La conexión se interrumpió con un procedimiento pendiente.") }
        indicationReady = false
        permission = false
        stopAccepted = false
        connectionGeneration += 1
        stopZeroObservedAt = nil
        stopZeroGeneration = nil
        message = "Control desconectado. Los resultados anteriores son históricos."
    }

    public init(
        indicationReady: Bool = false,
        permission: Bool = false,
        stopAccepted: Bool = false,
        requiresReconnect: Bool = false,
        movementUncertain: Bool = false,
        movementOutstanding: Bool = false,
        pending: FTMSProcedure? = nil,
        last: FTMSProcedure? = nil,
        message: String = "Prepara el canal de control. No se enviará movimiento."
    ) {
        self.indicationReady = indicationReady
        self.permission = permission
        self.stopAccepted = stopAccepted
        self.requiresReconnect = requiresReconnect
        self.movementUncertain = movementUncertain
        self.movementOutstanding = movementOutstanding
        self.pending = pending
        self.last = last
        self.message = message
    }
}

extension Data {
    public var hex: String { map { String(format: "%02X", $0) }.joined() }
    public init?(hex: String) {
        guard hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else { return nil }
        var result = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else { return nil }
            result.append(byte)
            index = end
        }
        self = result
    }
}
