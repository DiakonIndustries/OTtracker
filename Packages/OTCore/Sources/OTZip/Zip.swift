import Foundation

public struct ZipEntry: Hashable, Sendable {
    public var path: String
    public var data: Data
    public var modified: Date?

    public init(path: String, data: Data, modified: Date? = nil) {
        self.path = path
        self.data = data
        self.modified = modified
    }
}

public enum ZipError: Error, Equatable {
    case notAZip
    case truncated
    case unsupportedCompression(Int)
    case corruptEntry(String)
    case crcMismatch(String)
}

/// Writes a ZIP archive with STORED entries (no compression). Excel opens these fine.
public enum ZipWriter {
    public static func archive(_ entries: [ZipEntry]) -> Data {
        fatalError("OTZip.ZipWriter not implemented yet")
    }
}

/// Reads STORED and DEFLATE entries (pure-Swift inflate, no zlib).
public enum ZipReader {
    public static func entries(from data: Data) throws -> [ZipEntry] {
        fatalError("OTZip.ZipReader not implemented yet")
    }
}

/// CRC-32 (IEEE 802.3) as used by ZIP.
public enum CRC32 {
    public static func checksum(_ data: Data) -> UInt32 {
        fatalError("OTZip.CRC32 not implemented yet")
    }
}

/// RFC 1951 inflate.
public enum Inflate {
    public static func decompress(_ data: Data) throws -> Data {
        fatalError("OTZip.Inflate not implemented yet")
    }
}
