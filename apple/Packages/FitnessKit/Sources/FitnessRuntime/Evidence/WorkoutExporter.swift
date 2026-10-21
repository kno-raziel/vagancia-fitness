import FitnessCore
import Foundation

public enum WorkoutExporter {
    public static func jsonValue<T: Encodable>(_ workout: T) throws -> JSONValue {
        try EvidenceJSON.decoder().decode(JSONValue.self, from: EvidenceJSON.encoder().encode(workout))
    }

    public static func exportJSON<T: Encodable>(_ workout: T, directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(
            "vagancia-fitness-workout-\(UUID().uuidString.lowercased()).json")
        try EvidenceJSON.encoder(pretty: true).encode(workout).write(to: destination, options: .atomic)
        return destination
    }
}
