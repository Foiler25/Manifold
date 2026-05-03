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
// LoginItemController.swift
//
// Phase 14 facade over `SMAppService.mainApp.{register,unregister}`
// per SPEC §18 Phase 14 #2 + #3. The protocol surface lets tests
// swap in a stub instead of hitting the real
// ServiceManagement framework — the OS register call mutates the
// user's login items list and produces a real side effect that
// shouldn't fire in unit tests.
//
// Production wiring:
//   - GeneralPane's @AppStorage(SettingsKeys.launchAtLogin) drives
//     the toggle's `isOn`.
//   - On `.onChange`, the pane calls `controller.apply(newValue)`.
//   - LiveLoginItemController calls SMAppService.mainApp.register()
//     when on, .unregister() when off; failures log + revert the
//     UserDefaults flag so the UI reflects the actual OS state.

import Foundation
import ServiceManagement
import os

/// Test-friendly facade over SMAppService. `Sendable` so it can
/// be captured cleanly across actor boundaries; methods are sync
/// because SMAppService's calls are sync.
protocol LoginItemController: Sendable {
    /// Apply the desired state. Returns true on success, false on
    /// any registration error (caller reverts the UI flag in that
    /// case so the toggle reflects the actual OS state).
    func apply(_ enabled: Bool) -> Bool

    /// Inspect the current state. Used at app launch to reconcile
    /// the @AppStorage flag with whatever the OS recorded — if
    /// the user toggled login items via System Settings while
    /// Manifold wasn't running, the UI should reflect that.
    var isCurrentlyEnabled: Bool { get }
}

// MARK: - LiveLoginItemController

/// Production impl. Wraps `SMAppService.mainApp` calls + logs
/// errors. The OS-side state survives reboots; the UserDefaults
/// flag mirrors it for SwiftUI binding convenience.
struct LiveLoginItemController: LoginItemController {

    func apply(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            Log.app.error("SMAppService \(enabled ? "register" : "unregister", privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    var isCurrentlyEnabled: Bool {
        // SMAppService reports `.enabled` when the login item is
        // registered + active. `.requiresApproval` (user denied)
        // and `.notFound` both render as "off" for the UI.
        SMAppService.mainApp.status == .enabled
    }
}
