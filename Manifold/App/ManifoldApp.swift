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
//   • `WindowGroup` — the standalone window app (Phase 6 fills it out).
//   • `Settings`    — the settings pane (Phase 14 fills it out).
//
// The menu bar `NSStatusItem` is owned by `AppDelegate`, attached here via
// `@NSApplicationDelegateAdaptor`. We pick the AppDelegate-shimmed approach
// rather than `MenuBarExtra` per DECISIONS.md D1/D15 — `MenuBarExtra` cannot
// render the numeric badge over the menu bar icon that Manifold needs from
// Phase 4 onward.

import SwiftUI

@main
struct ManifoldApp: App {

    /// Bridges the SwiftUI app lifecycle to the AppKit `NSStatusItem`.
    /// The adaptor instantiates `AppDelegate` once per app lifetime and
    /// keeps it alive for the duration of the process.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Phase 0: an empty placeholder window. Phase 6 replaces this with
        // the three-pane `NavigationSplitView` (sidebar / topology / inspector)
        // described in SPEC.md §13.
        WindowGroup {
            PlaceholderRootView()
        }

        // Phase 0: empty Settings scene so `cmd-,` doesn't crash.
        // Phase 14 builds out General/Notifications/History/Updates/About panes.
        Settings {
            PlaceholderSettingsView()
        }
    }
}

/// Phase-0 stand-in for the main window's content. Replaced wholesale in
/// Phase 6 by `MainWindow` from `Manifold/UI/Window/`.
private struct PlaceholderRootView: View {
    var body: some View {
        // Strings live in `Localizable.xcstrings` per builder.md ("no
        // hardcoded strings in views"). The keys are typed-in literals that
        // SwiftUI's `LocalizedStringKey` initializer resolves against the
        // catalog at runtime.
        VStack(spacing: 12) {
            Text("placeholder.window.title")
                .font(.title2)
                .bold()
            Text("placeholder.window.subtitle")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}

/// Phase-0 stand-in for the Settings scene. Replaced in Phase 14.
private struct PlaceholderSettingsView: View {
    var body: some View {
        Text("placeholder.settings.title")
            .padding(40)
    }
}
