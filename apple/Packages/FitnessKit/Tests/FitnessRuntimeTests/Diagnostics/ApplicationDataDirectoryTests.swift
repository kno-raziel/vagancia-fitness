import FitnessCore
import Foundation
import Testing

@testable import FitnessRuntime

@MainActor
struct ApplicationDataDirectoryTests {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func newInstallationUsesCurrentDirectoryWithoutCreatingAStore() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = ApplicationDataDirectory.resolve(in: root)
        #expect(result.lastPathComponent == "VaganciaFitness")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func migrationPreservesRoutinesHistoryDiagnosticsAndUnknownFiles() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent(ApplicationDataDirectory.legacyDirectoryName, isDirectory: true)
        let program = WorkoutProgram(
            name: "Rutina conservada",
            intervals: [
                .init(durationSeconds: 60, targetSpeedKPH: 2)
            ])
        let record = WorkoutRecord(
            mode: "program", program: program, latestSnapshot: WorkoutEngine(program: program).snapshot())
        try seedRepository(at: legacy, program: program, record: record)
        let sessionID = try await seedDiagnostics(at: legacy)
        let cached = Data("{\"fixture\":\"synthetic-cache\"}".utf8)
        try cached.write(to: legacy.appendingPathComponent("remembered-treadmill.json"))
        try cached.write(to: legacy.appendingPathComponent("workout-target-limits.json"))
        let unknown = legacy.appendingPathComponent("Future/nested.bin")
        try FileManager.default.createDirectory(
            at: unknown.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1, 254, 255]).write(to: unknown)

        let result = ApplicationDataDirectory.resolve(in: root)
        #expect(result.lastPathComponent == "VaganciaFitness")
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        let repository = try WorkoutRepository(directory: result)
        #expect(try repository.programs().map(\.id) == [program.id])
        #expect(try repository.history().map(\.id) == [record.id])
        let restored = SessionStore(directory: result)
        #expect(restored.storageReady)
        #expect(restored.session?.sessionId == sessionID)
        #expect(restored.session?.events.contains { $0.kind == "operator.note" } == true)
        #expect(try Data(contentsOf: result.appendingPathComponent("remembered-treadmill.json")) == cached)
        #expect(try Data(contentsOf: result.appendingPathComponent("workout-target-limits.json")) == cached)
        #expect(try Data(contentsOf: result.appendingPathComponent("Future/nested.bin")) == Data([0, 1, 254, 255]))
    }

    @Test func directoryRenameIncludesSQLiteSidecarsAndIsIdempotent() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent(ApplicationDataDirectory.legacyDirectoryName, isDirectory: true)
        let sessions = legacy.appendingPathComponent("Sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        for name in ["session-log.sqlite", "session-log.sqlite-wal", "session-log.sqlite-shm"] {
            try Data(name.utf8).write(to: sessions.appendingPathComponent(name))
        }
        let migrated = ApplicationDataDirectory.resolve(in: root)
        #expect(ApplicationDataDirectory.resolve(in: root) == migrated)
        for name in ["session-log.sqlite", "session-log.sqlite-wal", "session-log.sqlite-shm"] {
            #expect(try Data(contentsOf: migrated.appendingPathComponent("Sessions/\(name)")) == Data(name.utf8))
        }
    }

    @Test func competingDestinationDoesNotOverwriteEitherStore() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent(ApplicationDataDirectory.legacyDirectoryName, isDirectory: true)
        let current = root.appendingPathComponent(ApplicationDataDirectory.currentDirectoryName, isDirectory: true)
        for folder in [legacy, current] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(folder.lastPathComponent.utf8).write(to: folder.appendingPathComponent("marker"))
        }
        #expect(ApplicationDataDirectory.resolve(in: root) == legacy)
        for folder in [legacy, current] {
            #expect(
                try Data(contentsOf: folder.appendingPathComponent("marker")) == Data(folder.lastPathComponent.utf8))
        }
    }

    @Test func failedRenameContinuesUsingEstablishedStoreAndCanRecoverLater() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent(ApplicationDataDirectory.legacyDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data([42]).write(to: legacy.appendingPathComponent("marker"))
        let result = ApplicationDataDirectory.resolve(in: root) { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }
        #expect(result == legacy)
        #expect(try Data(contentsOf: result.appendingPathComponent("marker")) == Data([42]))
        let recovered = ApplicationDataDirectory.resolve(in: root)
        #expect(recovered.lastPathComponent == "VaganciaFitness")
        #expect(try Data(contentsOf: recovered.appendingPathComponent("marker")) == Data([42]))
    }

    @Test func existingCurrentStoreRemainsUntouched() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent(ApplicationDataDirectory.currentDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data([7]).write(to: current.appendingPathComponent("marker"))
        #expect(ApplicationDataDirectory.resolve(in: root) == current)
        #expect(try Data(contentsOf: current.appendingPathComponent("marker")) == Data([7]))
    }

    private func seedRepository(at directory: URL, program: WorkoutProgram, record: WorkoutRecord) throws {
        let repository = try WorkoutRepository(directory: directory)
        try repository.saveProgram(program)
        try repository.save(record)
    }

    private func seedDiagnostics(at directory: URL) async throws -> String {
        let store = SessionStore(directory: directory)
        try store.startSession()
        try store.addNote("Evidencia sintética conservada")
        let id = try #require(store.session?.sessionId)
        try store.closeSession()
        try await store.flush()
        return id
    }
}
