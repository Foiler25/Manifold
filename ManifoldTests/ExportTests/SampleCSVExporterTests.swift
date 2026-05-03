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
// SampleCSVExporterTests.swift
//
// Pin per-row column projection + the optional-cells-empty contract
// (nil watts/mbps must render as empty cells, NOT "nil").

import XCTest
@testable import Manifold
import ManifoldKit

final class SampleCSVExporterTests: XCTestCase {

    func test_header_matchesDocumentedShape() {
        XCTAssertEqual(
            SampleCSVExporter.header,
            ["timestamp_iso8601", "aggregation", "device_id", "port_id", "watts", "mbps"]
        )
    }

    /// Populated sample → every column populated; watts formatted to
    /// 4 decimal places (consistent with EventLogCSVExporter); mbps
    /// emitted as plain integer.
    func test_row_populatedSample_hasAllColumns() {
        let sample = StoredSample(
            id: 1,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            deviceID: DeviceID("VID:PID:SN"),
            portID: PortID("/host/port-1"),
            watts: 2.5,
            mbps: 5000,
            aggregation: .raw
        )
        let row = SampleCSVExporter.row(for: sample)
        XCTAssertEqual(row[1], "raw")
        XCTAssertEqual(row[2], "VID:PID:SN")
        XCTAssertEqual(row[3], "/host/port-1")
        XCTAssertEqual(row[4], "2.5000")
        XCTAssertEqual(row[5], "5000")
    }

    /// nil watts + nil mbps render as empty cells. Pins the "the
    /// reader sees an empty cell, not the literal 'nil'" contract.
    func test_row_nilOptionalsRenderAsEmptyCells() {
        let sample = StoredSample(
            id: 2,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            deviceID: nil,
            portID: PortID("/p"),
            watts: nil,
            mbps: nil,
            aggregation: .oneMin
        )
        let row = SampleCSVExporter.row(for: sample)
        XCTAssertEqual(row[1], "1min")
        XCTAssertEqual(row[2], "")  // nil deviceID
        XCTAssertEqual(row[4], "")  // nil watts
        XCTAssertEqual(row[5], "")  // nil mbps
    }

    /// `encode` round-trips through CSVEncoder — header + row + CRLF
    /// pattern matches the event-log exporter.
    func test_encode_emitsHeaderAndRow() {
        let sample = StoredSample(
            id: 1,
            timestamp: Date(timeIntervalSince1970: 0),
            deviceID: nil,
            portID: PortID("/p"),
            watts: 1.0,
            mbps: nil,
            aggregation: .raw
        )
        let csv = SampleCSVExporter.encode([sample])
        XCTAssertTrue(csv.hasPrefix("timestamp_iso8601,aggregation,"))
        XCTAssertTrue(csv.contains("\r\n"))
        XCTAssertTrue(csv.hasSuffix("\r\n"))
    }
}
