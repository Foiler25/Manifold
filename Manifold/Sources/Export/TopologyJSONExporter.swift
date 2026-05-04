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
// TopologyJSONExporter.swift
//
// Per SPEC §18 Phase 11 #3. Top-level JSON object always carries
// `schemaVersion: 1` so future export-format changes can be detected
// by readers without inspecting the object shape. Phase 12+ may add
// versions; V1 stays frozen as the historical baseline.
//
// The full snapshot reuses the existing `[Host]` Codable shape
// (already proven by ManifoldKit's `SnapshotRoundTripTests`). Scope
// filtering happens at the `[Host]` level before encoding — single-
// host scope returns one host; single-device scope returns the host
// trimmed to just the matching device's port subtree.

import Foundation
import ManifoldKit

enum TopologyJSONExporter {

    // MARK: - Scope

    /// Three scope options the ExportSheet exposes per SPEC §18
    /// Phase 11 #4.
    enum Scope: Sendable, Equatable {
        case fullTopology
        case host(HostID)
        case device(DeviceID)
    }

    // MARK: - Encode entry points

    /// Encode `hosts` filtered by `scope` as pretty-printed JSON.
    /// Returns nil only when the scope's target isn't found in the
    /// supplied hosts (single-host with an unknown HostID, etc.) —
    /// the caller renders an "empty selection" alert in that case.
    static func encode(hosts: [ManifoldKit.Host], scope: Scope) -> Data? {
        guard let snapshot = makeSnapshot(hosts: hosts, scope: scope) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(snapshot)
    }

    // MARK: - Snapshot construction

    /// Strongly-typed top-level JSON object. `schemaVersion = 1`
    /// always. `exportedAt` carries the wall-clock time of the
    /// export so the downstream reader can correlate against
    /// other artifacts (notification logs, screenshot timestamps,
    /// etc.).
    struct Snapshot: Codable, Equatable {
        let schemaVersion: Int
        let exportedAt: Date
        let scope: String
        let hosts: [ManifoldKit.Host]
    }

    static func makeSnapshot(hosts: [ManifoldKit.Host], scope: Scope, now: Date = .now) -> Snapshot? {
        switch scope {
        case .fullTopology:
            return Snapshot(
                schemaVersion: 1,
                exportedAt: now,
                scope: "full",
                hosts: hosts
            )

        case .host(let hostID):
            guard let host = hosts.first(where: { $0.id == hostID }) else { return nil }
            return Snapshot(
                schemaVersion: 1,
                exportedAt: now,
                scope: "host:\(hostID.rawValue)",
                hosts: [host]
            )

        case .device(let deviceID):
            // Trim every host's port tree to the subtree containing
            // the target device. A host that doesn't contain the
            // device is dropped entirely. Hubs that contain the
            // device keep their structural path so the user can see
            // where the device sits.
            let trimmed = hosts.compactMap { host -> ManifoldKit.Host? in
                let trimmedPorts = trimmedPorts(host.ports, containing: deviceID)
                guard !trimmedPorts.isEmpty else { return nil }
                return ManifoldKit.Host(
                    id: host.id,
                    name: host.name,
                    model: host.model,
                    ports: trimmedPorts,
                    physicalPorts: host.physicalPorts
                )
            }
            guard !trimmed.isEmpty else { return nil }
            return Snapshot(
                schemaVersion: 1,
                exportedAt: now,
                scope: "device:\(deviceID.rawValue)",
                hosts: trimmed
            )
        }
    }

    /// Return ports whose subtree contains the target device. A leaf
    /// port matches when its `connectedDevice` is the target; a
    /// hub-port matches when at least one descendant matches (and
    /// is rebuilt with only the matching descendants in `children`).
    private static func trimmedPorts(_ ports: [ManifoldKit.Port], containing deviceID: DeviceID) -> [ManifoldKit.Port] {
        ports.compactMap { port in
            let isMatch = port.connectedDevice?.id == deviceID
            let trimmedKids = trimmedPorts(port.children, containing: deviceID)
            guard isMatch || !trimmedKids.isEmpty else { return nil }
            return ManifoldKit.Port(
                id: port.id,
                position: port.position,
                kind: port.kind,
                parentID: port.parentID,
                connectedDevice: port.connectedDevice,
                negotiated: port.negotiated,
                powerDraw: port.powerDraw,
                availablePower: port.availablePower,
                children: trimmedKids
            )
        }
    }
}
