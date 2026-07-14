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
/// - `AppleHPMInterface.connectionActive` lingers `true` for several seconds after
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
///
/// MagSafe is the awkward one. Normally a connected MagSafe charger exposes a
/// per-port power source (the negotiated PDO), which corroborates liveness.
/// But in rare cases macOS produces no per-port power source for a genuinely
/// connected MagSafe charger (one machine in the corpus; reporter Yee Zhang),
/// and then the port has nothing to corroborate and reads as "nothing
/// connected". MagSafe's `connectionActive` does report the connection, but it
/// also lingers `true` for seconds after unplug (issue #47), so it can't be
/// trusted on its own. The tie-breaker is `chargerAttached`: whether the Mac
/// actually has an external adapter attached right now. That clears immediately
/// on unplug, so it rules out the lingering case while still surfacing a
/// genuinely connected MagSafe charger even when no per-port source appears.
///
/// - Parameter chargerAttached: whether an external charger is attached to the
///   Mac. Used only to corroborate a MagSafe `connectionActive`. Defaults to
///   `false` so callers that can't supply it keep the prior behaviour.
public func isPortLive(
    port: AppleHPMInterface,
    powerSources: [PowerSource],
    identities: [USBPDSOP],
    matchingDevices: [USBDevice],
    chargerAttached: Bool = false
) -> Bool {
    if !matchingDevices.isEmpty { return true }
    if !identities.isEmpty { return true }

    let isMagSafe = port.portTypeDescription?.hasPrefix("MagSafe") == true
    if !isMagSafe && port.connectionActive == true { return true }

    // MagSafe reporting connected, corroborated by a charger actually attached.
    // This is what surfaces an M1/M2 MagSafe charger (no per-port power source
    // on that silicon). Gated on `connectionActive == true`, so the issue
    // #47 / #185 stale cases (a cached PDO on a disconnected port, where
    // `connectionActive` is false) are untouched. `chargerAttached` handles the
    // post-unplug lingering-true flag: once the only charger is gone the
    // adapter clears and this stops firing. (If a *second* charger is on
    // another port during the unplug, the port can read live until
    // `connectionActive` drains a few seconds later. Bounded, and no worse than
    // before, where an M1/M2 MagSafe charger never showed at all.)
    if isMagSafe && port.connectionActive == true && chargerAttached { return true }

    // Power sources alone aren't enough: the watcher's cached PDO can
    // outlive the physical connection. Only count them when the port
    // itself agrees something is connected.
    if !powerSources.isEmpty && port.connectionActive == true { return true }

    return false
}
