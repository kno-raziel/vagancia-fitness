import FitnessCore
import Foundation

/// ZIP32 with stored (uncompressed) entries. No third-party runtime dependency.
/// Callers provide fixed diagnostic filenames; Watch evidence adds two streams.
enum StoredZIP {
    struct Entry {
        let name: String
        let data: Data
    }

    enum ArchiveError: LocalizedError {
        case tooLarge, invalidName
        var errorDescription: String? {
            switch self {
            case .tooLarge: FitnessText.string("error.zip.tooLarge")
            case .invalidName: FitnessText.string("error.zip.invalidName")
            }
        }
    }

    static func archive(_ entries: [Entry]) throws -> Data {
        guard entries.count <= Int(UInt16.max) else { throw ArchiveError.tooLarge }
        var output = Data()
        var central = Data()
        var names = Set<String>()
        for entry in entries {
            guard !entry.name.isEmpty, !entry.name.contains("/"), !entry.name.contains("\\"),
                names.insert(entry.name).inserted
            else { throw ArchiveError.invalidName }
            let name = Data(entry.name.utf8)
            guard name.count <= Int(UInt16.max), entry.data.count <= Int(UInt32.max),
                output.count <= Int(UInt32.max)
            else { throw ArchiveError.tooLarge }
            let size = UInt32(entry.data.count)
            let offset = UInt32(output.count)
            let checksum = crc32(entry.data)
            output.appendLE(UInt32(0x0403_4b50))
            output.appendLE(UInt16(20))
            output.appendLE(UInt16(0x0800))  // UTF-8 names
            output.appendLE(UInt16(0))  // stored
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0x0021))  // 1980-01-01, valid DOS date
            output.appendLE(checksum)
            output.appendLE(size)
            output.appendLE(size)
            output.appendLE(UInt16(name.count))
            output.appendLE(UInt16(0))
            output.append(name)
            output.append(entry.data)

            central.appendLE(UInt32(0x0201_4b50))
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(0x0800))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0x0021))
            central.appendLE(checksum)
            central.appendLE(size)
            central.appendLE(size)
            central.appendLE(UInt16(name.count))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt32(0))
            central.appendLE(offset)
            central.append(name)
        }
        guard output.count <= Int(UInt32.max), central.count <= Int(UInt32.max),
            output.count + central.count <= Int(UInt32.max)
        else { throw ArchiveError.tooLarge }
        let offset = UInt32(output.count)
        output.append(central)
        output.appendLE(UInt32(0x0605_4b50))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(entries.count))
        output.appendLE(UInt16(entries.count))
        output.appendLE(UInt32(central.count))
        output.appendLE(offset)
        output.appendLE(UInt16(0))
        return output
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb8_8320 : 0)
            }
        }
        return crc ^ 0xffff_ffff
    }
}

extension Data {
    fileprivate mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
