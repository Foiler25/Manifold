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
// SnapshotPublisher.swift
//
// Per SPEC §12. Projects the live PortGraph + diagnostics into a
// `SnapshotV1` and writes it atomically to the resolved container
// directory. `SnapshotCoordinator` debounces writes to ≤2 Hz and
// triggers WidgetKit timeline reloads.
//
// Why a stateless projection enum: the publisher is pure
// `(graph) → SnapshotV1`. Tests inject canned hosts/diagnostics
// and assert on the resulting struct without spinning up
// `WidgetCenter` or touching the disk.

import Foundation
import ManifoldKit

@MainActor
enum SnapshotPublisher {

    /// Top-N cap for the medium widget per SPEC §12.1.
    static let topDeviceCap: Int = 4

    /// Per-port sample tail length per SPEC §12.1 ("up to 30 watt
    /// samples for sparkline").
    static let recentSampleCap: Int = 30

    // MARK: - Projection

    /// Build a `SnapshotV1` from the live PortGraph + most-recent
    /// event timestamp. Pure — no disk I/O, no WidgetKit calls.
    /// `now` is injectable for tests.
    static func makeSnapshot(
        from graph: PortGraph,
        lastEventAt: Date?,
        now: Date = .now
    ) -> SnapshotV1 {
        let collected = collect(graph: graph)
        let topDevices = pickTopDevices(collected.devices, graph: graph)
        return SnapshotV1(
            schemaVersion: 1,
            writtenAt: now,
            totalPowerDraw: Watts(collected.totalDrawWatts),
            connectedDeviceCount: collected.devices.count,
            topDevicesByPower: topDevices,
            activeDiagnosticCount: graph.diagnostics.count,
            lastEventAt: lastEventAt
        )
    }

    // MARK: - Collection

    /// Walk the host trees once, collecting (Device, port watts)
    /// pairs + a running total. Used by both the snapshot
    /// projection and the sample-history join.
    private static func collect(graph: PortGraph) -> CollectedDevices {
        var pairs: [(Device, Double)] = []
        var total: Double = 0
        func walk(_ ports: [ManifoldKit.Port]) {
            for port in ports {
                if let device = port.connectedDevice {
                    let watts = port.powerDraw?.value ?? 0
                    pairs.append((device, watts))
                    total += watts
                }
                walk(port.children)
            }
        }
        for host in graph.hosts { walk(host.ports) }
        return CollectedDevices(devices: pairs, totalDrawWatts: total)
    }

    private struct CollectedDevices {
        let devices: [(Device, Double)]
        let totalDrawWatts: Double
    }

    // MARK: - Top-N selection

    /// Pick the top `topDeviceCap` devices by power draw, descending.
    /// Each entry's recent samples come from the PortGraph's
    /// telemetry-history dict via the device's currently-connected
    /// port id.
    private static func pickTopDevices(
        _ pairs: [(Device, Double)],
        graph: PortGraph
    ) -> [SnapshotV1.TopDevice] {
        let sorted = pairs.sorted { $0.1 > $1.1 }
        let topN = Array(sorted.prefix(topDeviceCap))
        return topN.map { (device, watts) in
            SnapshotV1.TopDevice(
                id: device.id,
                name: device.name,
                powerDraw: Watts(watts),
                kind: device.kind,
                recentSamples: recentSamples(for: device, graph: graph)
            )
        }
    }

    /// Pull up to `recentSampleCap` watt samples from the PortGraph's
    /// telemetry buffer for the port currently hosting `device`.
    /// Empty when the device isn't currently in the graph or no
    /// telemetry has fired yet.
    private static func recentSamples(for device: Device, graph: PortGraph) -> [Double] {
        guard let portID = portID(for: device.id, in: graph) else { return [] }
        guard let buffer = graph.history(forPortID: portID) else { return [] }
        let samples = buffer.samples
            .compactMap { $0.watts?.value }
            .suffix(recentSampleCap)
        return Array(samples)
    }

    private static func portID(for deviceID: DeviceID, in graph: PortGraph) -> PortID? {
        for host in graph.hosts {
            if let id = walk(host.ports, lookingFor: deviceID) { return id }
        }
        return nil
    }

    private static func walk(_ ports: [ManifoldKit.Port], lookingFor deviceID: DeviceID) -> PortID? {
        for port in ports {
            if port.connectedDevice?.id == deviceID { return port.id }
            if let inChild = walk(port.children, lookingFor: deviceID) {
                return inChild
            }
        }
        return nil
    }
}
