import FitnessCore
import Foundation

/// Chunks are journaled before assembly. A process restart can resume an
/// incomplete delivery, while only a complete validated entry earns an ACK.
actor WatchRejectedEnvelopeAssembler {
    private struct Partial: Codable {
        var count: Int
        var parts: [Int: Data]
    }
    private let partialURL: URL
    private var partials: [String: Partial]
    private let journal: WatchRejectedEnvelopeJournal

    init(directory: URL) throws {
        journal = try WatchRejectedEnvelopeJournal(directory: directory)
        partialURL = directory.appendingPathComponent("watch-rejected-envelope-parts-v1.json")
        partials =
            FileManager.default.fileExists(atPath: partialURL.path)
            ? try JSONDecoder().decode([String: Partial].self, from: Data(contentsOf: partialURL)) : [:]
    }

    func accept(_ chunk: WatchRejectedEnvelopeChunk) throws -> String? {
        guard !chunk.entryID.isEmpty, chunk.entryID.count <= 128,
            chunk.count > 0, chunk.count <= 1_024,
            chunk.index >= 0, chunk.index < chunk.count,
            chunk.data.count <= 8_192
        else { throw CompanionError.invalidMessage }
        if journal.entries.contains(where: { $0.id == chunk.entryID }) { return chunk.entryID }
        var next = partials
        var partial = next[chunk.entryID] ?? Partial(count: chunk.count, parts: [:])
        guard partial.count == chunk.count,
            partial.parts[chunk.index] == nil || partial.parts[chunk.index] == chunk.data
        else {
            throw CompanionError.invalidMessage
        }
        partial.parts[chunk.index] = chunk.data
        next[chunk.entryID] = partial
        try JSONEncoder().encode(next).write(
            to: partialURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        partials = next
        guard partial.parts.count == partial.count else { return nil }
        var encoded = Data()
        for index in 0..<partial.count {
            guard let part = partial.parts[index] else { return nil }
            encoded.append(part)
        }
        let entry = try JSONDecoder().decode(WatchRejectedEnvelope.self, from: encoded)
        guard entry.id == chunk.entryID else { throw CompanionError.invalidMessage }
        try journal.record(entry)
        next.removeValue(forKey: chunk.entryID)
        try JSONEncoder().encode(next).write(
            to: partialURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        partials = next
        return entry.id
    }
}
