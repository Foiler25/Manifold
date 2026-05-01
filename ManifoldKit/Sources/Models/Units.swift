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
// Units.swift
//
// Typed wrappers for the two physical quantities Manifold reads. Why
// wrappers and not bare `Double`/`UInt64`: the USB spec publishes
// power as integer milliamps at multiple voltages and bitrate as
// hardware-encoded enum codes; mixing those at call sites *will*
// produce silent unit-confusion bugs. The wrappers carry the unit in
// the type and centralise the formatting in one place.

// Foundation is used only internally (String.init(format:)) — no
// Foundation type appears in the public API surface here, so an
// `internal import` keeps the public interface minimal.
internal import Foundation

// MARK: - Watts

/// Power draw in watts. Single-value Codable so the wire format is a
/// bare number rather than `{"value": 1.2}` — keeps Snapshot JSON and
/// GRDB payloads compact.
public struct Watts: Hashable, Sendable, Codable, Comparable {

    public let value: Double

    public init(_ value: Double) { self.value = value }

    public static func < (lhs: Watts, rhs: Watts) -> Bool { lhs.value < rhs.value }
    public static let zero = Watts(0)

    /// Construct from USB-spec milliamps at a given voltage. Most USB
    /// device descriptors publish power as `bMaxPower` units (2 mA in
    /// USB 2, 8 mA in USB 3) at the bus voltage (5 V for USB 2/3,
    /// negotiated for USB-C PD). Callers normalise to mA before this
    /// helper, then provide the bus voltage to convert to watts.
    public static func fromMilliamps(_ mA: Int, atVolts volts: Double) -> Watts {
        Watts(Double(mA) * volts / 1000.0)
    }

    /// Human-friendly "1.2 W" or "450 mW". Uses a single decimal place
    /// for whole-watt values to keep typography consistent in the
    /// popover (no jitter as a sample bounces between 1.04 W and 1.1 W).
    public var formatted: String {
        if value < 1.0 { return String(format: "%.0f mW", value * 1000) }
        return String(format: "%.1f W", value)
    }

    public init(from decoder: any Decoder) throws {
        self.value = try decoder.singleValueContainer().decode(Double.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

// MARK: - Bitrate

/// Link bitrate in bits per second. `UInt64` covers up to ~18 Eb/s —
/// safely above any present or foreseeable USB/Thunderbolt link.
/// Single-value Codable for the same reason as `Watts`.
public struct Bitrate: Hashable, Sendable, Codable, Comparable {

    public let bitsPerSecond: UInt64

    public init(bitsPerSecond: UInt64) { self.bitsPerSecond = bitsPerSecond }

    public static func < (lhs: Bitrate, rhs: Bitrate) -> Bool {
        lhs.bitsPerSecond < rhs.bitsPerSecond
    }

    /// Human-friendly "10 Gbps", "480 Mbps". Picks the SI unit by
    /// magnitude so a 5 Mbps device doesn't show as "0 Gbps". The
    /// kbps cutoff (< 1 Mbps) covers USB 1.1 low-speed (1.5 Mbps);
    /// the Mbps cutoff covers USB 2.0 (480 Mbps); above that we're
    /// always in Gbps territory.
    public var formatted: String {
        switch bitsPerSecond {
        case 0..<1_000_000:
            return "\(bitsPerSecond / 1_000) kbps"
        case 1_000_000..<1_000_000_000:
            return "\(bitsPerSecond / 1_000_000) Mbps"
        default:
            let g = Double(bitsPerSecond) / 1_000_000_000.0
            return String(format: "%.0f Gbps", g)
        }
    }

    public init(from decoder: any Decoder) throws {
        self.bitsPerSecond = try decoder.singleValueContainer().decode(UInt64.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bitsPerSecond)
    }
}
