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
// SampleCSVExporter.swift
//
// Per SPEC §18 Phase 11 #2. Maps `[StoredSample]` to a CSV blob.
//
// Column shape:
//   timestamp_iso8601, aggregation, device_id, port_id, watts, mbps
//
// Numbers cells display empty for nil watts/mbps (those are valid
// "not measured this tick" states per the SPEC §10.1 nullable
// columns). Aggregation column lets the user filter raw vs. 1min
// vs. 1hour rows in their spreadsheet.

import Foundation
import ManifoldKit

enum SampleCSVExporter {

    static let header: [String] = [
        "timestamp_iso8601",
        "aggregation",
        "device_id",
        "port_id",
        "watts",
        "mbps"
    ]

    static func encode(_ samples: [StoredSample]) -> String {
        CSVEncoder.encode(header: header, rows: samples.map(row(for:)))
    }

    static func encodeData(_ samples: [StoredSample]) -> Data {
        CSVEncoder.encodeData(header: header, rows: samples.map(row(for:)))
    }

    // MARK: - Per-row projection

    /// `nonisolated(unsafe)` per the same reasoning as
    /// `EventLogCSVExporter.isoFormatter` — documented thread-safe
    /// reads, no post-init mutation.
    private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func row(for sample: StoredSample) -> [String] {
        [
            isoFormatter.string(from: sample.timestamp),
            sample.aggregation.rawValue,
            sample.deviceID?.rawValue ?? "",
            sample.portID.rawValue,
            sample.watts.map { String(format: "%.4f", $0) } ?? "",
            sample.mbps.map(String.init) ?? ""
        ]
    }
}
