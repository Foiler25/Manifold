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
// TelemetrySample.swift
//
// One sampled instant of per-port telemetry. Per SPEC.md §4.5.
//
// Both `watts` and `bitrate` are optional because some port/device
// combinations don't publish one or the other (Phase 1 already showed
// us this on the M-series boot SSD). nil here means "not read this
// tick", not "zero" — the sparkline renders a gap, not a zero floor.

public import Foundation

public struct TelemetrySample: Hashable, Sendable, Codable {

    /// Wall-clock time of the sample. Used by the Phase 5 sparkline,
    /// the Phase 10 GRDB writer, and the Phase 5 downsampling job
    /// that aggregates raw samples into 1-min and 1-hour buckets.
    public let timestamp: Date

    /// Instantaneous power draw at sample time. nil when the
    /// underlying device or port doesn't publish a power property.
    public let watts: Watts?

    /// Instantaneous link bitrate at sample time. nil when the device
    /// is idle or doesn't publish a speed property.
    public let bitrate: Bitrate?

    public init(timestamp: Date = .now, watts: Watts?, bitrate: Bitrate?) {
        self.timestamp = timestamp
        self.watts = watts
        self.bitrate = bitrate
    }
}
