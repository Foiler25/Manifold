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
// PortEvent.swift
//
// Single union type over every event the discovery + events layers can
// emit. Per SPEC.md §4.5.
//
// One stream, one consumer entry point: `PortGraph.apply(_ event:)`
// switches on this enum and mutates the model. This is the boundary
// DECISIONS.md D3 refers to ("AsyncStream over Combine"); having one
// type means the @MainActor consumer's for-await loop is a single
// while-let, not three.

// No Foundation types referenced — every associated value is a
// ManifoldKit type (Device, PortID, DeviceID, TelemetrySample,
// Diagnostic). Codable, Hashable, Sendable all live in the Swift
// standard library.

public enum PortEvent: Sendable, Hashable, Codable {

    /// A new device was attached to the named port. Carries the full
    /// `Device` value because the events layer enriches the IOKit
    /// callback before publishing — consumers don't need to round-trip
    /// to the IORegistry to learn what plugged in.
    case attached(Device, at: PortID)

    /// A device was detached. Carries the device's last-known ID so
    /// `PortGraph.apply` can locate the slot to clear without holding
    /// the prior `Device` value.
    case detached(deviceID: DeviceID, from: PortID)

    /// One sample of telemetry for the named port. Phase 5 emits these
    /// at 0.5–5 Hz; the consumer appends to the per-port ring buffer.
    case telemetry(PortID, TelemetrySample)

    /// A diagnostic engine rule fired (Phase 8+).
    case diagnostic(Diagnostic)

    /// Force a full re-walk of the IORegistry. Emitted on settings
    /// changes that affect the discovery filter, on user "refresh"
    /// requests, and as the first event of an EventService session.
    case fullRefresh
}
