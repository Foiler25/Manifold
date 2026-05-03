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
// IntentDonor.swift
//
// F25 closure (Phase 12 review): donate `WatchForDeviceConnectIntent`
// with the matching device's filter parameters whenever a real
// `.attached` event fires. The system uses donations to surface
// the intent as a suggestion in Siri / Shortcuts / Spotlight when
// the user plugs the same device again — making the SPEC §18
// Phase 12 #3 "fires when matching device connects" semantics
// reachable via a Shortcuts.app Automation paired with this
// donation, without us trying to invent a custom event-trigger
// API that doesn't exist in the framework.
//
// Donation is best-effort: any framework failure logs at debug
// level + drops. The host app's user-facing behaviour does not
// depend on donations succeeding.

import Foundation
import AppIntents
import os
import ManifoldKit

@MainActor
enum IntentDonor {

    /// Donate one `WatchForDeviceConnectIntent` instance
    /// pre-filled with the connecting device's name + IDs. The
    /// system stores the donation; future Spotlight / Siri
    /// surfaces may suggest "Watch for Logitech MX Master" the
    /// next time the user plugs the same device.
    static func donateAttachedDevice(_ device: Device) {
        let intent = WatchForDeviceConnectIntent()
        intent.nameContains = device.name.isEmpty ? nil : device.name
        intent.vendorID = Int(device.vendorID)
        intent.productID = Int(device.productID)
        Task {
            do {
                try await intent.donate()
            } catch {
                Log.app.debug("WatchForDeviceConnectIntent donation failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
