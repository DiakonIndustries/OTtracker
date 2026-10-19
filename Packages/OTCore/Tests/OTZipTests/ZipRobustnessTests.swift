import XCTest
@testable import OTZip

// MARK: - Hand-built archives

extension ZipTestData {
    struct RawEntry {
        var name: String
        var method: Int
        var compressed: Data
        var crc: UInt32
        var uncompressedSize: Int
        var flags: Int = 0
    }

    /// Builds an archive from pre-compressed payloads so DEFLATE entries and odd headers can be tested.
    static func handArchive(_ entries: [RawEntry], comment: Data = Data()) -> Data {
        var a = Data()
        var central = Data()
        func le16(_ d: inout Data, _ v: Int) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        func le32(_ d: inout Data, _ v: Int) { le16(&d, v & 0xFFFF); le16(&d, (v >> 16) & 0xFFFF) }
        for e in entries {
            let name = Data(e.name.utf8)
            let offset = a.count
            le32(&a, 0x0403_4B50); le16(&a, 20); le16(&a, e.flags); le16(&a, e.method); le16(&a, 0); le16(&a, 0x5C21)
            le32(&a, Int(e.crc)); le32(&a, e.compressed.count); le32(&a, e.uncompressedSize)
            le16(&a, name.count); le16(&a, 0); a.append(name); a.append(e.compressed)
            le32(&central, 0x0201_4B50); le16(&central, 20); le16(&central, 20); le16(&central, e.flags); le16(&central, e.method)
            le16(&central, 0); le16(&central, 0x5C21)
            le32(&central, Int(e.crc)); le32(&central, e.compressed.count); le32(&central, e.uncompressedSize)
            le16(&central, name.count); le16(&central, 0); le16(&central, 0); le16(&central, 0); le16(&central, 0); le32(&central, 0)
            le32(&central, offset); central.append(name)
        }
        let centralOffset = a.count
        a.append(central)
        le32(&a, 0x0605_4B50); le16(&a, 0); le16(&a, 0); le16(&a, entries.count); le16(&a, entries.count)
        le32(&a, central.count); le32(&a, centralOffset); le16(&a, comment.count); a.append(comment)
        return a
    }

    /// Deterministic 32-bit LCG for the fuzzers.
    struct LCG {
        var state: UInt32
        mutating func next() -> UInt32 {
            state = state &* 1664525 &+ 1013904223
            return state
        }
        mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt32(n)) }
    }

    /// One seeded mutation: bit flips, truncation, byte overwrites or an insertion.
    static func mutate(_ original: Data, rng: inout LCG) -> (Data, String) {
        var d = original
        guard !d.isEmpty else { return (d, "empty") }
        switch rng.below(5) {
        case 0:
            let flips = 1 + rng.below(8)
            for _ in 0..<flips { d[d.startIndex + rng.below(d.count)] ^= UInt8(1 << rng.below(8)) }
            return (d, "flip×\(flips)")
        case 1:
            let keep = rng.below(d.count)
            return (Data(d.prefix(keep)), "truncate→\(keep)")
        case 2:
            let writes = 1 + rng.below(16)
            for _ in 0..<writes { d[d.startIndex + rng.below(d.count)] = UInt8(truncatingIfNeeded: rng.next()) }
            return (d, "overwrite×\(writes)")
        case 3:
            let at = rng.below(d.count)
            let junk = Data((0..<(1 + rng.below(32))).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            d.insert(contentsOf: junk, at: d.startIndex + at)
            return (d, "insert \(junk.count)@\(at)")
        default:
            // Flip one byte in the first 64 bytes (headers) and truncate the tail a little.
            d[d.startIndex + rng.below(min(64, d.count))] ^= 0xFF
            let cut = rng.below(min(32, d.count))
            return (Data(d.prefix(d.count - cut)), "header-flip+cut \(cut)")
        }
    }
}

// MARK: - Real-world archive shapes

final class ZipArchiveShapeTests: XCTestCase {
    /// A DEFLATE entry well over 64 KB that zlib encoded with dynamic Huffman blocks, read through the archive path.
    func testDeflatedEntryLargerThan64KBWithDynamicHuffman() throws {
        let text = ZipTestData.repetitiveText()
        let random = ZipTestData.pseudoRandomBytes(count: 64 * 1024)
        let textStream = try XCTUnwrap(DeflateFixtures.stream(for: "repetitive200k", level: 9))
        let randomStream = try XCTUnwrap(DeflateFixtures.stream(for: "random64k", level: 6))
        XCTAssertEqual((textStream[0] >> 1) & 0x03, 2, "dynamic Huffman")
        let archive = ZipTestData.handArchive([
            .init(name: "big.txt", method: 8, compressed: textStream, crc: CRC32.checksum(text), uncompressedSize: text.count),
            .init(name: "random.bin", method: 8, compressed: randomStream, crc: CRC32.checksum(random), uncompressedSize: random.count),
        ])
        let back = try ZipReader.entries(from: archive)
        XCTAssertEqual(back.map { $0.path }, ["big.txt", "random.bin"])
        XCTAssertEqual(back[0].data.count, 204_800)
        XCTAssertTrue(back[0].data == text)
        XCTAssertTrue(back[1].data == random)
    }

    func testEmptyEntriesInEveryEncoding() throws {
        let archive = ZipTestData.handArchive([
            .init(name: "stored-empty", method: 0, compressed: Data(), crc: 0, uncompressedSize: 0),
            .init(name: "deflated-empty", method: 8, compressed: Data([0x03, 0x00]), crc: 0, uncompressedSize: 0),
            .init(name: "deflated-no-stream", method: 8, compressed: Data(), crc: 0, uncompressedSize: 0),
            .init(name: "descriptor-empty", method: 8, compressed: Data([0x03, 0x00]), crc: 0, uncompressedSize: 0, flags: 0x08),
        ])
        let back = try ZipReader.entries(from: archive)
        XCTAssertEqual(back.map { $0.path }, ["stored-empty", "deflated-empty", "deflated-no-stream", "descriptor-empty"])
        XCTAssertTrue(back.allSatisfy { $0.data.isEmpty })
    }

    func testStoredEntryWithZeroCRCButDataIsAMismatch() {
        let payload = Data("not empty".utf8)
        let archive = ZipTestData.handArchive([
            .init(name: "zero.txt", method: 0, compressed: payload, crc: 0, uncompressedSize: payload.count),
        ])
        XCTAssertThrowsError(try ZipReader.entries(from: archive)) { XCTAssertEqual($0 as? ZipError, .crcMismatch("zero.txt")) }
    }

    func testDeclaredSizeBoundsInflation() throws {
        // The stream inflates to 200 KB but the directory claims 100 bytes: stop early instead of inflating it all.
        let stream = try XCTUnwrap(DeflateFixtures.stream(for: "repetitive200k", level: 9))
        let text = ZipTestData.repetitiveText()
        let lying = ZipTestData.handArchive([
            .init(name: "bomb.txt", method: 8, compressed: stream, crc: CRC32.checksum(text), uncompressedSize: 100),
        ])
        XCTAssertThrowsError(try ZipReader.entries(from: lying)) { error in
            guard case .corruptEntry(let what)? = error as? ZipError else { return XCTFail("\(error)") }
            XCTAssertTrue(what.hasPrefix("bomb.txt"), what)
        }
        // Claiming more than the stream yields is also corrupt (size check after a complete inflate).
        let bigger = ZipTestData.handArchive([
            .init(name: "short.txt", method: 8, compressed: stream, crc: CRC32.checksum(text), uncompressedSize: text.count + 1),
        ])
        XCTAssertThrowsError(try ZipReader.entries(from: bigger)) { XCTAssertEqual($0 as? ZipError, .corruptEntry("short.txt")) }
        // The exact size reads fine.
        let exact = ZipTestData.handArchive([
            .init(name: "ok.txt", method: 8, compressed: stream, crc: CRC32.checksum(text), uncompressedSize: text.count),
        ])
        XCTAssertEqual(try ZipReader.entries(from: exact).first?.data.count, text.count)
    }

    func testInflateOutputBoundIsExact() throws {
        let stream = try XCTUnwrap(DeflateFixtures.stream(for: "repetitive200k", level: 9))
        XCTAssertEqual(try Inflate.decompress(stream, maxOutputSize: 204_800).count, 204_800)
        XCTAssertThrowsError(try Inflate.decompress(stream, maxOutputSize: 204_799)) {
            XCTAssertEqual($0 as? ZipError, .corruptEntry("inflated data exceeds declared size"))
        }
        XCTAssertThrowsError(try Inflate.decompress(stream, maxOutputSize: 0))
        let stored = try XCTUnwrap(DeflateFixtures.stream(for: "oneByte", level: 0))
        XCTAssertEqual(try Inflate.decompress(stored, maxOutputSize: 1), Data("A".utf8))
        XCTAssertThrowsError(try Inflate.decompress(stored, maxOutputSize: 0))
    }

    func testEndRecordSignatureInsideALongCommentIsSkipped() throws {
        let entries = [ZipEntry(path: "a.txt", data: Data("alpha".utf8)), ZipEntry(path: "b.txt", data: Data("bravo".utf8))]
        // A comment longer than an end record whose first bytes spell the end-record signature.
        var comment = Data([0x50, 0x4B, 0x05, 0x06])
        comment.append(Data(repeating: 0x41, count: 60))
        let archive = ZipTestData.handArchive(
            entries.map { .init(name: $0.path, method: 0, compressed: $0.data, crc: CRC32.checksum($0.data), uncompressedSize: $0.data.count) },
            comment: comment)
        let back = try ZipReader.entries(from: archive)
        XCTAssertEqual(back.map { $0.path }, ["a.txt", "b.txt"])
        XCTAssertEqual(back[1].data, Data("bravo".utf8))
    }

    func testPythonDescriptorArchiveLocalHeadersCarryZeroSizes() throws {
        // Confirms the fixture really exercises bit 3: local sizes are zero, the central directory has the truth.
        let data = try XCTUnwrap(Data(base64Encoded: ZipTestData.pythonDescriptorArchive, options: .ignoreUnknownCharacters))
        XCTAssertEqual(ZipTestData.le16(data, 6) & 0x08, 0x08, "bit 3 set on the first local header")
        XCTAssertEqual(ZipTestData.le32(data, 18), 0, "local compressed size is zero")
        XCTAssertEqual(ZipTestData.le32(data, 22), 0, "local uncompressed size is zero")
        XCTAssertEqual(try ZipReader.entries(from: data).count, 4)
    }
}

// MARK: - Fuzzing

final class ZipFuzzTests: XCTestCase {
    /// Generous per-call bound; a healthy call takes milliseconds. Catches infinite loops and runaway allocation.
    static let perCallLimit: TimeInterval = 5

    private func timed(_ label: String, _ body: () throws -> Void) {
        let started = ProcessInfo.processInfo.systemUptime
        _ = try? body()   // throwing is the expected outcome; returning is acceptable; trapping or hanging is not
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThan(elapsed, ZipFuzzTests.perCallLimit, "\(label) took \(elapsed)s")
    }

    func testTwoHundredSeededMutationsOfDeflateStreamsNeverTrapOrHang() throws {
        let streams: [(String, Data, Int)] = try [
            ("repetitive200k L9", XCTUnwrap(DeflateFixtures.stream(for: "repetitive200k", level: 9)), 204_800),
            ("repetitive200k L1", XCTUnwrap(DeflateFixtures.stream(for: "repetitive200k", level: 1)), 204_800),
            ("random64k L6", XCTUnwrap(DeflateFixtures.stream(for: "random64k", level: 6)), 65_536),
            ("random64k L0", XCTUnwrap(DeflateFixtures.stream(for: "random64k", level: 0)), 65_536),
        ]
        var rng = ZipTestData.LCG(state: 0xC0FFEE)
        var outcomes = (threw: 0, returned: 0)
        for i in 0..<200 {
            let (name, stream, size) = streams[i % streams.count]
            let (mutated, how) = ZipTestData.mutate(stream, rng: &rng)
            timed("#\(i) \(name) \(how)") {
                do {
                    _ = try Inflate.decompress(mutated, maxOutputSize: size * 2 + 1024)
                    outcomes.returned += 1
                } catch {
                    guard case .corruptEntry = error as? ZipError else { return XCTFail("#\(i) \(name) \(how): \(error)") }
                    outcomes.threw += 1
                    throw error
                }
            }
        }
        XCTAssertEqual(outcomes.threw + outcomes.returned, 200)
        XCTAssertGreaterThan(outcomes.threw, 100, "most mutations of a compressed stream must be detected")
    }

    func testTwoHundredSeededMutationsOfArchivesNeverTrapOrHang() throws {
        let text = ZipTestData.repetitiveText()
        let textStream = try XCTUnwrap(DeflateFixtures.stream(for: "repetitive200k", level: 9))
        let archives: [(String, Data)] = try [
            ("stored", ZipWriter.archive([
                ZipEntry(path: "a.txt", data: Data("alpha alpha alpha".utf8)),
                ZipEntry(path: "dir/b.bin", data: ZipTestData.pseudoRandomBytes(count: 3000)),
                ZipEntry(path: "empty", data: Data()),
            ])),
            ("python-descriptors", XCTUnwrap(Data(base64Encoded: ZipTestData.pythonDescriptorArchive, options: .ignoreUnknownCharacters))),
            ("deflate-200k", ZipTestData.handArchive([
                .init(name: "big.txt", method: 8, compressed: textStream, crc: CRC32.checksum(text), uncompressedSize: text.count),
            ])),
        ]
        var rng = ZipTestData.LCG(state: 0xBEEF)
        var outcomes = (threw: 0, returned: 0)
        for i in 0..<200 {
            let (name, archive) = archives[i % archives.count]
            let (mutated, how) = ZipTestData.mutate(archive, rng: &rng)
            timed("#\(i) \(name) \(how)") {
                do {
                    _ = try ZipReader.entries(from: mutated)
                    outcomes.returned += 1
                } catch {
                    XCTAssertTrue(error is ZipError, "#\(i) \(name) \(how): \(error)")
                    outcomes.threw += 1
                    throw error
                }
            }
        }
        XCTAssertEqual(outcomes.threw + outcomes.returned, 200)
        XCTAssertGreaterThan(outcomes.threw, 100)
    }

    func testEveryTruncationOfADescriptorArchiveThrowsOrOnlyLosesTheComment() throws {
        let data = try XCTUnwrap(Data(base64Encoded: ZipTestData.pythonDescriptorArchive, options: .ignoreUnknownCharacters))
        let comment = "archive comment here".utf8.count
        let endRecord = data.count - 22 - comment
        XCTAssertEqual(ZipTestData.le32(data, endRecord), 0x0605_4B50)
        for length in 0..<data.count {
            if length < endRecord + 22 {
                XCTAssertThrowsError(try ZipReader.entries(from: data.prefix(length)), "prefix \(length)")
            } else {
                // Only the comment is cut: the record is intact and the entries still read.
                XCTAssertEqual(try ZipReader.entries(from: data.prefix(length)).count, 4, "prefix \(length)")
            }
        }
    }
}
