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
// SnapshotV1.swift
//
// Per SPEC §12.1. The widget snapshot wire format. Lives in
// ManifoldKit so the Manifold app target (writer) AND the
// ManifoldWidget extension (reader) share one Codable shape — the
// only sane way to keep the JSON contract in sync across two
// independently-shipped binaries.
//
// **Schema is FROZEN.** V1 stays unchanged once shipped, ever. Any
// future field-shape change adds `case v2(SnapshotV2)` to the
// `Snapshot` enum (per SPEC §12.4). Old widgets fall back to a
// "no data" entry on unknown versions.

public import Foundation

public struct SnapshotV1: Codable, Sendable, Equatable {

    /// Always 1 for this struct. Pinned by the test suite —
    /// re-encode → re-decode must produce the same value.
    public let schemaVersion: Int

    /// Wall-clock time the host app emitted the snapshot. Lets a
    /// widget render "data is N seconds old" affordances.
    public let writtenAt: Date

    /// Sum of every connected device's `Port.powerDraw`. Renders
    /// in the lock-screen circular widget + the desktop small.
    public let totalPowerDraw: Watts

    /// Device count for the desktop small + lock-screen alternate.
    public let connectedDeviceCount: Int

    /// Top-N devices by power draw, descending. Capped at 4 for
    /// the medium widget per SPEC §12.1; writer enforces the cap.
    public let topDevicesByPower: [TopDevice]

    /// Number of `Diagnostic`s currently active. Drives the
    /// medium widget's amber-dot indicator.
    public let activeDiagnosticCount: Int

    /// Most-recent `.attached` / `.detached` event timestamp.
    /// nil when the persistence layer is silently disabled or no
    /// events have fired yet on a fresh launch.
    public let lastEventAt: Date?

    public init(
        schemaVersion: Int = 1,
        writtenAt: Date,
        totalPowerDraw: Watts,
        connectedDeviceCount: Int,
        topDevicesByPower: [TopDevice],
        activeDiagnosticCount: Int,
        lastEventAt: Date?
    ) {
        self.schemaVersion = schemaVersion
        self.writtenAt = writtenAt
        self.totalPowerDraw = totalPowerDraw
        self.connectedDeviceCount = connectedDeviceCount
        self.topDevicesByPower = topDevicesByPower
        self.activeDiagnosticCount = activeDiagnosticCount
        self.lastEventAt = lastEventAt
    }

    // MARK: - TopDevice

    /// One entry in the medium widget's top-N list. Includes a
    /// short watt-sample tail so the medium-widget sparkline can
    /// render without a second snapshot read.
    public struct TopDevice: Codable, Sendable, Identifiable, Equatable {

        public let id: DeviceID
        public let name: String
        public let powerDraw: Watts
        public let kind: DeviceKind

        /// Up to 30 watt samples for the sparkline. Older samples
        /// at index 0; newest at the end. Empty when no telemetry
        /// has fired yet.
        public let recentSamples: [Double]

        public init(
            id: DeviceID,
            name: String,
            powerDraw: Watts,
            kind: DeviceKind,
            recentSamples: [Double]
        ) {
            self.id = id
            self.name = name
            self.powerDraw = powerDraw
            self.kind = kind
            self.recentSamples = recentSamples
        }
    }
}
