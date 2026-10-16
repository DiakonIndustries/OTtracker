import XCTest
@testable import OTCSV

final class CSVParseTests: XCTestCase {
    func testEmptyInputGivesNoRows() {
        XCTAssertEqual(CSV.parse(""), [])
    }

    func testSimpleRowsWithLF() {
        XCTAssertEqual(CSV.parse("a,b,c\n1,2,3\n"), [["a", "b", "c"], ["1", "2", "3"]])
    }

    func testSimpleRowsWithCRLF() {
        XCTAssertEqual(CSV.parse("a,b\r\n1,2\r\n"), [["a", "b"], ["1", "2"]])
    }

    func testLoneCRIsALineBreak() {
        XCTAssertEqual(CSV.parse("a,b\r1,2\r"), [["a", "b"], ["1", "2"]])
    }

    func testMissingTrailingNewlineIsFine() {
        XCTAssertEqual(CSV.parse("a,b\n1,2"), [["a", "b"], ["1", "2"]])
    }

    func testTrailingNewlineAddsNoRow() {
        XCTAssertEqual(CSV.parse("a\n").count, 1)
        XCTAssertEqual(CSV.parse("a\r\n").count, 1)
    }

    func testBOMIsStripped() {
        XCTAssertEqual(CSV.parse("\u{FEFF}record,date\nx,y\n"), [["record", "date"], ["x", "y"]])
    }

    func testQuotedFieldWithEmbeddedComma() {
        XCTAssertEqual(CSV.parse("\"a,b\",c\n"), [["a,b", "c"]])
    }

    func testQuotedFieldWithEscapedQuotes() {
        XCTAssertEqual(CSV.parse("\"say \"\"hi\"\"\",x\n"), [["say \"hi\"", "x"]])
        XCTAssertEqual(CSV.parse("\"\"\"\"\n"), [["\""]])
    }

    func testQuotedFieldWithEmbeddedNewlines() {
        XCTAssertEqual(CSV.parse("\"line1\nline2\",b\n"), [["line1\nline2", "b"]])
        XCTAssertEqual(CSV.parse("\"line1\r\nline2\",b\r\n"), [["line1\r\nline2", "b"]])
    }

    func testEmptyFields() {
        XCTAssertEqual(CSV.parse(",,\n"), [["", "", ""]])
        XCTAssertEqual(CSV.parse("a,,c\n"), [["a", "", "c"]])
        XCTAssertEqual(CSV.parse("a,\"\",c\n"), [["a", "", "c"]])
    }

    func testTrailingCommaGivesEmptyLastField() {
        XCTAssertEqual(CSV.parse("a,b,\n"), [["a", "b", ""]])
    }

    func testRaggedRowsAreKept() {
        XCTAssertEqual(CSV.parse("a,b,c\n1\n4,5,6,7\n"), [["a", "b", "c"], ["1"], ["4", "5", "6", "7"]])
    }

    func testBlankLineIsOneEmptyField() {
        XCTAssertEqual(CSV.parse("a\n\nb\n"), [["a"], [""], ["b"]])
    }

    func testSpacesArePreserved() {
        XCTAssertEqual(CSV.parse(" a , b \n"), [[" a ", " b "]])
    }

    func testStrayQuoteInsideUnquotedFieldIsKept() {
        XCTAssertEqual(CSV.parse("5\" tall,x\n"), [["5\" tall", "x"]])
    }

    func testTextAfterClosingQuoteIsKept() {
        XCTAssertEqual(CSV.parse("\"a\"b,c\n"), [["ab", "c"]])
    }

    func testUnterminatedQuoteFlushesAtEnd() {
        XCTAssertEqual(CSV.parse("\"abc"), [["abc"]])
    }

    func testUnicodeContent() {
        XCTAssertEqual(CSV.parse("héllo,日本,🙂\n"), [["héllo", "日本", "🙂"]])
    }
}

final class CSVSerializeTests: XCTestCase {
    func testPlainFieldsUnquotedWithCRLFAndTrailingNewline() {
        XCTAssertEqual(CSV.serialize([["a", "b"], ["1", "2"]]), "a,b\r\n1,2\r\n")
    }

    func testNoRowsGivesEmptyString() {
        XCTAssertEqual(CSV.serialize([]), "")
    }

    func testEmptyRowGivesBareLineBreak() {
        XCTAssertEqual(CSV.serialize([[]]), "\r\n")
    }

    func testCommaIsQuoted() {
        XCTAssertEqual(CSV.serialize([["a,b"]]), "\"a,b\"\r\n")
    }

    func testQuoteIsDoubledAndQuoted() {
        XCTAssertEqual(CSV.serialize([["say \"hi\""]]), "\"say \"\"hi\"\"\"\r\n")
    }

    func testLineBreaksAreQuoted() {
        XCTAssertEqual(CSV.serialize([["a\nb"]]), "\"a\nb\"\r\n")
        XCTAssertEqual(CSV.serialize([["a\rb"]]), "\"a\rb\"\r\n")
        XCTAssertEqual(CSV.serialize([["a\r\nb"]]), "\"a\r\nb\"\r\n")
    }

    func testLeadingOrTrailingSpaceIsQuoted() {
        XCTAssertEqual(CSV.serialize([[" a"]]), "\" a\"\r\n")
        XCTAssertEqual(CSV.serialize([["a "]]), "\"a \"\r\n")
        XCTAssertEqual(CSV.serialize([["a b"]]), "a b\r\n")
    }

    func testEmptyFieldStaysEmpty() {
        XCTAssertEqual(CSV.serialize([["", "x", ""]]), ",x,\r\n")
    }

    func testSerializeThenParseIsIdentity() {
        let rows: [[String]] = [
            ["record", "date", "note"],
            ["a,b", "say \"hi\"", "multi\nline"],
            [" lead", "trail ", ""],
            ["\r\n", "\"", "plain"],
            ["日本", "", "x"],
            [],
            ["single"],
        ]
        XCTAssertEqual(CSV.parse(CSV.serialize(rows)), rows.map { $0.isEmpty ? [""] : $0 })
    }

    func testParseThenSerializeIsStableForCanonicalText() {
        let text = "a,b\r\n\"x,y\",\"q\"\"q\"\r\n"
        XCTAssertEqual(CSV.serialize(CSV.parse(text)), text)
    }
}
