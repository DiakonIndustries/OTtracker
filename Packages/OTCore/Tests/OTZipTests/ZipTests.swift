import XCTest
@testable import OTZip

// MARK: - Shared helpers

enum ZipTestData {
    /// Deterministic LCG byte stream; mirrors the Python generator used for the fixtures.
    static func pseudoRandomBytes(count: Int, seed: UInt32 = 12345) -> Data {
        var state = seed
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            state = state &* 1664525 &+ 1013904223
            out[i] = UInt8(truncatingIfNeeded: state >> 24)
        }
        return Data(out)
    }

    /// 200 KB of repeated text, identical to the Python fixture input.
    static func repetitiveText(count: Int = 200 * 1024) -> Data {
        let base = "The quick brown fox jumps over the lazy dog. 0123456789 OTtracker ledger line.\n"
        var s = ""
        while s.utf8.count < count { s += base }
        return Data(Array(s.utf8)[0..<count])
    }

    static func le16(_ data: Data, _ offset: Int) -> Int {
        Int(data[data.startIndex + offset]) | Int(data[data.startIndex + offset + 1]) << 8
    }

    static func le32(_ data: Data, _ offset: Int) -> Int {
        le16(data, offset) | le16(data, offset + 2) << 16
    }

    static func put16(_ data: inout Data, _ offset: Int, _ value: Int) {
        data[data.startIndex + offset] = UInt8(truncatingIfNeeded: value)
        data[data.startIndex + offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    static func put32(_ data: inout Data, _ offset: Int, _ value: Int) {
        put16(&data, offset, value & 0xFFFF)
        put16(&data, offset + 2, (value >> 16) & 0xFFFF)
    }

    /// Offset of the end-of-central-directory record in a comment-free archive.
    static func eocdOffset(_ data: Data) -> Int { data.count - 22 }

    /// Offset of the first central directory header.
    static func centralOffset(_ data: Data) -> Int { le32(data, eocdOffset(data) + 16) }

    static func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi, second: s))!
    }
}

// MARK: - CRC-32

final class CRC32Tests: XCTestCase {
    func testCheckValue() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testEmptyIsZero() {
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }

    func testOtherKnownVectors() {
        XCTAssertEqual(CRC32.checksum(Data("a".utf8)), 0xE8B7_BE43)
        XCTAssertEqual(CRC32.checksum(Data("The quick brown fox jumps over the lazy dog".utf8)), 0x414F_A339)
        XCTAssertEqual(CRC32.checksum(Data([UInt8](repeating: 0, count: 32))), 0x190A_55AD)
    }
}

// MARK: - Writer / reader round trips

final class ZipRoundTripTests: XCTestCase {
    let entries = [
        ZipEntry(path: "[Content_Types].xml", data: Data("<Types/>".utf8)),
        ZipEntry(path: "dir/empty.bin", data: Data()),
        ZipEntry(path: "näme/日本語 ✓.txt", data: Data("café ✓ 日本".utf8)),
        ZipEntry(path: "binary.dat", data: ZipTestData.pseudoRandomBytes(count: 5000)),
        ZipEntry(path: "big.txt", data: ZipTestData.repetitiveText(count: 70_000)),
    ]

    func testRoundTripPreservesOrderNamesAndBytes() throws {
        let archive = ZipWriter.archive(entries)
        let back = try ZipReader.entries(from: archive)
        XCTAssertEqual(back.count, entries.count)
        for (a, b) in zip(entries, back) {
            XCTAssertEqual(a.path, b.path)
            XCTAssertEqual(a.data, b.data)
        }
    }

    func testEmptyArchiveRoundTrips() throws {
        let archive = ZipWriter.archive([])
        XCTAssertEqual(archive.count, 22)
        XCTAssertEqual(try ZipReader.entries(from: archive).count, 0)
    }

    func testLocalHeaderIsStoredWithUTF8Flag() {
        let archive = ZipWriter.archive([entries[2]])
        XCTAssertEqual(ZipTestData.le32(archive, 0), 0x0403_4B50)
        XCTAssertEqual(ZipTestData.le16(archive, 6) & 0x0800, 0x0800, "UTF-8 name flag (bit 11)")
        XCTAssertEqual(ZipTestData.le16(archive, 8), 0, "method = stored")
        let nameLength = ZipTestData.le16(archive, 26)
        XCTAssertEqual(nameLength, entries[2].path.utf8.count)
        XCTAssertEqual(Data(archive[30..<(30 + nameLength)]), Data(entries[2].path.utf8))
        XCTAssertEqual(ZipTestData.le32(archive, 14), Int(CRC32.checksum(entries[2].data)))
        XCTAssertEqual(ZipTestData.le32(archive, 18), entries[2].data.count)
        XCTAssertEqual(ZipTestData.le32(archive, 22), entries[2].data.count)
    }

    func testCentralDirectoryAndEndRecord() {
        let archive = ZipWriter.archive(entries)
        let eocd = ZipTestData.eocdOffset(archive)
        XCTAssertEqual(ZipTestData.le32(archive, eocd), 0x0605_4B50)
        XCTAssertEqual(ZipTestData.le16(archive, eocd + 8), entries.count)
        XCTAssertEqual(ZipTestData.le16(archive, eocd + 10), entries.count)
        let centralOffset = ZipTestData.centralOffset(archive)
        let centralSize = ZipTestData.le32(archive, eocd + 12)
        XCTAssertEqual(centralOffset + centralSize, eocd)
        XCTAssertEqual(ZipTestData.le32(archive, centralOffset), 0x0201_4B50)
        XCTAssertEqual(ZipTestData.le32(archive, centralOffset + 42), 0, "first entry's local header is at offset 0")
    }

    func testNilModifiedUsesFixed2026Timestamp() throws {
        let archive = ZipWriter.archive([ZipEntry(path: "a", data: Data("x".utf8))])
        XCTAssertEqual(ZipTestData.le16(archive, 10), 0x0000, "DOS time 00:00:00")
        XCTAssertEqual(ZipTestData.le16(archive, 12), 0x5C21, "DOS date 2026-01-01")
        let back = try ZipReader.entries(from: archive)
        XCTAssertEqual(back.first?.modified, ZipTestData.utc(2026, 1, 1))
    }

    func testModifiedRoundTripsAtTwoSecondResolution() throws {
        let when = ZipTestData.utc(2026, 10, 14, 17, 42, 31)
        let archive = ZipWriter.archive([ZipEntry(path: "a", data: Data(), modified: when)])
        XCTAssertEqual(ZipTestData.le16(archive, 10), (17 << 11) | (42 << 5) | (31 / 2))
        XCTAssertEqual(ZipTestData.le16(archive, 12), ((2026 - 1980) << 9) | (10 << 5) | 14)
        let back = try ZipReader.entries(from: archive)
        XCTAssertEqual(back.first?.modified, ZipTestData.utc(2026, 10, 14, 17, 42, 30))
    }

    func testModifiedUsesGivenTimeZone() throws {
        let ny = TimeZone(identifier: "America/New_York")!
        let when = ZipTestData.utc(2026, 11, 1, 20, 0, 0)   // 15:00 EST
        let archive = ZipWriter.archive([ZipEntry(path: "a", data: Data(), modified: when)], timeZone: ny)
        XCTAssertEqual(ZipTestData.le16(archive, 10), 15 << 11)
        let back = try ZipReader.entries(from: archive, timeZone: ny)
        XCTAssertEqual(back.first?.modified, when)
    }

    func testEndRecordWithCommentIsFound() throws {
        var archive = ZipWriter.archive(entries)
        let comment = Data("archive comment with PK\u{05}\u{06} inside".utf8)
        ZipTestData.put16(&archive, ZipTestData.eocdOffset(archive) + 20, comment.count)
        archive.append(comment)
        let back = try ZipReader.entries(from: archive)
        XCTAssertEqual(back.map { $0.path }, entries.map { $0.path })
    }

    func testLocalHeaderExtraFieldIsHonoured() throws {
        // Build by hand: the local header carries an extra field the central directory does not mention.
        let payload = Data("payload".utf8)
        let name = Data("x.txt".utf8)
        let extra = Data([0x55, 0x54, 0x05, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        var a = Data()
        func le16(_ v: Int) { a.append(UInt8(v & 0xFF)); a.append(UInt8((v >> 8) & 0xFF)) }
        func le32(_ v: Int) { le16(v & 0xFFFF); le16((v >> 16) & 0xFFFF) }
        le32(0x0403_4B50); le16(20); le16(0); le16(0); le16(0); le16(0x5C21)
        le32(Int(CRC32.checksum(payload))); le32(payload.count); le32(payload.count)
        le16(name.count); le16(extra.count); a.append(name); a.append(extra); a.append(payload)
        let central = a.count
        le32(0x0201_4B50); le16(20); le16(20); le16(0); le16(0); le16(0); le16(0x5C21)
        le32(Int(CRC32.checksum(payload))); le32(payload.count); le32(payload.count)
        le16(name.count); le16(0); le16(0); le16(0); le16(0); le32(0); le32(0); a.append(name)
        let centralSize = a.count - central
        le32(0x0605_4B50); le16(0); le16(0); le16(1); le16(1); le32(centralSize); le32(central); le16(0)

        let back = try ZipReader.entries(from: a)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back.first?.path, "x.txt")
        XCTAssertEqual(back.first?.data, payload)
    }

    func testPythonZipWithDataDescriptorsDeflateAndComment() throws {
        // zipfile.ZipFile on a non-seekable stream: flag bit 3 (data descriptors), ZIP_DEFLATED,
        // a directory entry, an empty deflated file, a stored file and an archive comment.
        let b64 = """
        UEsDBBQACAAIAEq4UF0AAAAAAAAAAAAAAAAEAAAAZGlyLwMAUEsHCAAAAAACAAAAAAAAAFBLAwQUAAgACABKuFBdAAAAAAAAAAAAAAAADQAAAGRpci9oZWxsby50eHTLSM3JyVfIIIIszy/KSQEAUEsHCK/BS7UQAAAALwAAAFBLAwQUAAgACABKuFBdAAAAAAAAAAAAAAAACQAAAGVtcHR5LmJpbgMAUEsHCAAAAAACAAAAAAAAAFBLAwQUAAgAAAAAACEAAAAAAAAAAAAAAAAACgAAAHN0b3JlZC50eHRzdG9yZWQgYnl0ZXNQSwcIeHemDwwAAAAMAAAAUEsDBBQACAgIAEq4UF0AAAAAAAAAAAAAAAAXAAAAdW5pY29kZS3DqcOoLeaXpeacrC50eHRLTkw7vFLh0ZzJAFBLBwjQTS0jCwAAAAkAAABQSwECFAMUAAgACABKuFBdAAAAAAIAAAAAAAAABAAAAAAAAAAAABAA/UEAAAAAZGlyL1BLAQIUAxQACAAIAEq4UF2vwUu1EAAAAC8AAAANAAAAAAAAAAAAAACAATQAAABkaXIvaGVsbG8udHh0UEsBAhQDFAAIAAgASrhQXQAAAAACAAAAAAAAAAkAAAAAAAAAAAAAAIABfwAAAGVtcHR5LmJpblBLAQIUAxQACAAAAAAAIQB4d6YPDAAAAAwAAAAKAAAAAAAAAAAAAACAAbgAAABzdG9yZWQudHh0UEsBAhQDFAAICAgASrhQXdBNLSMLAAAACQAAABcAAAAAAAAAAAAAAIAB/AAAAHVuaWNvZGUtw6nDqC3ml6XmnKwudHh0UEsFBgAAAAAFAAUAIQEAAEwBAAAUAGFyY2hpdmUgY29tbWVudCBoZXJl
        """
        let data = try XCTUnwrap(Data(base64Encoded: b64, options: .ignoreUnknownCharacters))
        let back = try ZipReader.entries(from: data)
        XCTAssertEqual(back.map { $0.path }, ["dir/hello.txt", "empty.bin", "stored.txt", "unicode-éè-日本.txt"], "directory entry skipped")
        XCTAssertEqual(back[0].data, Data("hello hello hello hello hello hello hello world".utf8))
        XCTAssertEqual(back[1].data, Data())
        XCTAssertEqual(back[2].data, Data("stored bytes".utf8))
        XCTAssertEqual(String(decoding: back[3].data, as: UTF8.self), "café ✓")
    }
}

// MARK: - Reader failure modes

final class ZipReaderErrorTests: XCTestCase {
    let entries = [
        ZipEntry(path: "a.txt", data: Data("alpha alpha alpha".utf8)),
        ZipEntry(path: "b.txt", data: Data("bravo".utf8)),
    ]

    func testEmptyAndGarbageAreNotZips() {
        XCTAssertThrowsError(try ZipReader.entries(from: Data())) { XCTAssertEqual($0 as? ZipError, .notAZip) }
        XCTAssertThrowsError(try ZipReader.entries(from: Data(repeating: 0x41, count: 100))) { XCTAssertEqual($0 as? ZipError, .notAZip) }
        XCTAssertThrowsError(try ZipReader.entries(from: Data("PK".utf8))) { XCTAssertEqual($0 as? ZipError, .notAZip) }
    }

    func testTruncatedTailLosesEndRecord() {
        let archive = ZipWriter.archive(entries)
        for cut in [1, 5, 21, 22, 40, archive.count / 2] {
            let truncated = archive.prefix(archive.count - cut)
            XCTAssertThrowsError(try ZipReader.entries(from: Data(truncated)), "cut \(cut)") { error in
                XCTAssertTrue(error is ZipError)
            }
        }
    }

    func testEntrySizeBeyondEndIsTruncated() {
        var archive = ZipWriter.archive(entries)
        let central = ZipTestData.centralOffset(archive)
        ZipTestData.put32(&archive, central + 20, 10_000)   // compressed size
        ZipTestData.put32(&archive, central + 24, 10_000)   // uncompressed size
        XCTAssertThrowsError(try ZipReader.entries(from: archive)) { XCTAssertEqual($0 as? ZipError, .truncated) }
    }

    func testCentralDirectoryBeyondEndIsTruncated() {
        var archive = ZipWriter.archive(entries)
        ZipTestData.put32(&archive, ZipTestData.eocdOffset(archive) + 12, 0x7FFF_0000)
        XCTAssertThrowsError(try ZipReader.entries(from: archive)) { XCTAssertEqual($0 as? ZipError, .truncated) }
    }

    func testLocalHeaderOffsetBeyondEndIsTruncated() {
        var archive = ZipWriter.archive(entries)
        let central = ZipTestData.centralOffset(archive)
        ZipTestData.put32(&archive, central + 42, archive.count + 100)
        XCTAssertThrowsError(try ZipReader.entries(from: archive)) { XCTAssertEqual($0 as? ZipError, .truncated) }
    }

    func testCorruptedDataFailsCRC() {
        var archive = ZipWriter.archive(entries)
        archive[30 + 5] ^= 0xFF   // first byte of a.txt's payload
        XCTAssertThrowsError(try ZipReader.entries(from: archive)) { XCTAssertEqual($0 as? ZipError, .crcMismatch("a.txt")) }
    }

    func testWrongCentralCRCFieldFails() {
        var archive = ZipWriter.archive(entries)
        let central = ZipTestData.centralOffset(archive)
        let secondHeader = central + 46 + "a.txt".utf8.count
        ZipTestData.put32(&archive, secondHeader + 16, 0x1234_5678)
        XCTAssertThrowsError(try ZipReader.entries(from: archive)) { XCTAssertEqual($0 as? ZipError, .crcMismatch("b.txt")) }
    }

    func testUnsupportedMethod() {
        var archive = ZipWriter.archive(entries)
        let central = ZipTestData.centralOffset(archive)
        ZipTestData.put16(&archive, central + 10, 12)   // bzip2
        XCTAssertThrowsError(try ZipReader.entries(from: archive)) { XCTAssertEqual($0 as? ZipError, .unsupportedCompression(12)) }
    }

    func testZip64MarkersAreRejected() {
        var a = ZipWriter.archive(entries)
        ZipTestData.put16(&a, ZipTestData.eocdOffset(a) + 10, 0xFFFF)
        XCTAssertThrowsError(try ZipReader.entries(from: a)) { XCTAssertEqual($0 as? ZipError, .unsupportedCompression(-1)) }

        var b = ZipWriter.archive(entries)
        let central = ZipTestData.centralOffset(b)
        ZipTestData.put32(&b, central + 24, 0xFFFF_FFFF)
        XCTAssertThrowsError(try ZipReader.entries(from: b)) { XCTAssertEqual($0 as? ZipError, .unsupportedCompression(-1)) }
    }

    func testBadCentralSignatureIsCorrupt() {
        var archive = ZipWriter.archive(entries)
        let central = ZipTestData.centralOffset(archive)
        ZipTestData.put32(&archive, central, 0x0000_0000)
        XCTAssertThrowsError(try ZipReader.entries(from: archive)) { XCTAssertEqual($0 as? ZipError, .corruptEntry("central directory")) }
    }

    func testBadLocalSignatureIsCorrupt() {
        var archive = ZipWriter.archive(entries)
        ZipTestData.put32(&archive, 0, 0x1111_1111)
        XCTAssertThrowsError(try ZipReader.entries(from: archive)) { XCTAssertEqual($0 as? ZipError, .corruptEntry("a.txt")) }
    }

    func testStoredSizeMismatchIsCorrupt() {
        var archive = ZipWriter.archive(entries)
        let central = ZipTestData.centralOffset(archive)
        ZipTestData.put32(&archive, central + 24, 3)   // uncompressed ≠ compressed for a stored entry
        XCTAssertThrowsError(try ZipReader.entries(from: archive)) { XCTAssertEqual($0 as? ZipError, .corruptEntry("a.txt")) }
    }

    func testEveryPrefixOfAnArchiveFailsWithoutTrapping() {
        let archive = ZipWriter.archive(entries)
        for length in 0..<archive.count {
            XCTAssertThrowsError(try ZipReader.entries(from: archive.prefix(length)))
        }
    }
}

// MARK: - Inflate

final class InflateTests: XCTestCase {
    static let inputs: [(name: String, data: Data)] = [
        ("empty", Data()),
        ("oneByte", Data("A".utf8)),
        ("repetitive200k", ZipTestData.repetitiveText()),
        ("random64k", ZipTestData.pseudoRandomBytes(count: 64 * 1024)),
    ]

    func testGeneratorsMatchPythonFixtures() {
        XCTAssertEqual(Array(ZipTestData.pseudoRandomBytes(count: 8)), [5, 4, 139, 162, 232, 28, 126, 140])
        XCTAssertEqual(ZipTestData.repetitiveText().count, 204_800)
        XCTAssertEqual(ZipTestData.pseudoRandomBytes(count: 64 * 1024).count, 65_536)
    }

    func testAllFixturesInflateExactly() throws {
        for (name, original) in InflateTests.inputs {
            for level in [0, 1, 6, 9] {
                let stream = try XCTUnwrap(DeflateFixtures.stream(for: name, level: level), "\(name) L\(level)")
                let out = try Inflate.decompress(stream)
                XCTAssertEqual(out.count, original.count, "\(name) L\(level) length")
                XCTAssertTrue(out == original, "\(name) L\(level) content")
            }
        }
    }

    func testLevel0UsesStoredBlocksAndIsLargerThanInput() throws {
        let stream = try XCTUnwrap(DeflateFixtures.stream(for: "repetitive200k", level: 0))
        XCTAssertGreaterThan(stream.count, 204_800)
        XCTAssertEqual(stream[0] & 0x06, 0, "first block is stored")
    }

    func testDynamicHuffmanStreamIsTiny() throws {
        let stream = try XCTUnwrap(DeflateFixtures.stream(for: "repetitive200k", level: 9))
        XCTAssertLessThan(stream.count, 1000)
        XCTAssertEqual((stream[0] >> 1) & 0x03, 2, "first block uses dynamic Huffman codes")
    }

    func testHandBuiltFixedHuffmanStream() throws {
        // BFINAL=1, BTYPE=01, literal 'A' (0x41 → code 0x71, 8 bits), end-of-block (7 zero bits).
        let out = try Inflate.decompress(Data([0x73, 0x04, 0x00]))
        XCTAssertEqual(out, Data("A".utf8))
    }

    func testHandBuiltStoredBlock() throws {
        let out = try Inflate.decompress(Data([0x01, 0x03, 0x00, 0xFC, 0xFF, 0x61, 0x62, 0x63]))
        XCTAssertEqual(out, Data("abc".utf8))
    }

    func testEmptyInputThrows() {
        XCTAssertThrowsError(try Inflate.decompress(Data())) { XCTAssertEqual($0 as? ZipError, .corruptEntry("deflate stream truncated")) }
    }

    func testInvalidBlockTypeThrows() {
        XCTAssertThrowsError(try Inflate.decompress(Data([0x07]))) { XCTAssertEqual($0 as? ZipError, .corruptEntry("invalid block type")) }
    }

    func testStoredLengthMismatchThrows() {
        XCTAssertThrowsError(try Inflate.decompress(Data([0x01, 0x05, 0x00, 0x00, 0x00]))) {
            XCTAssertEqual($0 as? ZipError, .corruptEntry("stored block length mismatch"))
        }
    }

    func testStoredBlockShorterThanLengthThrows() {
        XCTAssertThrowsError(try Inflate.decompress(Data([0x01, 0x05, 0x00, 0xFA, 0xFF, 0x61]))) {
            XCTAssertEqual($0 as? ZipError, .corruptEntry("deflate stream truncated"))
        }
    }

    func testDistanceBeforeStartThrows() {
        // Fixed block whose first symbol is a length/distance pair pointing before the output start.
        XCTAssertThrowsError(try Inflate.decompress(Data([0x03, 0x02]))) {
            XCTAssertEqual($0 as? ZipError, .corruptEntry("distance too far back"))
        }
    }

    func testTruncatedStreamsThrow() throws {
        for (name, _) in InflateTests.inputs where name != "empty" {
            for level in [0, 1, 6, 9] {
                let stream = try XCTUnwrap(DeflateFixtures.stream(for: name, level: level))
                for fraction in [0.1, 0.5, 0.9] {
                    let cut = max(1, Int(Double(stream.count) * fraction))
                    XCTAssertThrowsError(try Inflate.decompress(stream.prefix(cut)), "\(name) L\(level) cut \(cut)") { error in
                        guard case .corruptEntry = error as? ZipError else { return XCTFail("unexpected \(error)") }
                    }
                }
            }
        }
    }

    func testEveryPrefixOfASmallStreamThrows() throws {
        let stream = try XCTUnwrap(DeflateFixtures.stream(for: "repetitive200k", level: 9))
        for length in 0..<stream.count {
            XCTAssertThrowsError(try Inflate.decompress(stream.prefix(length)), "prefix \(length)")
        }
    }

    func testBitFlipsNeverTrap() throws {
        let stream = try XCTUnwrap(DeflateFixtures.stream(for: "repetitive200k", level: 9))
        for i in stride(from: 0, to: stream.count, by: 7) {
            for mask: UInt8 in [0x01, 0x10, 0x80] {
                var mutated = stream
                mutated[i] ^= mask
                _ = try? Inflate.decompress(mutated)   // must throw or return, never crash
            }
        }
    }

    func testRandomGarbageNeverTraps() {
        var seed: UInt32 = 99
        for _ in 0..<400 {
            seed = seed &* 1664525 &+ 1013904223
            let length = Int(seed % 300) + 1
            let garbage = ZipTestData.pseudoRandomBytes(count: length, seed: seed)
            _ = try? Inflate.decompress(garbage)
        }
    }

    func testOversubscribedDynamicCodeThrows() {
        // Dynamic block header with HCLEN describing 19 code-length codes all of length 1 (over-subscribed).
        var bits: [Int] = [1, 0, 1]                  // BFINAL=1, BTYPE=10 (LSB first)
        bits += [0, 0, 0, 0, 0]                      // HLIT = 257
        bits += [0, 0, 0, 0, 0]                      // HDIST = 1
        bits += [1, 1, 1, 1]                         // HCLEN = 19
        for _ in 0..<19 { bits += [1, 0, 0] }        // every code-length code has length 1
        var bytes = [UInt8](repeating: 0, count: (bits.count + 7) / 8 + 4)
        for (i, b) in bits.enumerated() where b == 1 { bytes[i / 8] |= UInt8(1 << (i % 8)) }
        XCTAssertThrowsError(try Inflate.decompress(Data(bytes))) {
            XCTAssertEqual($0 as? ZipError, .corruptEntry("bad code-length code"))
        }
    }
}
