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
// ExportTopologySnapshotIntent.swift
//
// Per SPEC §11.2 + §18 Phase 12 #4. Reuses Phase 11's
// `TopologyJSONExporter` so the JSON shape (top-level
// `schemaVersion: 1`) is consistent across menu-driven exports
// and Shortcut-driven exports. The intent's filename parameter
// drives the on-disk name; the `IntentFile` returned carries the
// content so a downstream Shortcut step can pipe it into another
// app (Mail, Files, Messages…).

import AppIntents
import Foundation
import UniformTypeIdentifiers

struct ExportTopologySnapshotIntent: AppIntent {

    static let title: LocalizedStringResource = "intent.exportTopology.title"
    static let description = IntentDescription(
        "intent.exportTopology.description"
    )

    /// Optional override for the auto-generated filename. Default
    /// includes the YYYY-MM-DD stamp so consecutive runs land in
    /// distinct files.
    @Parameter(title: "intent.parameter.filename", default: "manifold-topology.json")
    var filename: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let source = IntentEnvironment.dataSource else {
            throw ExportTopologyError.dataSourceUnavailable
        }
        guard let data = TopologyJSONExporter.encode(hosts: source.hosts, scope: .fullTopology) else {
            throw ExportTopologyError.encodeFailed
        }
        let file = IntentFile(
            data: data,
            filename: filename.isEmpty ? "manifold-topology.json" : filename,
            type: .json
        )
        return .result(value: file)
    }
}

/// Localized errors surface in the Shortcuts.app failure UI. Both
/// cases are rare in practice (cold-launch IntentEnvironment race;
/// JSONEncoder failure on a non-encodable type).
enum ExportTopologyError: LocalizedError {
    case dataSourceUnavailable
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .dataSourceUnavailable:
            return NSLocalizedString("intent.exportTopology.error.dataSourceUnavailable", comment: "")
        case .encodeFailed:
            return NSLocalizedString("intent.exportTopology.error.encodeFailed", comment: "")
        }
    }
}
