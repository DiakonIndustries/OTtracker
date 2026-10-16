import Foundation

/// One file inside a ZIP archive: its path, uncompressed bytes and optional modification time.
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

/// Everything that can go wrong while reading an archive or inflating an entry.
public enum ZipError: Error, Equatable {
    case notAZip
    case truncated
    case unsupportedCompression(Int)
    case corruptEntry(String)
    case crcMismatch(String)
}

// MARK: - Little-endian helpers

private extension Data {
    /// Appends a 16-bit little-endian value (low 16 bits of `value`).
    mutating func appendLE16(_ value: Int) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    /// Appends a 32-bit little-endian value (low 32 bits of `value`).
    mutating func appendLE32(_ value: Int) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    /// Appends a 32-bit little-endian value.
    mutating func appendLE32(_ value: UInt32) {
        appendLE32(Int(value))
    }
}

/// Bounds-checked little-endian reads over a byte array; every miss throws `.truncated`.
private struct ByteReader {
    let bytes: [UInt8]

    func u16(at offset: Int) throws -> Int {
        guard offset >= 0, offset + 2 <= bytes.count else { throw ZipError.truncated }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    func u32(at offset: Int) throws -> Int {
        guard offset >= 0, offset + 4 <= bytes.count else { throw ZipError.truncated }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
    }

    func slice(at offset: Int, count: Int) throws -> [UInt8] {
        guard offset >= 0, count >= 0, offset + count <= bytes.count else { throw ZipError.truncated }
        return Array(bytes[offset..<(offset + count)])
    }
}

// MARK: - DOS date/time

/// MS-DOS packed date and time as stored in ZIP headers (2-second resolution, 1980–2107).
enum DOSDateTime {
    static let fallbackDate = 0x5C21   // 2026-01-01
    static let fallbackTime = 0x0000   // 00:00:00

    static var utc: TimeZone { TimeZone(identifier: "UTC") ?? .gmt }

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// Packs `date` (wall clock in `timeZone`) into (dosDate, dosTime); nil → 2026-01-01 00:00.
    static func pack(_ date: Date?, timeZone: TimeZone) -> (date: Int, time: Int) {
        guard let date else { return (fallbackDate, fallbackTime) }
        let c = calendar(timeZone).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max(c.year ?? 1980, 1980), 2107)
        let month = min(max(c.month ?? 1, 1), 12)
        let day = min(max(c.day ?? 1, 1), 31)
        let hour = min(max(c.hour ?? 0, 0), 23)
        let minute = min(max(c.minute ?? 0, 0), 59)
        let second = min(max(c.second ?? 0, 0), 59)
        let d = ((year - 1980) << 9) | (month << 5) | day
        let t = (hour << 11) | (minute << 5) | (second / 2)
        return (d, t)
    }

    /// Unpacks DOS fields to an instant in `timeZone`; invalid fields yield nil.
    static func unpack(date: Int, time: Int, timeZone: TimeZone) -> Date? {
        var c = DateComponents()
        c.year = 1980 + ((date >> 9) & 0x7F)
        c.month = (date >> 5) & 0x0F
        c.day = date & 0x1F
        c.hour = (time >> 11) & 0x1F
        c.minute = (time >> 5) & 0x3F
        c.second = (time & 0x1F) * 2
        guard let m = c.month, (1...12).contains(m), let d = c.day, (1...31).contains(d),
              let h = c.hour, h <= 23, let mi = c.minute, mi <= 59, let s = c.second, s <= 59 else { return nil }
        return calendar(timeZone).date(from: c)
    }
}

// MARK: - Writer

/// Writes a ZIP archive with STORED entries (no compression). Excel opens these fine.
public enum ZipWriter {
    private static let localHeaderSignature = 0x04034B50
    private static let centralHeaderSignature = 0x02014B50
    private static let endRecordSignature = 0x06054B50
    private static let utf8Flag = 0x0800
    private static let versionMadeBy = 20
    private static let versionNeeded = 20

    /// Builds the archive; entry timestamps are rendered as UTC wall-clock DOS times.
    public static func archive(_ entries: [ZipEntry]) -> Data {
        archive(entries, timeZone: DOSDateTime.utc)
    }

    /// Builds the archive, rendering each entry's `modified` as wall-clock time in `timeZone`.
    public static func archive(_ entries: [ZipEntry], timeZone: TimeZone) -> Data {
        var out = Data()
        var central = Data()
        var count = 0

        for entry in entries {
            let name = Data(entry.path.utf8)
            let crc = CRC32.checksum(entry.data)
            let size = entry.data.count
            let (dosDate, dosTime) = DOSDateTime.pack(entry.modified, timeZone: timeZone)
            let offset = out.count

            // Local file header.
            out.appendLE32(localHeaderSignature)
            out.appendLE16(versionNeeded)
            out.appendLE16(utf8Flag)
            out.appendLE16(0)               // method: stored
            out.appendLE16(dosTime)
            out.appendLE16(dosDate)
            out.appendLE32(crc)
            out.appendLE32(size)            // compressed size
            out.appendLE32(size)            // uncompressed size
            out.appendLE16(name.count)
            out.appendLE16(0)               // extra length
            out.append(name)
            out.append(entry.data)

            // Central directory header.
            central.appendLE32(centralHeaderSignature)
            central.appendLE16(versionMadeBy)
            central.appendLE16(versionNeeded)
            central.appendLE16(utf8Flag)
            central.appendLE16(0)           // method
            central.appendLE16(dosTime)
            central.appendLE16(dosDate)
            central.appendLE32(crc)
            central.appendLE32(size)
            central.appendLE32(size)
            central.appendLE16(name.count)
            central.appendLE16(0)           // extra length
            central.appendLE16(0)           // comment length
            central.appendLE16(0)           // disk number start
            central.appendLE16(0)           // internal attributes
            central.appendLE32(0)           // external attributes
            central.appendLE32(offset)
            central.append(name)
            count += 1
        }

        let centralOffset = out.count
        out.append(central)

        // End of central directory record.
        out.appendLE32(endRecordSignature)
        out.appendLE16(0)                   // this disk
        out.appendLE16(0)                   // disk with central directory
        out.appendLE16(count)
        out.appendLE16(count)
        out.appendLE32(central.count)
        out.appendLE32(centralOffset)
        out.appendLE16(0)                   // comment length
        return out
    }
}

// MARK: - Reader

/// Reads STORED and DEFLATE entries (pure-Swift inflate, no zlib).
public enum ZipReader {
    private static let localHeaderSignature = 0x04034B50
    private static let centralHeaderSignature = 0x02014B50
    private static let endRecordSignature = 0x06054B50
    private static let endRecordLength = 22
    private static let maxCommentLength = 0xFFFF

    /// Parses every file entry; directory entries (names ending in `/`) are skipped.
    public static func entries(from data: Data) throws -> [ZipEntry] {
        try entries(from: data, timeZone: DOSDateTime.utc)
    }

    /// Parses every file entry, interpreting DOS timestamps as wall-clock time in `timeZone`.
    public static func entries(from data: Data, timeZone: TimeZone) throws -> [ZipEntry] {
        let bytes = [UInt8](data)
        let r = ByteReader(bytes: bytes)
        let eocd = try findEndRecord(r)

        let totalEntries = try r.u16(at: eocd + 10)
        let centralSize = try r.u32(at: eocd + 12)
        let centralOffset = try r.u32(at: eocd + 16)
        if totalEntries == 0xFFFF || centralSize == 0xFFFF_FFFF || centralOffset == 0xFFFF_FFFF {
            throw ZipError.unsupportedCompression(-1)   // Zip64 is not supported.
        }
        guard centralOffset + centralSize <= bytes.count else { throw ZipError.truncated }

        var result: [ZipEntry] = []
        var pos = centralOffset
        for _ in 0..<totalEntries {
            guard try r.u32(at: pos) == centralHeaderSignature else { throw ZipError.corruptEntry("central directory") }
            let flags = try r.u16(at: pos + 8)
            let method = try r.u16(at: pos + 10)
            let dosTime = try r.u16(at: pos + 12)
            let dosDate = try r.u16(at: pos + 14)
            let crc = UInt32(truncatingIfNeeded: try r.u32(at: pos + 16))
            let compressedSize = try r.u32(at: pos + 20)
            let uncompressedSize = try r.u32(at: pos + 24)
            let nameLength = try r.u16(at: pos + 28)
            let extraLength = try r.u16(at: pos + 30)
            let commentLength = try r.u16(at: pos + 32)
            let localOffset = try r.u32(at: pos + 42)
            let nameBytes = try r.slice(at: pos + 46, count: nameLength)
            pos += 46 + nameLength + extraLength + commentLength

            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw ZipError.unsupportedCompression(-1)
            }
            let name = decodeName(nameBytes, utf8Flag: flags & 0x0800 != 0)
            if name.hasSuffix("/") { continue }   // directory entry

            // Local header: trust its own name/extra lengths, sizes come from the central directory.
            guard try r.u32(at: localOffset) == localHeaderSignature else { throw ZipError.corruptEntry(name) }
            let localNameLength = try r.u16(at: localOffset + 26)
            let localExtraLength = try r.u16(at: localOffset + 28)
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            let raw = try r.slice(at: dataStart, count: compressedSize)

            let payload: Data
            switch method {
            case 0:
                guard compressedSize == uncompressedSize else { throw ZipError.corruptEntry(name) }
                payload = Data(raw)
            case 8:
                do {
                    payload = try Inflate.decompress(Data(raw))
                } catch ZipError.corruptEntry(let reason) {
                    throw ZipError.corruptEntry("\(name): \(reason)")
                }
                guard payload.count == uncompressedSize else { throw ZipError.corruptEntry(name) }
            default:
                throw ZipError.unsupportedCompression(method)
            }
            guard CRC32.checksum(payload) == crc else { throw ZipError.crcMismatch(name) }

            let modified = DOSDateTime.unpack(date: dosDate, time: dosTime, timeZone: timeZone)
            result.append(ZipEntry(path: name, data: payload, modified: modified))
        }
        return result
    }

    /// Locates the end-of-central-directory record, scanning backwards past any archive comment.
    private static func findEndRecord(_ r: ByteReader) throws -> Int {
        let count = r.bytes.count
        guard count >= endRecordLength else { throw ZipError.notAZip }
        let lowest = max(0, count - endRecordLength - maxCommentLength)
        var pos = count - endRecordLength
        while pos >= lowest {
            if (try? r.u32(at: pos)) == endRecordSignature {
                // Prefer a record whose comment length matches the remaining bytes, but accept any.
                let commentLength = try r.u16(at: pos + 20)
                if pos + endRecordLength + commentLength == count { return pos }
                return pos
            }
            pos -= 1
        }
        throw ZipError.notAZip
    }

    /// Decodes an entry name: UTF-8 when flagged or valid, otherwise Latin-1.
    private static func decodeName(_ bytes: [UInt8], utf8Flag: Bool) -> String {
        if let s = String(bytes: bytes, encoding: .utf8) { return s }
        return String(bytes: bytes, encoding: .isoLatin1) ?? String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - CRC-32

/// CRC-32 (IEEE 802.3) as used by ZIP.
public enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    /// Table-driven checksum of `data`; the empty input yields 0.
    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Inflate

/// RFC 1951 inflate.
public enum Inflate {
    /// Decompresses a raw deflate stream (no zlib or gzip wrapper). Bad input throws `ZipError.corruptEntry`.
    public static func decompress(_ data: Data) throws -> Data {
        var state = InflateState(input: [UInt8](data))
        try state.run()
        return Data(state.output)
    }
}

/// A canonical Huffman code in the compact "count per length + symbols" form used by zlib's puff.
private struct Huffman {
    static let maxBits = 15
    var count: [Int]      // number of codes of each length 0...15
    var symbol: [Int]     // symbols ordered by code

    /// Builds the code from per-symbol lengths; returns the number of unused codes (0 = complete, < 0 = over-subscribed).
    init(lengths: [Int]) throws {
        count = [Int](repeating: 0, count: Huffman.maxBits + 1)
        symbol = [Int](repeating: 0, count: lengths.count)
        for len in lengths {
            guard len >= 0, len <= Huffman.maxBits else { throw ZipError.corruptEntry("bad code length") }
            count[len] += 1
        }
        var offs = [Int](repeating: 0, count: Huffman.maxBits + 2)
        for len in 1..<Huffman.maxBits { offs[len + 1] = offs[len] + count[len] }
        for (sym, len) in lengths.enumerated() where len != 0 {
            symbol[offs[len]] = sym
            offs[len] += 1
        }
    }

    /// Unused code space: 0 when complete, negative when over-subscribed, positive when incomplete.
    var left: Int {
        var left = 1
        for len in 1...Huffman.maxBits {
            left <<= 1
            left -= count[len]
            if left < 0 { return left }
        }
        return left
    }

    /// Number of symbols that have a code.
    var codedSymbols: Int { symbol.count - count[0] }
}

private struct InflateState {
    let input: [UInt8]
    var inPos = 0
    var bitBuf: UInt32 = 0
    var bitCnt = 0
    var output: [UInt8] = []

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                     35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                      3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                       257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                                       8193, 12289, 16385, 24577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private static let fixedLiteral: Huffman? = {
        var lengths = [Int](repeating: 8, count: 288)
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        return try? Huffman(lengths: lengths)
    }()
    private static let fixedDistance: Huffman? = {
        try? Huffman(lengths: [Int](repeating: 5, count: 30))
    }()

    init(input: [UInt8]) {
        self.input = input
        output.reserveCapacity(input.count * 3)
    }

    /// Reads `need` (≤ 16) bits, least-significant first; running out of input throws.
    mutating func bits(_ need: Int) throws -> Int {
        var val = bitBuf
        while bitCnt < need {
            guard inPos < input.count else { throw ZipError.corruptEntry("deflate stream truncated") }
            val |= UInt32(input[inPos]) << UInt32(bitCnt)
            inPos += 1
            bitCnt += 8
        }
        bitBuf = val >> UInt32(need)
        bitCnt -= need
        return Int(val & ((UInt32(1) << UInt32(need)) - 1))
    }

    /// Decodes one symbol bit by bit using the canonical code.
    mutating func decode(_ h: Huffman) throws -> Int {
        var code = 0, first = 0, index = 0
        for len in 1...Huffman.maxBits {
            code |= try bits(1)
            let count = h.count[len]
            if code - count < first {
                let i = index + (code - first)
                guard i >= 0, i < h.symbol.count else { throw ZipError.corruptEntry("invalid Huffman code") }
                return h.symbol[i]
            }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw ZipError.corruptEntry("invalid Huffman code")
    }

    mutating func run() throws {
        var last = false
        repeat {
            last = try bits(1) == 1
            switch try bits(2) {
            case 0: try stored()
            case 1: try fixed()
            case 2: try dynamic()
            default: throw ZipError.corruptEntry("invalid block type")
            }
        } while !last
    }

    /// Stored block: byte-align, LEN / NLEN, raw copy.
    private mutating func stored() throws {
        bitBuf = 0
        bitCnt = 0
        guard inPos + 4 <= input.count else { throw ZipError.corruptEntry("deflate stream truncated") }
        let len = Int(input[inPos]) | Int(input[inPos + 1]) << 8
        let nlen = Int(input[inPos + 2]) | Int(input[inPos + 3]) << 8
        inPos += 4
        guard len == (~nlen & 0xFFFF) else { throw ZipError.corruptEntry("stored block length mismatch") }
        guard inPos + len <= input.count else { throw ZipError.corruptEntry("deflate stream truncated") }
        output.append(contentsOf: input[inPos..<(inPos + len)])
        inPos += len
    }

    private mutating func fixed() throws {
        guard let lit = InflateState.fixedLiteral, let dist = InflateState.fixedDistance else {
            throw ZipError.corruptEntry("fixed tables unavailable")
        }
        try codes(literal: lit, distance: dist)
    }

    private mutating func dynamic() throws {
        let nlen = try bits(5) + 257
        let ndist = try bits(5) + 1
        let ncode = try bits(4) + 4
        guard nlen <= 286, ndist <= 30 else { throw ZipError.corruptEntry("bad dynamic block counts") }

        var lengths = [Int](repeating: 0, count: 320)
        for i in 0..<ncode { lengths[InflateState.codeLengthOrder[i]] = try bits(3) }
        let lencode = try Huffman(lengths: Array(lengths[0..<19]))
        guard lencode.left == 0 else { throw ZipError.corruptEntry("bad code-length code") }

        var index = 0
        while index < nlen + ndist {
            var symbol = try decode(lencode)
            if symbol < 16 {
                lengths[index] = symbol
                index += 1
                continue
            }
            var len = 0
            if symbol == 16 {
                guard index > 0 else { throw ZipError.corruptEntry("repeat with no previous length") }
                len = lengths[index - 1]
                symbol = 3 + (try bits(2))
            } else if symbol == 17 {
                symbol = 3 + (try bits(3))
            } else {
                symbol = 11 + (try bits(7))
            }
            guard index + symbol <= nlen + ndist else { throw ZipError.corruptEntry("code lengths overflow") }
            for _ in 0..<symbol {
                lengths[index] = len
                index += 1
            }
        }
        guard lengths[256] != 0 else { throw ZipError.corruptEntry("missing end-of-block code") }

        let literal = try Huffman(lengths: Array(lengths[0..<nlen]))
        let litLeft = literal.left
        if litLeft != 0 && (litLeft < 0 || literal.codedSymbols != 1 || literal.count[1] != 1) {
            throw ZipError.corruptEntry("bad literal/length code")
        }
        let distance = try Huffman(lengths: Array(lengths[nlen..<(nlen + ndist)]))
        let distLeft = distance.left
        if distLeft != 0 && (distLeft < 0 || distance.codedSymbols != 1 || distance.count[1] != 1) {
            throw ZipError.corruptEntry("bad distance code")
        }
        try codes(literal: literal, distance: distance)
    }

    /// Decodes literal/length and distance codes until the end-of-block symbol.
    private mutating func codes(literal: Huffman, distance: Huffman) throws {
        while true {
            var symbol = try decode(literal)
            if symbol < 256 {
                output.append(UInt8(symbol))
                continue
            }
            if symbol == 256 { return }
            symbol -= 257
            guard symbol < InflateState.lengthBase.count else { throw ZipError.corruptEntry("invalid length symbol") }
            let len = InflateState.lengthBase[symbol] + (try bits(InflateState.lengthExtra[symbol]))

            let dsym = try decode(distance)
            guard dsym < InflateState.distanceBase.count else { throw ZipError.corruptEntry("invalid distance symbol") }
            let dist = InflateState.distanceBase[dsym] + (try bits(InflateState.distanceExtra[dsym]))
            guard dist <= output.count, dist > 0 else { throw ZipError.corruptEntry("distance too far back") }

            let start = output.count - dist
            if dist >= len {
                output.append(contentsOf: output[start..<(start + len)])
            } else {
                for i in 0..<len { output.append(output[start + i]) }
            }
        }
    }
}
