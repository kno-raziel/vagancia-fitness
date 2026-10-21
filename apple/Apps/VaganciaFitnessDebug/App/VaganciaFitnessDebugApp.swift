import FitnessCore
import FitnessRuntime
import SwiftUI
import UIKit

@main
struct VaganciaFitnessDebugApp: App {
    @State private var store: SessionStore
    @State private var bluetooth: BluetoothExplorer
    private let metadata: AppMetadata

    init() {
        let base: URL
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            base = FileManager.default.temporaryDirectory.appendingPathComponent(
                "UITests-\(UUID().uuidString)", isDirectory: true)
        } else {
            base = ApplicationDataDirectory.resolve()
        }
        let store = SessionStore(directory: base)
        #if DEBUG
            // UI fixtures are opt-in, isolated and always labelled synthetic.
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
                let json = ProcessInfo.processInfo.environment["VAGANCIA_FITNESS_INVENTORY_FIXTURE"],
                var fixture = try? EvidenceJSON.decoder().decode(GATTDevice.self, from: Data(json.utf8))
            {
                fixture.source = .synthetic
                fixture.connectionState = "notConnectedFixture"
                try? store.startSession()
                try? store.record(
                    kind: "synthetic.fixture", source: .synthetic,
                    payload: [
                        "reason": .string("Inventario sintético para probar la interfaz; sin hardware.")
                    ], device: fixture)
                if let replay = ProcessInfo.processInfo.environment["VAGANCIA_FITNESS_DISTANCE_REPLAY"] {
                    for value in replay.split(separator: ",").compactMap({ UInt32($0) })
                    where value <= 0xFFFFFF {
                        try? store.record(
                            kind: "ftms.treadmill.received", source: .synthetic,
                            payload: [
                                "inspectionId": .string(fixture.inspectionId),
                                "sample": .object(["distanceMeters": .number(Double(value))]),
                            ])
                    }
                }
                if let json = ProcessInfo.processInfo.environment["VAGANCIA_FITNESS_REMEMBERED_FIXTURE"],
                    let saved = try? JSONDecoder().decode(RememberedTreadmill.self, from: Data(json.utf8))
                {
                    try? RememberedTreadmillStorage(
                        url: base.appendingPathComponent("remembered-treadmill.json")
                    ).save(saved)
                }
            }
        #endif
        _store = State(initialValue: store)
        _bluetooth = State(initialValue: BluetoothExplorer(store: store))
        metadata = AppMetadata(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            osVersion: UIDevice.current.systemVersion,
            deviceModel: UIDevice.current.model
        )
    }

    var body: some Scene {
        WindowGroup {
            FitnessTabsView(store: store, explorer: bluetooth, metadata: metadata)
        }
    }
}
