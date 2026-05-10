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
// SettingsScene.swift
//
// Phase 14 root for the SwiftUI Settings scene. Per SPEC §13 the
// scene is a `TabView` with five tabs (General / Notifications /
// History / Updates / About). Each tab body is its own pane file
// already built in earlier phases or this one.
//
// Services are passed in by `ManifoldApp` so the panes can hand
// new values to AppDelegate-owned services (TelemetrySampler for
// the sample rate, DownsamplingJob for the retention sliders,
// DatabaseManager for the compact button) without import-cycling.

import SwiftUI

struct SettingsScene: Scene {

    /// Pushed into the General pane: invoked whenever the rate
    /// slider's @AppStorage changes. AppDelegate captures the
    /// closure with a weak reference to TelemetrySampler.
    let onSampleRateChange: ((Double) -> Void)?

    /// Login-item facade — production wires `LiveLoginItemController`;
    /// the placeholder fallback is nil (preview builds + tests).
    let loginItemController: (any LoginItemController)?

    /// History-pane services. Both nil when DatabaseManager init
    /// failed at app launch (Phase 10 silent-disable path); the
    /// pane shows a degraded banner in that case.
    let databaseManager: DatabaseManager?
    let downsamplingJob: DownsamplingJob?

    /// Phase 16 Sparkle wrapper. Pushed in by ManifoldApp from
    /// AppDelegate's lazy controller.
    let updaterController: UpdaterController?

    /// Phase 19 — live `PortGraph` so MenuBarPane can hide its
    /// battery-alert sections on desktop Macs (where `graph.battery
    /// == nil` at app start). Bound, not value-passed, so the pane
    /// re-renders if the battery probe later finds hardware (rare —
    /// the probe is one-shot at app start).
    let graph: PortGraph

    /// Phase 19 — shared alert preferences instance. nil on desktop
    /// Macs (the AppDelegate didn't construct the alert stack); the
    /// MenuBarPane hides its battery-alert sections in that case.
    let batteryAlertPreferences: BatteryAlertPreferences?

    /// Persisted selection bound to `TabView` so deep-link callers
    /// (e.g. the battery popover's gear button writing `"menubar"`)
    /// can land the user on a specific pane on next open. Tagged
    /// with `SettingsTabID` raw values so the storage value is
    /// programmatic, not localized copy.
    @AppStorage(SettingsKeys.selectedSettingsPaneId)
    private var selectedPaneId: String = SettingsTabID.general.rawValue

    var body: some Scene {
        Settings {
            TabView(selection: $selectedPaneId) {
                GeneralPane(
                    onSampleRateChange: onSampleRateChange,
                    loginItemController: loginItemController
                )
                .tabItem { Label("settings.tab.general", systemImage: "gearshape") }
                .tag(SettingsTabID.general.rawValue)

                NotificationsPane()
                    .tabItem { Label("settings.tab.notifications", systemImage: "bell") }
                    .tag(SettingsTabID.notifications.rawValue)

                HistoryPane(
                    databaseManager: databaseManager,
                    downsamplingJob: downsamplingJob
                )
                .tabItem { Label("settings.tab.history", systemImage: "clock") }
                .tag(SettingsTabID.history.rawValue)

                MenuBarPane(
                    graph: graph,
                    batteryAlertPreferences: batteryAlertPreferences
                )
                .tabItem { Label("settings.tab.menubar", systemImage: "menubar.rectangle") }
                .tag(SettingsTabID.menubar.rawValue)

                UpdatesPane(updaterController: updaterController)
                    .tabItem { Label("settings.tab.updates", systemImage: "arrow.down.circle") }
                    .tag(SettingsTabID.updates.rawValue)

                AboutPane()
                    .tabItem { Label("settings.tab.about", systemImage: "info.circle") }
                    .tag(SettingsTabID.about.rawValue)
            }
        }
    }
}
