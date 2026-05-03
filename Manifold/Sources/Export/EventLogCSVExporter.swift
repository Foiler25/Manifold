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
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// ─────────────────────────────────────────────────────────────────────
// EventLogCSVExporter.swift
//
// Per SPEC §18 Phase 11 #1. Maps `[StoredEvent]` to a CSV blob the
// user can open in Excel or Numbers.
//
// Column shape (header + per-row):
//   timestamp_iso8601, kind, device_id, port_id,
//   device_name, link_protocol, watts,
//   diagnostic_severity, diagnostic_rule, diagnostic_title, diagnostic_detail
//
// One column per useful payload field rather than dumping
// `payload_json` raw — spreadsheets are happier with flat columns
// for filtering/sorting. Cells that don't apply to the row's kind
// stay empty.

import Foundation
import ManifoldKit

enum EventLogCSVExporter {

    /// Header row used by every export. Stable column order is part
    /// of the schema contract — downstream Excel/Numbers macros
    /// keying on column position must keep working across app
    /// versions.
    static let header: [String] = [
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

    /// Encode the events as a CSV `String` (UTF-8 BOM not included
    /// — `encodeData` adds it). Useful for tests + the JSON-export
    /// path that wants the same projection without the BOM.
    static func encode(_ events: [StoredEvent]) -> String {
        CSVEncoder.encode(header: header, rows: events.map(row(for:)))
    }

    /// Encode + UTF-8 BOM + UTF-8 bytes ready for disk write.
    static func encodeData(_ events: [StoredEvent]) -> Data {
        CSVEncoder.encodeData(header: header, rows: events.map(row(for:)))
    }

    // MARK: - Per-row projection

    /// `nonisolated(unsafe)` because `ISO8601DateFormatter` is
    /// documented thread-safe for `string(from:)` calls but isn't
    /// marked `Sendable` in the stdlib. Static-let initialization
    /// happens once at first access; we never mutate `formatOptions`
    /// after construction.
    private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        // Include fractional seconds so two events in the same
        // second still sort deterministically by timestamp.
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Map one StoredEvent to its column array. Empty strings for
    /// fields that don't apply to the row's `kind`.
    static func row(for event: StoredEvent) -> [String] {
        var fields: [String] = Array(repeating: "", count: header.count)
        fields[0] = isoFormatter.string(from: event.timestamp)
        fields[1] = event.kind.rawValue
        fields[2] = event.deviceID?.rawValue ?? ""
        fields[3] = event.portID.rawValue

        switch event.payload {
        case .attached(let deviceName, let linkProtocol, let watts):
            fields[4] = deviceName
            fields[5] = linkProtocol ?? ""
            fields[6] = watts.map { String(format: "%.4f", $0) } ?? ""
        case .detached(let lastKnown):
            fields[4] = lastKnown ?? ""
        case .diagnostic(let severity, let ruleIdentifier, let title, let detail):
            fields[7] = severity
            fields[8] = ruleIdentifier
            fields[9] = title
            fields[10] = detail
        }
        return fields
    }
}
