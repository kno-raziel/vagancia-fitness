import Foundation
import Testing

@testable import FitnessCore
@testable import FitnessRuntime

struct RememberedTreadmillTests {
    @Test func preferenceRoundTripDefaultsToManualAndCanBeForgotten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = RememberedTreadmillStorage(url: dir.appendingPathComponent("device.json"))
        #expect(try storage.load() == nil)
        var saved = RememberedTreadmill(identifier: UUID(), name: "YK-03K45")
        #expect(!saved.connectOnOpen)
        try storage.save(saved)
        #expect(try storage.load() == saved)
        saved.connectOnOpen = true
        try storage.save(saved)
        #expect(try storage.load()?.connectOnOpen == true)
        try storage.save(nil)
        #expect(try storage.load() == nil)
    }

    @Test func startupConnectionIsOneAttemptAndNeverRetriesOnAnotherForeground() {
        var policy = ConnectOnOpenPolicy()
        let disabled = policy.claim(enabled: false, foreground: true, idle: true)
        let background = policy.claim(enabled: true, foreground: false, idle: true)
        let busy = policy.claim(enabled: true, foreground: true, idle: false)
        #expect(!disabled && !background && !busy && !policy.attempted)
        let first = policy.claim(enabled: true, foreground: true, idle: true)
        let later = policy.claim(enabled: true, foreground: true, idle: true)
        #expect(first && !later)
        var manual = ConnectOnOpenPolicy()
        manual.suppress()
        let afterDisconnect = manual.claim(enabled: true, foreground: true, idle: true)
        #expect(!afterDisconnect)
    }

    @MainActor @Test func historicalHardwareCanBeRememberedWithoutInitializingBluetooth() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        try store.startSession()
        let identifier = UUID()
        var device = GATTDevice(
            localPeripheralIdentifier: identifier.uuidString, inspectionId: "old",
            advertisedName: "YK-03K45", advertisement: [:], selectedAt: Date())
        device.services = [GATTService(id: "ftms", uuid: "1826", isPrimary: true)]
        try store.record(
            kind: "ble.discovery.finished", source: .hardware, payload: [:], device: device)
        let explorer = BluetoothExplorer(store: store)
        #expect(explorer.rememberedTreadmill?.identifier == identifier)
        #expect(explorer.rememberedTreadmill?.connectOnOpen == false)
        #expect(explorer.phase == .idle && explorer.radioStatus == "Bluetooth se activará al buscar.")
        #expect(
            !explorer.control.permission && explorer.control.pending == nil
                && !explorer.control.stopAccepted)
        explorer.setConnectOnOpen(true)
        let reloaded = BluetoothExplorer(store: store)
        #expect(reloaded.rememberedTreadmill?.connectOnOpen == true)
        reloaded.forgetTreadmill()
        #expect(reloaded.rememberedTreadmill == nil)
        let forgottenAfterRelaunch = BluetoothExplorer(store: store)
        #expect(forgottenAfterRelaunch.rememberedTreadmill == nil)
    }

    @Test func corruptPreferencesAreReportedAndNotSilentlyReplaced() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("broken".utf8).write(to: url)
        let storage = RememberedTreadmillStorage(url: url)
        #expect(throws: DecodingError.self) { try storage.load() }
        #expect(try String(contentsOf: url, encoding: .utf8) == "broken")
    }
}
