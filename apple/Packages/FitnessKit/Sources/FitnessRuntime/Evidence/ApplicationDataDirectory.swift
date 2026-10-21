import Foundation

/// Resolves storage before opening any database or starting a background writer.
/// Both iOS apps use this within their independent, unchanged app containers.
public enum ApplicationDataDirectory {
    // Compatibility only: the directory used by already-installed releases.
    static let legacyDirectoryName = "OpenFitness"
    static let currentDirectoryName = "VaganciaFitness"

    public static func resolve(in supportDirectory: URL = .applicationSupportDirectory) -> URL {
        resolve(in: supportDirectory) { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    static func resolve(
        in supportDirectory: URL, move: (URL, URL) throws -> Void
    ) -> URL {
        let legacy = supportDirectory.appendingPathComponent(legacyDirectoryName, isDirectory: true)
        let current = supportDirectory.appendingPathComponent(currentDirectoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return current }
        // Never merge or overwrite two stores. Prefer the established store if
        // both exist, including a destination blocked by a file.
        guard !FileManager.default.fileExists(atPath: current.path) else { return legacy }
        do {
            // Same-container directory rename preserves SQLite sidecars, journals,
            // cached capabilities, routines and all files unknown to this version.
            try move(legacy, current)
            return current
        } catch {
            // A failed rename must not silently create a new empty database.
            return legacy
        }
    }
}
