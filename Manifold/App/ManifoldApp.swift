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
// ManifoldApp.swift
//
// SwiftUI `App` entry point. Hosts two scenes:
//   • `WindowGroup` — Phase 6's `MainWindow` (NavigationSplitView,
//     three-pane host/topology/inspector).
//   • `SettingsScene` — Phase 14 TabView with five panes
//     (General / Notifications / History / Updates / About).
//
// The menu bar `NSStatusItem` is owned by `AppDelegate`, attached
// here via `@NSApplicationDelegateAdaptor`. AppDelegate exposes its
// `PortGraph` and the lifecycle bridge so the WindowGroup body can
// reach them without touching AppKit globals directly.

import SwiftUI

@main
struct ManifoldApp: App {

    /// Bridges the SwiftUI app lifecycle to the AppKit `NSStatusItem`.
    /// The adaptor instantiates `AppDelegate` once per app lifetime
    /// and keeps it alive for the duration of the process.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Phase 14 theme picker. SwiftUI re-applies
    /// `.preferredColorScheme(_:)` on the WindowGroup body the
    /// moment this @AppStorage value changes, so a flip in the
    /// General pane takes effect without a relaunch.
    @AppStorage(SettingsKeys.themePreference)
    private var themeRaw: String = ThemePreference.default.rawValue

    var body: some Scene {
        WindowGroup {
            MainWindow(
                graph: appDelegate.publishedPortGraph,
                eventRepository: appDelegate.publishedEventRepository,
                sampleRepository: appDelegate.publishedSampleRepository,
                cableEngine: appDelegate.publishedCableEngine,
                powerTelemetryEngine: appDelegate.publishedPowerTelemetryEngine,
                cableHistoryRepository: appDelegate.publishedCableHistoryRepository,
                cableHistoryRecorder: appDelegate.publishedCableHistoryRecorder,
                onWindowAppear: { appDelegate.notifyMainWindowDidAppear() },
                onWindowDisappear: { appDelegate.notifyMainWindowDidDisappear() },
                onPowerAppear: { appDelegate.notifyPowerSurfaceDidAppear("main-window") },
                onPowerDisappear: { appDelegate.notifyPowerSurfaceDidDisappear("main-window") }
            )
            .preferredColorScheme(currentColorScheme)
        }
        .defaultSize(MainWindowConstants.defaultWindowSize)
        .windowResizability(.contentMinSize)
        .commands {
            // Phase 11: File ▸ Export… (Cmd-E). Replaces the
            // default `importExport` group so the menu reads
            // "Export…" rather than the system's "Import from…".
            CommandGroup(replacing: .importExport) {
                Button("export.menu.item") {
                    NotificationCenter.default.post(name: .manifoldShowExportSheet, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command])
            }
            // Phase 15 #8 + F18: ⌘1 / ⌘2 / ⌘3 jump to Topology /
            // History / Diagnostics. Sidebar group keeps these
            // items grouped under View in the menu bar so the
            // user can discover them via menu inspection too.
            CommandGroup(after: .sidebar) {
                Divider()
                Button("window.tab.topology.menu") {
                    NotificationCenter.default.post(
                        name: .manifoldSelectTab,
                        object: nil,
                        userInfo: ["tab": WindowTab.topology.rawValue]
                    )
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("window.tab.history.menu") {
                    NotificationCenter.default.post(
                        name: .manifoldSelectTab,
                        object: nil,
                        userInfo: ["tab": WindowTab.history.rawValue]
                    )
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button("window.tab.diagnostics.menu") {
                    NotificationCenter.default.post(
                        name: .manifoldSelectTab,
                        object: nil,
                        userInfo: ["tab": WindowTab.diagnostics.rawValue]
                    )
                }
                .keyboardShortcut("3", modifiers: [.command])

                Button("window.tab.battery.menu") {
                    NotificationCenter.default.post(
                        name: .manifoldSelectTab,
                        object: nil,
                        userInfo: ["tab": WindowTab.battery.rawValue]
                    )
                }
                .keyboardShortcut("4", modifiers: [.command])

                // Phase 21: ⌘5 jumps to the Cables tab. Same pattern
                // as the other shortcuts — process-wide notification
                // routes to MainWindow's selectedTab binding.
                Button("window.tab.cables.menu") {
                    NotificationCenter.default.post(
                        name: .manifoldSelectTab,
                        object: nil,
                        userInfo: ["tab": WindowTab.cables.rawValue]
                    )
                }
                .keyboardShortcut("5", modifiers: [.command])

                Button("window.tab.savedCables.menu") {
                    NotificationCenter.default.post(
                        name: .manifoldSelectTab,
                        object: nil,
                        userInfo: ["tab": WindowTab.savedCables.rawValue]
                    )
                }
                .keyboardShortcut("6", modifiers: [.command])

                Button("window.tab.power.menu") {
                    NotificationCenter.default.post(
                        name: .manifoldSelectTab,
                        object: nil,
                        userInfo: ["tab": WindowTab.power.rawValue]
                    )
                }
                .keyboardShortcut("7", modifiers: [.command])

                Button("window.tab.negotiation.menu") {
                    NotificationCenter.default.post(
                        name: .manifoldSelectTab,
                        object: nil,
                        userInfo: ["tab": WindowTab.negotiation.rawValue]
                    )
                }
                .keyboardShortcut("8", modifiers: [.command])

                Button("window.tab.display.menu") {
                    NotificationCenter.default.post(
                        name: .manifoldSelectTab,
                        object: nil,
                        userInfo: ["tab": WindowTab.display.rawValue]
                    )
                }
                .keyboardShortcut("9", modifiers: [.command])
            }
        }

        // Phase 14: Settings tab view per SPEC §13. Phase 16
        // adds the Sparkle UpdaterController for the Updates
        // pane's "Check for updates now" button. Phase 19 threads
        // the alert preferences (and the live PortGraph for the
        // batteryHardwarePresent gate) into MenuBarPane.
        SettingsScene(
            onSampleRateChange: { rate in
                appDelegate.applySampleRate(rate)
            },
            loginItemController: LiveLoginItemController(),
            databaseManager: appDelegate.publishedDatabaseManager,
            downsamplingJob: appDelegate.publishedDownsamplingJob,
            updaterController: appDelegate.publishedUpdaterController,
            graph: appDelegate.publishedPortGraph,
            batteryAlertPreferences: appDelegate.publishedBatteryAlertPreferences
        )
    }

    /// Map the @AppStorage raw string to SwiftUI's
    /// `ColorScheme?`. nil → follow the system setting.
    private var currentColorScheme: ColorScheme? {
        switch ThemePreference(rawValue: themeRaw) ?? .default {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
