import Foundation
import Testing

@testable import FitnessCore
@testable import FitnessRuntime

@MainActor
struct SessionStoreTests {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VaganciaFitnessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func restoresOpenSessionAndPreservesNoteProvenance() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = SessionStore(directory: directory)
        try original.startSession()
        try original.addNote("  Prueba con acentos: caminadora y velocidad.\nSegunda línea.  ")
        try await original.flush()
        let id = try #require(original.session?.sessionId)
        let recovered = SessionStore(directory: directory)
        let session = try #require(recovered.session)
        #expect(recovered.storageReady)
        #expect(session.sessionId == id)
        #expect(session.events.last?.kind == "session.restored")
        let note = try #require(session.events.first(where: { $0.kind == "operator.note" }))
        #expect(note.source == .userReported)
        #expect(
            note.payload["note"]?.text == "Prueba con acentos: caminadora y velocidad.\nSegunda línea.")
        #expect(session.gaps.count == 1)
        #expect(session.events.map(\.sequence) == [1, 2, 3])
        #expect(
            zip(session.events, session.events.dropFirst()).allSatisfy {
                $0.elapsedMilliseconds <= $1.elapsedMilliseconds
            })
    }

    @Test func closureIsPersistentAndPreviousSessionsRemainOnDisk() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        try store.startSession()
        let first = try #require(store.session?.sessionId)
        try store.closeSession()
        try await store.flush()
        let reopened = SessionStore(directory: directory)
        #expect(reopened.session?.isOpen == false)
        #expect(reopened.session?.events.last?.kind == "session.closed")
        #expect(throws: SessionError.self) { try reopened.addNote("No modificar una sesión cerrada") }
        try reopened.startSession()
        #expect(reopened.session?.sessionId != first)
        let journal = try SessionJournal(directory: directory.appendingPathComponent("Sessions"))
        #expect(try journal.contains(first))
        #expect(try journal.allEvents(sessionId: first).last?.kind == "session.closed")
    }

    @Test func rejectsInvalidNotesAndConcurrentSessionCreation() throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        #expect(throws: SessionError.self) { try store.addNote("Sin sesión") }
        try store.startSession()
        #expect(throws: SessionError.self) { try store.startSession() }
        #expect(throws: SessionError.self) { try store.addNote(" \n ") }
        #expect(throws: SessionError.self) { try store.addNote(String(repeating: "a", count: 2_001)) }
        #expect(store.session?.events.count == 1)
    }

    @Test func failedSaveDoesNotClaimAnUnsavedNote() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        try store.startSession()
        let before = store.session
        let sessions = directory.appendingPathComponent("Sessions")
        try FileManager.default.removeItem(at: sessions)
        try Data("not a directory".utf8).write(to: sessions)
        try store.addNote("Esto no se guardará")
        do {
            try await store.flush()
            Issue.record("La escritura debió fallar")
        } catch {}
        #expect(store.persistenceError != nil)
        #expect(store.pendingEventCount == 1)
        #expect(store.session?.totalEventCount == (before?.totalEventCount ?? 0) + 1)
    }

    @Test func failedDurableMotorIntentCannotReachWriteStep() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        try store.startSession()
        let sessions = directory.appendingPathComponent("Sessions")
        try FileManager.default.removeItem(at: sessions)
        try Data("blocked".utf8).write(to: sessions)
        var wroteMotorBytes = false
        do {
            try await store.recordDurably(
                kind: "ftms.control.requested",
                payload: ["valueHex": .string("07"), "operatorAuthorized": .bool(true)])
            wroteMotorBytes = true
        } catch {}
        #expect(!wroteMotorBytes)
        #expect(store.persistenceError != nil)
    }

    @Test func failedQueuedWritesReleaseTheFlushBarrierWithoutClaimingDurability() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory, writerDelay: .milliseconds(20))
        try store.startSession()
        let sessions = directory.appendingPathComponent("Sessions")
        try FileManager.default.removeItem(at: sessions)
        try Data("blocked".utf8).write(to: sessions)
        try store.addNote("Primera nota")
        try store.addNote("Segunda nota")
        do {
            try await store.flush()
            Issue.record("La cola debió fallar")
        } catch {}
        #expect(store.persistenceError != nil)
        #expect(store.pendingEventCount == 2)
        #expect(throws: SessionError.self) { try store.addNote("Tercera nota") }
    }

    @Test func acceptedWriteFinishesAfterStoreReferenceIsReleased() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: SessionStore? = SessionStore(directory: directory, writerDelay: .milliseconds(20))
        try store?.startSession()
        let id = try #require(store?.session?.sessionId)
        let journal = try SessionJournal(directory: directory.appendingPathComponent("Sessions"))
        try store?.addNote("Nota pendiente")
        store = nil

        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        var events: [DiagnosticEvent] = []
        while ContinuousClock().now < deadline {
            events = (try? journal.allEvents(sessionId: id)) ?? []
            if events.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(events.map(\.kind) == ["session.created", "operator.note"])
        #expect(events.last?.payload["note"] == .string("Nota pendiente"))
    }

    @Test func corruptLatestSessionIsReportedWithoutOverwritingIt() throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = directory.appendingPathComponent("Sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let corrupt = sessions.appendingPathComponent("broken.json")
        let bytes = Data("{broken".utf8)
        try bytes.write(to: corrupt)
        let store = SessionStore(directory: directory)
        #expect(!store.storageReady)
        #expect(store.startupError != nil)
        #expect(throws: SessionError.self) { try store.startSession() }
        #expect(try Data(contentsOf: corrupt) == bytes)
    }

    @Test func exportIncludesAllEventsBeyondTheMemoryWindow() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory, maxEvents: 3)
        try store.startSession()
        for n in 1...5 { try store.addNote("Nota \(n)") }
        let artifact = try await store.exportAsync(
            metadata: AppMetadata(
                version: "test", build: "1", osVersion: "test", deviceModel: "simulated"))
        #expect(FileManager.default.fileExists(atPath: artifact.archiveURL.path))
        #expect(artifact.fileURLs.count == 5)
        let manifestURL = try #require(
            artifact.fileURLs.first(where: { $0.lastPathComponent == "manifest.json" }))
        let manifest = try EvidenceJSON.decoder().decode(
            [String: JSONValue].self, from: Data(contentsOf: manifestURL))
        #expect(manifest["isOpen"] == .bool(true))
        #expect(manifest["endedAt"] == .null)
        #expect(manifest["source"] == .string("application"))
        #expect(manifest["captureMode"] == .string("sessionOnly"))
        guard case .object(let capture) = manifest["capture"] else {
            Issue.record("Falta capture")
            return
        }
        #expect(capture["truncated"] == .bool(false))
        #expect(capture["droppedEventCount"] == .number(0))
        let eventsURL = try #require(
            artifact.fileURLs.first(where: { $0.lastPathComponent == "events.jsonl" }))
        let lines = try String(contentsOf: eventsURL, encoding: .utf8).split(separator: "\n")
        let events = try lines.map {
            try EvidenceJSON.decoder().decode(DiagnosticEvent.self, from: Data($0.utf8))
        }
        #expect(events.map(\.sequence) == [1, 2, 3, 4, 5, 6])
        #expect(events.dropFirst().allSatisfy { $0.source == .userReported })
        #expect(store.session?.events.map(\.sequence) == [4, 5, 6])
        let resultsURL = try #require(
            artifact.fileURLs.first(where: { $0.lastPathComponent == "results.json" }))
        let results = try EvidenceJSON.decoder().decode(
            [String: JSONValue].self, from: Data(contentsOf: resultsURL))
        #expect(results["status"] == .string("notRun"))
        #expect(results["tests"] == .array([]))
        // Export is a snapshot; it must not append events to or close the session.
        #expect(store.session?.isOpen == true)
        #expect(store.session?.totalEventCount == 6)
    }

    @Test func moreThanOneThousandNotificationsSurviveBackgroundLifecycleAndReload() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory, maxEvents: 20)
        try store.startSession()
        try store.recordLifecycle("background")
        for index in 0..<1_050 {
            try store.record(
                kind: "ftms.treadmill.received", source: .synthetic,
                payload: [
                    "valueHex": .string("8C05C8003200000000FF7F04000000004D6800"),
                    "fixtureIndex": .number(Double(index)),
                ])
        }
        try store.recordLifecycle("active")
        try await store.flush()
        #expect(store.session?.events.count == 20)
        #expect(store.session?.droppedEventCount == 0)
        let recovered = SessionStore(directory: directory, maxEvents: 20)
        #expect(recovered.storageReady)
        let artifact = try recovered.export(
            metadata: .init(version: "test", build: "5", osVersion: "test", deviceModel: "simulated"))
        let url = try #require(artifact.fileURLs.first { $0.lastPathComponent == "events.jsonl" })
        let events = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try EvidenceJSON.decoder().decode(DiagnosticEvent.self, from: Data($0.utf8))
        }
        #expect(events.count == 1_054)
        #expect(events.map(\.sequence) == Array(1...1_054))
        #expect(events.filter { $0.kind == "ftms.treadmill.received" }.count == 1_050)
        #expect(events[2].payload["fixtureIndex"] == .number(0))
        #expect(events[1].kind == "app.backgrounded")
        #expect(events[1_052].kind == "app.activated")
        #expect(recovered.session?.events.count == 20)
        #expect(recovered.session?.droppedEventCount == 0)
    }

    @Test func migratesLegacyJSONOnceAndPreservesItsExistingLossCounter() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = directory.appendingPathComponent("Sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let event = DiagnosticEvent(
            eventId: "legacy-event", sequence: 5, timestamp: Date(), elapsedMilliseconds: 500,
            kind: "operator.note", source: .userReported, payload: ["note": .string("Nota anterior")])
        let legacy = DiagnosticSession(
            sessionId: "legacy", startedAt: Date(), endedAt: Date(),
            events: [event], totalEventCount: 5, droppedEventCount: 4, gaps: [])
        let url = sessions.appendingPathComponent("legacy.json")
        let bytes = try EvidenceJSON.encoder().encode(legacy)
        let decodedLegacy = try EvidenceJSON.decoder().decode(DiagnosticSession.self, from: bytes)
        try bytes.write(to: url)
        let store = SessionStore(directory: directory)
        #expect(store.storageReady)
        #expect(store.session == decodedLegacy)
        try store.startSession()
        try store.addNote("Nueva captura")
        try await store.flush()
        let recovered = SessionStore(directory: directory)
        #expect(recovered.storageReady)
        #expect(recovered.session?.sessionId == store.session?.sessionId)
        #expect(try Data(contentsOf: url) == bytes)
        let journal = try SessionJournal(directory: sessions)
        #expect(try journal.allEvents(sessionId: "legacy") == decodedLegacy.events)
    }

    @Test func journalTransactionRollsBackBothEventsAndSnapshot() throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        try store.startSession()
        var next = try #require(store.session)
        let original = try #require(next.events.last)
        let extra = DiagnosticEvent(
            eventId: "new", sequence: 2, timestamp: Date(), elapsedMilliseconds: 1,
            kind: "operator.note", source: .userReported, payload: ["note": .string("No debe quedar")])
        next.totalEventCount = 2
        next.events.append(extra)
        let journal = try SessionJournal(directory: directory.appendingPathComponent("Sessions"))
        // The first insert succeeds, the second conflicts. Neither may commit.
        #expect(throws: (any Error).self) { try journal.save(next, events: [extra, original]) }
        let decodedOriginal = try EvidenceJSON.decoder().decode(
            DiagnosticEvent.self, from: EvidenceJSON.encoder().encode(original))
        #expect(try journal.allEvents(sessionId: next.sessionId) == [decodedOriginal])
        #expect(try journal.latest(cacheLimit: 20)?.totalEventCount == 1)
        #if !targetEnvironment(simulator)
            // The simulator filesystem does not implement iOS Data Protection.
            let protection =
                try FileManager.default.attributesOfItem(atPath: journal.url.path)[.protectionKey]
                as? FileProtectionType
            #expect(protection == .completeUntilFirstUserAuthentication)
        #endif
    }

    @Test func staleSessionWritersReconcileAgainstCommittedEventSequence() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = SessionStore(directory: directory, writerDelay: .milliseconds(350))
        try first.startSession()
        let second = SessionStore(directory: directory)
        try first.recordLifecycle("background")
        // Independent writer queues have no cross-store commit ordering. Commit
        // the first writer before exercising the second writer's stale cache.
        try await first.flush()
        #expect(second.session?.events.last?.sequence == 2)
        try second.addNote("Nota después del cambio de estado")
        try await second.flush()

        let journal = try SessionJournal(directory: directory.appendingPathComponent("Sessions"))
        let events = try journal.allEvents(sessionId: try #require(first.session?.sessionId))
        #expect(events.map(\.sequence) == [1, 2, 3, 4])
        #expect(
            events.map(\.kind) == [
                "session.created", "session.restored", "app.backgrounded", "operator.note",
            ])
        #expect(try journal.latest(cacheLimit: 20)?.totalEventCount == 4)
    }

    @Test func staleWriterPreservesCommittedDeviceDistanceClosureAndRawEvents() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = SessionStore(directory: directory)
        try first.startSession()
        let second = SessionStore(directory: directory)
        let id = try #require(first.session?.sessionId)
        let device = GATTDevice(
            localPeripheralIdentifier: "synthetic-peripheral", inspectionId: "inspection-A",
            advertisedName: "Fixture", advertisement: [:], selectedAt: Date())
        try first.record(
            kind: "ble.connected", source: .synthetic,
            payload: ["valueHex": .string("A1B2")], device: device)
        for (index, counter) in [100, 125].enumerated() {
            try first.record(
                kind: "ftms.treadmill.received", source: .synthetic,
                payload: [
                    "inspectionId": .string("inspection-A"),
                    "valueHex": .string(index == 0 ? "0064" : "007D"),
                    "sample": .object(["distanceMeters": .number(Double(counter))]),
                ])
        }
        try first.closeSession()
        try await first.flush()

        // The second writer still believes the session is open and has no
        // device or distance state. Its note must not reopen or erase either.
        try second.addNote("Nota desde vista antigua")
        try await second.flush()
        let journal = try SessionJournal(directory: directory.appendingPathComponent("Sessions"))
        let loadedSnapshot = try journal.exportSnapshot(sessionId: id)
        let snapshot = try #require(loadedSnapshot)
        #expect(snapshot.device?.localPeripheralIdentifier == "synthetic-peripheral")
        #expect(snapshot.distanceProgress?.accumulatedMeters == 25)
        #expect(snapshot.bleObserved == true)
        #expect(snapshot.endedAt != nil)
        #expect(snapshot.gaps.count == 1)
        #expect(snapshot.events.map(\.sequence) == Array(1...7))
        #expect(
            snapshot.events.map(\.kind) == [
                "session.created", "session.restored", "ble.connected",
                "ftms.treadmill.received", "ftms.treadmill.received",
                "session.closed", "operator.note",
            ])
        #expect(snapshot.events[2].payload["valueHex"] == .string("A1B2"))
        #expect(snapshot.events[4].payload["valueHex"] == .string("007D"))
        let artifact = try second.export(
            metadata: .init(version: "test", build: "stale", osVersion: "test", deviceModel: "simulated"))
        let eventURL = try #require(artifact.fileURLs.first { $0.lastPathComponent == "events.jsonl" })
        #expect(try String(contentsOf: eventURL, encoding: .utf8).split(separator: "\n").count == 7)
    }

    @Test func busyBLECaptureKeepsMainActorResponsiveAndExportsEveryByte() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory, maxEvents: 1_000, writerDelay: .milliseconds(1))
        try store.startSession()
        for index in 0..<2_500 {
            try store.record(
                kind: "ftms.treadmill.received", source: .synthetic,
                payload: [
                    "valueHex": .string(String(format: "%08X", index)),
                    "fixtureIndex": .number(Double(index)),
                ])
        }
        let cachedEventCount = try #require(store.session?.events.count)
        #expect(cachedEventCount <= 1_000)
        var heartbeat = 0
        let ticker = Task { @MainActor in
            for _ in 0..<200 {
                try? await Task.sleep(for: .milliseconds(10))
                if Task.isCancelled { return }
                heartbeat += 1
            }
        }
        try await store.flush()
        let ticksWhileWriting = heartbeat
        ticker.cancel()
        await ticker.value
        #expect(ticksWhileWriting >= 5)
        #expect(store.pendingEventCount == 0)
        #expect(store.session?.events.count == 1_000)
        let artifact = try await store.exportAsync(
            metadata: .init(version: "test", build: "load", osVersion: "test", deviceModel: "simulated"))
        let url = try #require(artifact.fileURLs.first { $0.lastPathComponent == "events.jsonl" })
        let events = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try EvidenceJSON.decoder().decode(DiagnosticEvent.self, from: Data($0.utf8))
        }
        #expect(events.count == 2_501)
        #expect(events.map(\.sequence) == Array(1...2_501))
        #expect(
            events.dropFirst().enumerated().allSatisfy { index, event in
                event.payload["fixtureIndex"] == .number(Double(index))
                    && event.payload["valueHex"] == .string(String(format: "%08X", index))
            })
    }

    @Test func flushIsFiniteWhileNewTelemetryContinues() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory, writerDelay: .milliseconds(5))
        try store.startSession()
        for index in 0..<20 {
            try store.record(kind: "ftms.treadmill.received", payload: ["index": .number(Double(index))])
        }
        var keepProducing = true
        var streamEndedNaturally = false
        var produced = 0
        let producer = Task { @MainActor in
            var index = 20
            let deadline = ContinuousClock().now.advanced(by: .milliseconds(500))
            while keepProducing && ContinuousClock().now < deadline {
                try? store.record(
                    kind: "ftms.treadmill.received", payload: ["index": .number(Double(index))])
                index += 1
                produced += 1
                try? await Task.sleep(for: .milliseconds(2))
            }
            if keepProducing { streamEndedNaturally = true }
        }
        try await store.flush()
        #expect(!streamEndedNaturally)
        #expect(produced > 0)
        #expect(store.pendingEventCount > 0)
        keepProducing = false
        await producer.value
        try await store.flush()
        #expect(store.pendingEventCount == 0)
    }

    @Test func zipChecksumMatchesPublishedCRC32VectorAndRejectsDuplicateEntries() throws {
        #expect(StoredZIP.crc32(Data("123456789".utf8)) == 0xcbf4_3926)
        #expect(throws: StoredZIP.ArchiveError.self) {
            try StoredZIP.archive([.init(name: "same", data: Data()), .init(name: "same", data: Data())])
        }
    }
}
