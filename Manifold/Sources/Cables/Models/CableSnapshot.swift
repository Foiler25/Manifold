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

/// External power adapter info. Populated by the Darwin backend from IOKit.
public struct CableAdapterInfo: Hashable {
    public let watts: Int?
    public let isCharging: Bool?
    public let source: String?  // "AC" / "Battery" / nil

    public init(watts: Int?, isCharging: Bool?, source: String?) {
        self.watts = watts
        self.isCharging = isCharging
        self.source = source
    }
}

/// One unified view of cable / port / power state at a point in time.
/// Backends produce these; CLI and GUI consume them.
// TODO: Sendable — requires USBCPort, PowerSource, PDIdentity, USBDevice to conform first
public struct CableSnapshot: Equatable {
    public let ports: [USBCPort]
    public let powerSources: [PowerSource]
    public let identities: [PDIdentity]
    public let usbDevices: [USBDevice]
    public let adapter: CableAdapterInfo?
    /// Top-level array of every Thunderbolt switch the host can see. Empty
    /// on machines without a Thunderbolt controller, or when IOKit returns
    /// nothing (the JSON shape adds the key but with an empty array, so
    /// downstream consumers can rely on the field always being present).
    public let thunderboltSwitches: [ThunderboltSwitch]

    public init(
        ports: [USBCPort],
        powerSources: [PowerSource],
        identities: [PDIdentity],
        usbDevices: [USBDevice],
        adapter: CableAdapterInfo?,
        thunderboltSwitches: [ThunderboltSwitch] = []
    ) {
        self.ports = ports
        self.powerSources = powerSources
        self.identities = identities
        self.usbDevices = usbDevices
        self.adapter = adapter
        self.thunderboltSwitches = thunderboltSwitches
    }
}
