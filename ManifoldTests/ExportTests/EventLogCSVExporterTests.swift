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
// EventLogCSVExporterTests.swift
//
// Pin per-payload column projection. The Phase-11 SPEC contract is
// "opens cleanly in Excel and Numbers" — we can't run those headlessly,
// but we can pin the column shape + per-row values so a future
// payload-shape change surfaces here.

import XCTest
@testable import Manifold
import ManifoldKit

final class EventLogCSVExporterTests: XCTestCase {

    /// Header row matches the documented column shape exactly. If
    /// this changes, downstream Excel/Numbers macros break.
    func test_header_matchesDocumentedShape() {
        XCTAssertEqual(
            EventLogCSVExporter.header,
            [
                "timestamp_iso8601",
                "kind",
                "device_id",
                "port_id",
                "device_name",
                "link_protocol",
                "watts",
                "diagnostic_severity",
                "diagnostic_rule",
                "diagnostic_title",
                "diagnostic_detail"
            ]
        )
    }

    /// `.attached` row populates device_name + link_protocol + watts;
    /// diagnostic columns stay empty.
    func test_row_attached_populatesDeviceColumns() {
        let event = StoredEvent(
            id: 1,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .attached,
            deviceID: DeviceID("VID:PID:SERIAL"),
            portID: PortID("/host/port-1"),
            payload: .attached(deviceName: "Logitech MX", linkProtocol: "USB 3.0", watts: 0.45),
            payloadJSON: "{}"
        )
        let row = EventLogCSVExporter.row(for: event)
        XCTAssertEqual(row[1], "attached")
        XCTAssertEqual(row[2], "VID:PID:SERIAL")
        XCTAssertEqual(row[3], "/host/port-1")
        XCTAssertEqual(row[4], "Logitech MX")
        XCTAssertEqual(row[5], "USB 3.0")
        XCTAssertEqual(row[6], "0.4500")
        // Diagnostic columns stay empty for non-diagnostic rows.
        for index in 7...10 { XCTAssertEqual(row[index], "") }
    }

    /// `.detached` row populates the last-known device name only.
    /// Link/watts columns are empty (we don't have port state at
    /// detach time).
    func test_row_detached_populatesLastKnownNameOnly() {
        let event = StoredEvent(
            id: 2,
            timestamp: Date(timeIntervalSince1970: 1_700_000_001),
            kind: .detached,
            deviceID: DeviceID("VID:PID:SERIAL"),
            portID: PortID("/host/port-1"),
            payload: .detached(lastKnownDeviceName: "Logitech MX"),
            payloadJSON: "{}"
        )
        let row = EventLogCSVExporter.row(for: event)
        XCTAssertEqual(row[1], "detached")
        XCTAssertEqual(row[4], "Logitech MX")
        // link_protocol + watts not applicable to detach.
        XCTAssertEqual(row[5], "")
        XCTAssertEqual(row[6], "")
    }

    /// `.diagnostic` row populates the four diagnostic columns;
    /// device_name + link/watts stay empty (the diagnostic carries
    /// no device context).
    func test_row_diagnostic_populatesDiagnosticColumns() {
        let event = StoredEvent(
            id: 3,
            timestamp: Date(timeIntervalSince1970: 1_700_000_002),
            kind: .diagnostic,
            deviceID: nil,
            portID: PortID("/host/port-2"),
            payload: .diagnostic(
                severity: "warning",
                ruleIdentifier: "running-at-usb-2",
                title: "Running @ USB 2.0",
                detail: "Device supports USB 3.0 but is on a USB 2.0 link."
            ),
            payloadJSON: "{}"
        )
        let row = EventLogCSVExporter.row(for: event)
        XCTAssertEqual(row[1], "diagnostic")
        XCTAssertEqual(row[2], "")
        XCTAssertEqual(row[7], "warning")
        XCTAssertEqual(row[8], "running-at-usb-2")
        XCTAssertEqual(row[9], "Running @ USB 2.0")
        XCTAssertEqual(row[10], "Device supports USB 3.0 but is on a USB 2.0 link.")
    }

    /// `encode` includes header + each row, all CRLF-terminated.
    /// Pins the integration with `CSVEncoder.encode`.
    func test_encode_includesHeaderAndRows_eachLineCRLFTerminated() {
        let event = StoredEvent(
            id: 1,
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .attached,
            deviceID: DeviceID("a"),
            portID: PortID("p"),
            payload: .attached(deviceName: "x", linkProtocol: nil, watts: nil),
            payloadJSON: "{}"
        )
        let csv = EventLogCSVExporter.encode([event])
        let lines = csv.components(separatedBy: "\r\n")
        // Expect: header + 1 row + trailing empty (from the final
        // CRLF after the row).
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("timestamp_iso8601,"))
        XCTAssertTrue(lines[1].contains("attached"))
        XCTAssertEqual(lines[2], "")
    }
}
