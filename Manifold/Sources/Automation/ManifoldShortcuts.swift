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
// ManifoldShortcuts.swift
//
// Per SPEC §11. Registers all five Phase-12 intents with the system
// `AppShortcutsProvider`, including the SPEC-listed voice phrases
// so Siri and the Shortcuts app suggest them.
//
// Phrases per SPEC §11 final paragraph:
//   - "Get connected devices on \(.applicationName)"
//   - "\(.applicationName) power draw"
//   - "\(.applicationName) active diagnostics"
//   - "Watch for device on \(.applicationName)"
//   - "Export \(.applicationName) topology"

import AppIntents

struct ManifoldShortcuts: AppShortcutsProvider {

    /// Tint applied to the App Shortcuts tile in Shortcuts.app. The
    /// system reserves a color enum; using the existing palette
    /// would require a wider AppIntents palette type (not exposed
    /// in macOS 26's shipping framework). Default tint is fine.
    static var shortcutTileColor: ShortcutTileColor { .lightBlue }

    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetConnectedDevicesIntent(),
            phrases: [
                "Get connected devices on \(.applicationName)"
            ],
            shortTitle: "intent.getConnectedDevices.shortTitle",
            systemImageName: "cable.connector"
        )
        AppShortcut(
            intent: GetPowerDrawIntent(),
            phrases: [
                "\(.applicationName) power draw"
            ],
            shortTitle: "intent.getPowerDraw.shortTitle",
            systemImageName: "bolt.fill"
        )
        AppShortcut(
            intent: GetActiveDiagnosticsIntent(),
            phrases: [
                "\(.applicationName) active diagnostics"
            ],
            shortTitle: "intent.getActiveDiagnostics.shortTitle",
            systemImageName: "exclamationmark.triangle"
        )
        AppShortcut(
            intent: WatchForDeviceConnectIntent(),
            phrases: [
                "Watch for device on \(.applicationName)"
            ],
            shortTitle: "intent.watchForDeviceConnect.shortTitle",
            systemImageName: "eye"
        )
        AppShortcut(
            intent: ExportTopologySnapshotIntent(),
            phrases: [
                "Export \(.applicationName) topology"
            ],
            shortTitle: "intent.exportTopology.shortTitle",
            systemImageName: "square.and.arrow.up"
        )
    }
}
