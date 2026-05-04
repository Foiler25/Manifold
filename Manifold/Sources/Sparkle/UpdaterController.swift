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
// UpdaterController.swift
//
// Per SPEC §15. Wraps `SPUStandardUpdaterController` from Sparkle so
// the rest of the app can call `checkForUpdates()` without touching
// the Sparkle types directly. The wrapper is `@MainActor` because
// SPUStandardUpdaterController must be constructed on the main
// thread per Sparkle's documentation.
//
// Single shared instance lives on AppDelegate; the Updates pane
// invokes the wrapper's `checkForUpdates()` action and stamps the
// last-check timestamp into the SettingsKeys.lastUpdateCheckISO
// AppStorage value the same instant.
//
// Sparkle reads the appcast URL + public EdDSA key from `Info.plist`
// (`SUFeedURL` + `SUPublicEDKey` — added in Phase 16). The release
// pipeline (`build-dmg.sh`) overrides these on every DMG build so
// a fork's published binary points at the fork's appcast.

import Foundation
import Sparkle
import os

@MainActor
final class UpdaterController {

    /// Sparkle's standard controller. `startingUpdater: true` means
    /// the framework boots its background scheduling on init —
    /// Sparkle then performs its periodic checks per the user's
    /// system-wide settings (Sparkle's `SUEnableAutomaticChecks`
    /// defaults to true on first run; the user can flip via the
    /// system-provided update-frequency UI).
    private let standard: SPUStandardUpdaterController

    init() {
        // `updaterDelegate: nil` + `userDriverDelegate: nil` uses
        // Sparkle's default behavior: the framework presents its
        // own UI for "Update available" / "Download progress" /
        // "Ready to install" via SPUStandardUserDriver. Phase 16+
        // can ship a custom delegate if Brandon wants the update
        // prompt themed to match Manifold's palette.
        self.standard = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// User-driven "Check for updates now" action. UpdatesPane
    /// invokes this from the menu button + stamps the timestamp.
    /// Sparkle handles the network fetch, signature verification,
    /// download, and install prompt internally.
    func checkForUpdates() {
        Log.app.notice("UpdaterController: user requested check for updates")
        standard.checkForUpdates(nil)
    }

    /// Toggle automatic background checks. Defaults to true via
    /// Sparkle's own preferences; exposed here so the UpdatesPane
    /// can offer a "Check automatically" toggle in the future
    /// (not a Phase 16 acceptance bullet, but the wrapper covers
    /// it for cheap).
    var automaticallyChecksForUpdates: Bool {
        get { standard.updater.automaticallyChecksForUpdates }
        set { standard.updater.automaticallyChecksForUpdates = newValue }
    }
}
