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
// MainWindowConstants.swift
//
// Window-module constants per builder.md "no magic numbers" rule.
// Sizes, scene-storage keys, tab identifiers — anything Phase 6+
// views need a stable name for.

import Foundation
import SwiftUI

enum MainWindowConstants {

    // MARK: - Window sizing

    /// Default window size on first launch. Big enough that the
    /// three-pane NavigationSplitView shows real content in each
    /// column without manual resize. Subsequent launches use the
    /// system-persisted frame via `NSWindow.frameAutosaveName`.
    static let defaultWindowSize: CGSize = CGSize(width: 920, height: 600)

    /// Minimum window size below which the three-pane layout collapses
    /// uglily. Picked so each column has at least ~200 pt of usable
    /// width.
    static let minimumWindowSize: CGSize = CGSize(width: 720, height: 400)

    /// Sidebar column ideal width. NavigationSplitView resolves it
    /// against the user's resize gesture and the window's overall
    /// width; this is the seed value.
    static let sidebarIdealWidth: CGFloat = 200
    static let sidebarMinWidth: CGFloat = 160
    static let sidebarMaxWidth: CGFloat = 320

    /// Detail column ideal width.
    static let detailIdealWidth: CGFloat = 280
    static let detailMinWidth: CGFloat = 240

    // MARK: - Scene storage keys

    /// `@SceneStorage` key for the currently-selected tab. String
    /// because that's the simplest @SceneStorage-compatible type for
    /// our small enum. Keep this string stable across releases —
    /// changing it resets every existing user's selected tab on
    /// upgrade.
    static let sceneStorageSelectedTabKey = "manifold.window.selectedTab"

    /// `@SceneStorage` key for the selected host's `HostID.rawValue`.
    /// nil means "no host selected" → sidebar shows hosts but content
    /// renders the empty-state.
    static let sceneStorageSelectedHostKey = "manifold.window.selectedHost"

    /// `@SceneStorage` key for the selected device's `DeviceID.rawValue`.
    /// Detail column reads this; nil → "select a device" empty state.
    static let sceneStorageSelectedDeviceKey = "manifold.window.selectedDevice"

    /// `NSWindow.frameAutosaveName`. Setting this on the WindowGroup's
    /// underlying NSWindow makes AppKit persist size + position to
    /// `~/Library/Preferences/com.Loofa.Manifold.plist` automatically.
    /// SwiftUI's `WindowGroup` inherits this via `.windowResizability`
    /// and friends; we set it explicitly via the `windowToolbarStyle`
    /// modifier in MainWindow.
    static let windowFrameAutosaveName = "Manifold-MainWindow"
}

// MARK: - WindowTab enum

/// The three top-level tabs of the main window per SPEC §13.2 / §18
/// Phase 6 acceptance #3. `String` raw values so `@SceneStorage` can
/// persist directly. `topology` is the default selected tab.
enum WindowTab: String, CaseIterable, Identifiable {
    case topology
    case history
    case diagnostics

    var id: String { rawValue }

    /// Localised display label for the tab control. Strings catalog
    /// keyed by tab.<case>.label so a translator can give them
    /// distinct names without touching code.
    var labelKey: String {
        "window.tab.\(rawValue).label"
    }

    /// SF Symbol used in the tab control.
    var systemImageName: String {
        switch self {
        case .topology:    return "rectangle.grid.2x2"
        case .history:     return "clock.arrow.circlepath"
        case .diagnostics: return "exclamationmark.triangle"
        }
    }
}
