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
// Portions of this file derive from WhatCable
// (https://github.com/darrylmorley/whatcable) by Darryl Morley,
// originally distributed under the MIT licence. See
// `Manifold/Sources/Cables/ATTRIBUTION.md` for the full original
// copyright + permission notice.
//
// ─────────────────────────────────────────────────────────────────────
public import Foundation

/// One PDO (Power Data Object) advertised by the connected source.
public struct PowerOption: Hashable {
    public let voltageMV: Int
    public let maxCurrentMA: Int
    public let maxPowerMW: Int

    public init(voltageMV: Int, maxCurrentMA: Int, maxPowerMW: Int) {
        self.voltageMV = voltageMV
        self.maxCurrentMA = maxCurrentMA
        self.maxPowerMW = maxPowerMW
    }

    public var voltsLabel: String {
        String(format: "%.0fV", Double(voltageMV) / 1000)
    }
    public var ampsLabel: String {
        String(format: "%.2fA", Double(maxCurrentMA) / 1000)
    }
    public var wattsLabel: String {
        String(format: "%.0fW", Double(maxPowerMW) / 1000)
    }
}

/// A power source advertised on a USB-C / MagSafe port (parsed from
/// `IOPortFeaturePowerSource`). One port may have multiple sources
/// (e.g. "USB-PD" + "Brick ID").
public struct PowerSource: Identifiable, Hashable {
    public let id: UInt64
    public let name: String                // "USB-PD", "Brick ID"
    public let parentPortType: Int         // 0x2 = USB-C, 0x11 = MagSafe 3
    public let parentPortNumber: Int
    public let options: [PowerOption]
    public let winning: PowerOption?

    public init(
        id: UInt64,
        name: String,
        parentPortType: Int,
        parentPortNumber: Int,
        options: [PowerOption],
        winning: PowerOption?
    ) {
        self.id = id
        self.name = name
        self.parentPortType = parentPortType
        self.parentPortNumber = parentPortNumber
        self.options = options
        self.winning = winning
    }

    public var maxPowerMW: Int {
        if let max = options.map(\.maxPowerMW).max(), max > 0 {
            return max
        }
        return winning?.maxPowerMW ?? 0
    }

    /// Match key joining a power source to its port.
    public var portKey: String { "\(parentPortType)/\(parentPortNumber)" }
}

extension PowerSource {
    public static func preferredChargingSource(in sources: [PowerSource]) -> PowerSource? {
        sources.first { $0.name == "USB-PD" }
            ?? sources.first { $0.name == "Brick ID" }
    }
}

extension USBCPort {
    public var portKey: String? {
        guard let n = portNumber else { return nil }
        let rawType: Int
        if portTypeDescription?.hasPrefix("MagSafe") == true {
            rawType = 0x11
        } else {
            rawType = rawProperties["PortType"].flatMap { Int($0) } ?? 0x2
        }
        return "\(rawType)/\(n)"
    }
}
