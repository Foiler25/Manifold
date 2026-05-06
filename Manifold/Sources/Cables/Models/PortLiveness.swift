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

/// Decide whether a port is physically live based on the union of IOKit
/// watcher state (devices, power sources, PD identities) and the port-level
/// `ConnectionActive` flag.
///
/// Why this helper exists:
///
/// - `USBCPort.connectionActive` lingers `true` for several seconds after
///   unplug on MagSafe (`AppleHPMInterfaceType11`), so we can't trust it
///   alone there.
/// - The power source watcher caches the last negotiated PDO, so a port
///   with nothing plugged in can still expose a USB-PD source long after
///   the cable was removed (issue #47).
///
/// So we treat each signal differently. Devices and PD identities are
/// strong: their watchers terminate on real IOKit notifications, no
/// caching. The port-level `connectionActive` flag is trusted on
/// non-MagSafe. Power sources need corroboration before they count.
public func isPortLive(
    port: USBCPort,
    powerSources: [PowerSource],
    identities: [PDIdentity],
    matchingDevices: [USBDevice]
) -> Bool {
    if !matchingDevices.isEmpty { return true }
    if !identities.isEmpty { return true }

    let isMagSafe = port.portTypeDescription?.hasPrefix("MagSafe") == true
    if !isMagSafe && port.connectionActive == true { return true }

    // Power sources alone aren't enough: the watcher's cached PDO can
    // outlive the physical connection. Only count them when the port
    // itself agrees something is connected.
    if !powerSources.isEmpty && port.connectionActive == true { return true }

    return false
}
