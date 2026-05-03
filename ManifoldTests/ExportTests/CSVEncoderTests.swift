// Manifold — visualizes physical USB and Thunderbolt connections live.
// Copyright (C) 2026 Brandon Villar
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// ─────────────────────────────────────────────────────────────────────
// CSVEncoderTests.swift
//
// Pin RFC 4180 quoting + CRLF + UTF-8 BOM. The headline contract is
// "Excel + Numbers open it cleanly" — the BOM is what makes that
// hold across both apps; this test class is what catches a future
// "small refactor" that drops the BOM.

import XCTest
@testable import Manifold

final class CSVEncoderTests: XCTestCase {

    // MARK: - quote()

    /// Plain ASCII with no reserved characters → emit verbatim.
    func test_quote_plainField_returnsVerbatim() {
        XCTAssertEqual(CSVEncoder.quote("hello"), "hello")
    }

    /// Comma in the field → wrap in quotes.
    func test_quote_fieldWithComma_wrapsInQuotes() {
        XCTAssertEqual(CSVEncoder.quote("a,b"), "\"a,b\"")
    }

    /// Quote in the field → wrap AND double the embedded quote.
    func test_quote_fieldWithQuote_doublesQuote() {
        XCTAssertEqual(CSVEncoder.quote("say \"hi\""), "\"say \"\"hi\"\"\"")
    }

    /// Newline in the field → wrap in quotes (Excel folds the cell
    /// across rows correctly when quoted).
    func test_quote_fieldWithNewline_wrapsInQuotes() {
        XCTAssertEqual(CSVEncoder.quote("line1\nline2"), "\"line1\nline2\"")
    }

    /// Empty string → empty (not `""`). RFC 4180 leaves empty cells
    /// as nothing between commas; quoting an empty string would
    /// be valid but unnecessarily noisy.
    func test_quote_emptyField_isEmpty() {
        XCTAssertEqual(CSVEncoder.quote(""), "")
    }

    // MARK: - encodeRow()

    /// Mixed fields — some quote, some not.
    func test_encodeRow_mixedFields_quotesOnlyAsNeeded() {
        let row = CSVEncoder.encodeRow(["plain", "with,comma", "with\"quote", "trailing"])
        XCTAssertEqual(row, "plain,\"with,comma\",\"with\"\"quote\",trailing")
    }

    // MARK: - encode()

    /// Header + two rows + CRLF after every line.
    func test_encode_headerAndRows_endsEveryLineWithCRLF() {
        let csv = CSVEncoder.encode(
            header: ["a", "b"],
            rows: [["1", "2"], ["3", "4"]]
        )
        XCTAssertEqual(csv, "a,b\r\n1,2\r\n3,4\r\n")
    }

    // MARK: - encodeData()

    /// `encodeData` prefixes the UTF-8 BOM (3 bytes EF BB BF).
    func test_encodeData_prefixesUTF8BOM() {
        let data = CSVEncoder.encodeData(header: ["a"], rows: [["1"]])
        XCTAssertEqual(data.prefix(3), Data([0xEF, 0xBB, 0xBF]))
    }

    /// `encodeData` round-trips through UTF-8 cleanly so non-ASCII
    /// characters survive. (A 1-byte off-by-one in the BOM emit
    /// would manifest as garbled output here.)
    func test_encodeData_roundTripsNonASCIIAfterBOM() {
        let data = CSVEncoder.encodeData(header: ["name"], rows: [["café"]])
        let body = data.dropFirst(3)  // skip BOM
        let decoded = String(data: body, encoding: .utf8)
        XCTAssertEqual(decoded, "name\r\ncafé\r\n")
    }
}
