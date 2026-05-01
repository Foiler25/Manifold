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
// Identifiers.swift
//
// Stable identifier types for hosts, ports, and devices. Defined per
// SPEC.md §4.1. Stability across reboots, replug events, and
// SwiftUI re-renders is the *whole point* of these types — DECISIONS.md
// D9 explains the derivation rules in detail.
//
// All three IDs encode as their bare string value (`"machine-uuid"`,
// `"IOService:/…"`, `"046d:c52b:serial"`) rather than as JSON dicts
// `{"rawValue":"…"}`. Custom single-value Codable below makes the
// wire format readable for the Phase 12 JSON snapshot exports and for
// any human reading the GRDB tables in Phase 10.

// Foundation is used only internally (String.init(format:) inside
// `DeviceID.make`). No Foundation type is part of the public API.
internal import Foundation

// MARK: - HostID

/// Stable host identifier derived from the machine's hardware UUID.
/// Stable across reboots and OS upgrades on the same physical machine.
public struct HostID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

// MARK: - PortID

/// Stable port identifier derived from the IOKit registry path
/// (`IORegistryEntryGetPath(.., kIOServicePlane, ..)`). Survives
/// replug because the registry path of the *port* persists even when
/// the connected device changes — that is what makes SwiftUI rows
/// update in place rather than animate remove-then-add.
public struct PortID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

// MARK: - DeviceID

/// Composite device identifier. Preferred form: `"vid:pid:serial"`.
/// Fallback when serial absent: `"vid:pid:registryPath"`.
///
/// Why composite (not synthesized UUIDs): plugging the same physical
/// device back in across reboots should produce the same DeviceID so
/// historical event-log queries remain coherent. VID/PID/serial gives
/// us that for free; synthesized UUIDs would need a "have I seen this
/// before?" disk lookup on the discovery hot path. Edge cases (two
/// identical no-serial devices swapped between ports look like
/// disconnect+connect) are accepted per DECISIONS.md D9.
public struct DeviceID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    /// Construct a DeviceID from the four pieces of info Phase 1's
    /// USBWalker captures. `vendorID` and `productID` are zero-padded to
    /// 4 hex digits (USB spec width); `serial` is preferred and falls
    /// back to `registryPath` when the device exposes no serial string.
    /// Lowercase hex is intentional — case-folding noise out of the
    /// wire format means equality comparisons stay simple.
    public static func make(
        vendorID: UInt16,
        productID: UInt16,
        serial: String?,
        registryPath: String
    ) -> DeviceID {
        let suffix = serial ?? registryPath
        return DeviceID(rawValue: String(format: "%04x:%04x:%@", vendorID, productID, suffix))
    }
}

// MARK: - Single-value Codable

/// Boilerplate-shared single-value Codable so all three ID types
/// encode as bare strings on the wire. Without this, the synthesised
/// Codable would produce `{"rawValue":"…"}` per ID, which clutters the
/// snapshot JSON and forces every consumer (widget, exports, GRDB
/// payloads) to thread through a wrapping dict.
extension HostID {
    public init(from decoder: any Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension PortID {
    public init(from decoder: any Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension DeviceID {
    public init(from decoder: any Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
