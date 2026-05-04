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

    var body: some Scene {
        Settings {
            TabView {
                GeneralPane(
                    onSampleRateChange: onSampleRateChange,
                    loginItemController: loginItemController
                )
                .tabItem { Label("settings.tab.general", systemImage: "gearshape") }

                NotificationsPane()
                    .tabItem { Label("settings.tab.notifications", systemImage: "bell") }

                HistoryPane(
                    databaseManager: databaseManager,
                    downsamplingJob: downsamplingJob
                )
                .tabItem { Label("settings.tab.history", systemImage: "clock") }

                UpdatesPane(updaterController: updaterController)
                    .tabItem { Label("settings.tab.updates", systemImage: "arrow.down.circle") }

                AboutPane()
                    .tabItem { Label("settings.tab.about", systemImage: "info.circle") }
            }
        }
    }
}
