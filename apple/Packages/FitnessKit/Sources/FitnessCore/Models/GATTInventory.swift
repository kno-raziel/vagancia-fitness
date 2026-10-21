import Foundation

// Evidence models deliberately have no CoreBluetooth or SwiftUI dependency.
public struct BLEFailure: Codable, Equatable, Sendable {
    public let domain: String
    public let code: Int
    public let message: String

    public init(_ error: any Error) {
        let error = error as NSError
        domain = error.domain
        code = error.code
        message = error.localizedDescription
    }
}

public struct GATTDescriptor: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let uuid: String

    public init(
        id: String,
        uuid: String
    ) {
        self.id = id
        self.uuid = uuid
    }
}

public struct GATTCharacteristic: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let uuid: String
    public let properties: [String]
    public let rawProperties: UInt
    public var descriptorDiscovery = "pending"
    public var descriptors: [GATTDescriptor] = []
    public var error: BLEFailure?
    public var readStatus: String?
    public var valueHex: String?
    public var textValue: String?
    public var readError: BLEFailure?
    public var readAt: Date?
    public var valueEventId: String?
    public var ftmsFeatures: FTMSFeatures?
    public var ftmsRange: FTMSRange?
    public var decodeError: String?

    public init(
        id: String,
        uuid: String,
        properties: [String],
        rawProperties: UInt,
        descriptorDiscovery: String = "pending",
        descriptors: [GATTDescriptor] = [],
        error: BLEFailure? = nil,
        readStatus: String? = nil,
        valueHex: String? = nil,
        textValue: String? = nil,
        readError: BLEFailure? = nil,
        readAt: Date? = nil,
        valueEventId: String? = nil,
        ftmsFeatures: FTMSFeatures? = nil,
        ftmsRange: FTMSRange? = nil,
        decodeError: String? = nil
    ) {
        self.id = id
        self.uuid = uuid
        self.properties = properties
        self.rawProperties = rawProperties
        self.descriptorDiscovery = descriptorDiscovery
        self.descriptors = descriptors
        self.error = error
        self.readStatus = readStatus
        self.valueHex = valueHex
        self.textValue = textValue
        self.readError = readError
        self.readAt = readAt
        self.valueEventId = valueEventId
        self.ftmsFeatures = ftmsFeatures
        self.ftmsRange = ftmsRange
        self.decodeError = decodeError
    }
}

public struct GATTService: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let uuid: String
    public let isPrimary: Bool
    public var characteristicDiscovery = "pending"
    public var characteristics: [GATTCharacteristic] = []
    public var error: BLEFailure?

    public init(
        id: String,
        uuid: String,
        isPrimary: Bool,
        characteristicDiscovery: String = "pending",
        characteristics: [GATTCharacteristic] = [],
        error: BLEFailure? = nil
    ) {
        self.id = id
        self.uuid = uuid
        self.isPrimary = isPrimary
        self.characteristicDiscovery = characteristicDiscovery
        self.characteristics = characteristics
        self.error = error
    }
}

public struct GATTDevice: Codable, Equatable, Sendable {
    public let localPeripheralIdentifier: String
    public let inspectionId: String
    public let advertisedName: String?
    public let advertisement: [String: JSONValue]
    public let selectedAt: Date
    public var source: EvidenceSource = .hardware
    public var connectedAt: Date?
    public var connectionState = "connecting"
    public var serviceDiscovery = "pending"
    public var discoveryStatus = "pending"
    public var services: [GATTService] = []
    public var error: BLEFailure?
    public var telemetry: FTMSTelemetry?
    public var interactive: InteractiveEvidence?
    public var reception: ReceptionHealth?

    public var speedRange: FTMSRange? {
        services.filter { $0.uuid == "1826" }.flatMap(\.characteristics).first { $0.uuid == "2AD4" }?
            .ftmsRange
    }
    public var speedControlAdvertised: Bool {
        services.filter { $0.uuid == "1826" }.flatMap(\.characteristics).contains {
            ($0.ftmsFeatures?.targetBits ?? 0) & 1 != 0
        }
    }
    public var inclinationRange: FTMSRange? {
        services.filter { $0.uuid == "1826" }.flatMap(\.characteristics).first { $0.uuid == "2AD5" }?
            .ftmsRange
    }
    public var inclinationControlAdvertised: Bool {
        services.filter { $0.uuid == "1826" }.flatMap(\.characteristics).contains {
            ($0.ftmsFeatures?.targetBits ?? 0) & (1 << 1) != 0
        }
    }

    public var containsFTMS: Bool { services.contains { $0.uuid == "1826" } }
    public var characteristicCount: Int { services.reduce(0) { $0 + $1.characteristics.count } }
    public var manufacturer: String? { identity("2A29") }
    public var moduleModel: String? { identity("2A24") }
    public var firmware: String? { identity("2A26") }

    private func identity(_ uuid: String) -> String? {
        services.filter { $0.uuid == "180A" }.flatMap(\.characteristics)
            .first { $0.uuid == uuid && $0.readStatus == "complete" }?.textValue
    }

    // Only these standard Device Information strings may be read in this delivery.
    public static let identityUUIDs: Set<String> = ["2A29", "2A24", "2A26", "2A27", "2A28"]

    public mutating func endPendingDiscovery(as status: String) {
        if serviceDiscovery == "pending" { serviceDiscovery = status }
        for s in services.indices {
            if services[s].characteristicDiscovery == "pending" {
                services[s].characteristicDiscovery = status
            }
            for c in services[s].characteristics.indices {
                if services[s].characteristics[c].descriptorDiscovery == "pending" {
                    services[s].characteristics[c].descriptorDiscovery = status
                }
                if services[s].characteristics[c].readStatus == "pending" {
                    services[s].characteristics[c].readStatus = status
                }
            }
        }
        if discoveryStatus == "pending" { discoveryStatus = status }
    }

    public mutating func interruptTelemetry() {
        if telemetry != nil { telemetry?.subscriptionStatus = "interrupted" }
        interactive?.control.disconnected()
        if interactive != nil {
            for index in interactive!.fitShow.indices {
                interactive?.fitShow[index].subscriptionStatus = "interrupted"
            }
        }
    }

    public init(
        localPeripheralIdentifier: String,
        inspectionId: String,
        advertisedName: String?,
        advertisement: [String: JSONValue],
        selectedAt: Date,
        source: EvidenceSource = .hardware,
        connectedAt: Date? = nil,
        connectionState: String = "connecting",
        serviceDiscovery: String = "pending",
        discoveryStatus: String = "pending",
        services: [GATTService] = [],
        error: BLEFailure? = nil,
        telemetry: FTMSTelemetry? = nil,
        interactive: InteractiveEvidence? = nil,
        reception: ReceptionHealth? = nil
    ) {
        self.localPeripheralIdentifier = localPeripheralIdentifier
        self.inspectionId = inspectionId
        self.advertisedName = advertisedName
        self.advertisement = advertisement
        self.selectedAt = selectedAt
        self.source = source
        self.connectedAt = connectedAt
        self.connectionState = connectionState
        self.serviceDiscovery = serviceDiscovery
        self.discoveryStatus = discoveryStatus
        self.services = services
        self.error = error
        self.telemetry = telemetry
        self.interactive = interactive
        self.reception = reception
    }
}

public enum GATTNames {
    public static func name(_ uuid: String) -> String {
        switch uuid {
        case "1826": "Fitness Machine · FTMS"
        case "180A": "Información del dispositivo"
        case "180D": "Frecuencia cardíaca"
        case "180F": "Batería"
        case "2ACC": "Fitness Machine Feature"
        case "2ACD": "Treadmill Data"
        case "2AD9": "Fitness Machine Control Point"
        case "2ADA": "Fitness Machine Status"
        case "2AD3": "Training Status"
        case "2AD4": "Supported Speed Range"
        case "2AD5": "Supported Inclination Range"
        case "2AD7": "Supported Heart Rate Range"
        case "2AD8": "Supported Power Range"
        case "2A29": "Fabricante"
        case "2A24": "Modelo del módulo"
        case "2A26": "Firmware"
        case "2A27": "Hardware"
        case "2A28": "Software"
        default: uuid
        }
    }
}
