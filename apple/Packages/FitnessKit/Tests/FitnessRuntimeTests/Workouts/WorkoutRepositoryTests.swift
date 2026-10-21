import FitnessCore
import Foundation
import SQLite3
import Testing

@testable import FitnessRuntime

struct WorkoutRepositoryTests {
    @Test func deletingSeedProgramsIsDurableAndHistoryClearPreservesPrograms() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try WorkoutRepository(directory: directory)
        try repository.seedDefaultsIfNeeded(WorkoutProgram.seedPrograms)
        for program in try repository.programs() { try repository.deleteProgram(id: program.id) }
        let restored = try WorkoutRepository(directory: directory)
        try restored.seedDefaultsIfNeeded(WorkoutProgram.seedPrograms)
        #expect(try restored.programs().isEmpty)
        let program = WorkoutProgram(
            name: "Mi programa", intervals: [.init(durationSeconds: 15, targetSpeedKPH: 1)])
        try restored.saveProgram(program)
        let record = WorkoutRecord(
            mode: "program", program: program, latestSnapshot: WorkoutEngine(program: program).snapshot())
        try restored.save(record)
        try restored.clearHistory()
        #expect(try restored.history().isEmpty)
        #expect(try restored.programs().map(\.id) == [program.id])
    }

    @Test func duplicateEvidenceRollsBackSamplesAndSnapshotTogether() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try WorkoutRepository(directory: directory)
        let program = WorkoutProgram.seedPrograms[0]
        let record = WorkoutRecord(
            mode: "program", program: program, latestSnapshot: WorkoutEngine(program: program).snapshot())
        let sample = WorkoutRecordedSample(
            metric: "speedKPH",
            sample: .init(
                value: 1, source: .machineFTMS,
                receivedAt: Date(), eventId: "stable-evidence"))
        try repository.save(record, samples: [sample])
        var changed = record
        changed.endedAt = Date()
        #expect(throws: (any Error).self) { try repository.save(changed, samples: [sample]) }
        #expect(try repository.samples(for: record.id).count == 1)
        #expect(try repository.record(id: record.id)?.endedAt == nil)
    }

    @Test func staleRepositoryWriterAppendsWithCommittedWorkoutEventSequence() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try WorkoutRepository(directory: directory)
        let staleWriter = try WorkoutRepository(directory: directory)
        let program = WorkoutProgram.seedPrograms[0]
        let record = WorkoutRecord(
            mode: "program", program: program, latestSnapshot: WorkoutEngine(program: program).snapshot())
        try first.save(record, events: [.init(sequence: 1, kind: "workout.started")])

        // This writer still has the original record with eventCount == 0.
        try staleWriter.save(record, events: [.init(sequence: 1, kind: "workout.completed")])

        let events: [WorkoutRuntimeEvent] = try staleWriter.events(for: record.id)
        #expect(events.map(\.sequence) == [1, 2])
        #expect(events.map(\.kind) == ["workout.started", "workout.completed"])
        #expect(try staleWriter.record(id: record.id)?.eventCount == 2)
    }

    @Test func futureSchemaIsRejectedWithoutDowngradingIt() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try WorkoutRepository(directory: directory)
        var handle: OpaquePointer?
        #expect(sqlite3_open(repository.url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, "PRAGMA user_version = 42", nil, nil, nil) == SQLITE_OK)
        #expect(throws: WorkoutRepositoryError.self) { try WorkoutRepository(directory: directory) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 42)
    }

    @Test func supplementalMocksCannotReplaceMachineMetrics() {
        let samples = WorkoutMockMetrics.samples(
            speedKPH: 1, distanceMeters: 10, activeSeconds: 60,
            at: Date(timeIntervalSince1970: 0), uptime: 60)
        #expect(Set(samples.map(\.metric)) == ["heartRateBPM", "steps", "energyKilocalories"])
        #expect(samples.allSatisfy { $0.sample.source == .mock })
        #expect(samples.allSatisfy { $0.sample.value.isFinite })
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "WorkoutRepository-\(UUID().uuidString)")
    }
}
