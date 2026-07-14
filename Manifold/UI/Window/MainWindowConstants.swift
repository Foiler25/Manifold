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
    /// uglily. Sized so that, with the sidebar + inspector at their
    /// mins, the middle column still has ~240 pt of usable width.
    static let minimumWindowSize: CGSize = CGSize(width: 780, height: 420)

    /// Sidebar column widths. The 220 pt minimum is the value the user
    /// requested — host names longer than ~16 characters will tail-
    /// truncate with an ellipsis at this width rather than clip past
    /// the trailing edge (HostSidebarRow applies `.lineLimit(1)` +
    /// `.truncationMode(.tail)` so the truncation is graceful).
    static let sidebarIdealWidth: CGFloat = 240
    static let sidebarMinWidth: CGFloat = 220
    static let sidebarMaxWidth: CGFloat = 360

    /// Legacy detail-column widths (used by the popover and any code
    /// path that still treats the inspector as a NavigationSplitView
    /// detail column). The native-polish refactor presents the inspector
    /// via SwiftUI's `.inspector` modifier with the dedicated
    /// `inspector*` widths below.
    static let detailIdealWidth: CGFloat = 280
    static let detailMinWidth: CGFloat = 240

    /// Inspector / detail pane widths. Capped at 300 pt so the
    /// device-detail pane stays a fixed slim column even on a wide
    /// monitor — the topology canvas in the middle column is what
    /// should absorb extra horizontal space, not the inspector.
    static let inspectorMinWidth: CGFloat = 260
    static let inspectorIdealWidth: CGFloat = 300
    static let inspectorMaxWidth: CGFloat = 300

    /// Ideal seed width for the middle (content) column. The actual
    /// width flexes with the window size — sidebar and detail are
    /// pinned within their own ranges, content absorbs the slack.
    static let contentIdealWidth: CGFloat = 480

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

    /// `@SceneStorage` key for the inspector pane's visibility. Persisted
    /// so a user who closes the inspector keeps it closed across launches.
    static let sceneStorageInspectorVisibleKey = "manifold.window.inspectorVisible"

    /// `NSWindow.frameAutosaveName`. AppKit persists window size +
    /// position under the `defaults` key `"NSWindow Frame
    /// ManifoldMainWindow"` whenever the user resizes or moves the
    /// window, and restores from there on next launch.
    ///
    /// Per SPEC §18 Phase 6 rev-6 (and the §18.0 `WINDOW-FRAME-PERSISTS`
    /// procedure), this MUST match the literal `"ManifoldMainWindow"`
    /// (no hyphen) so the Reviewer's
    /// `defaults read com.Loofa.Manifold "NSWindow Frame ManifoldMainWindow"`
    /// verification step finds the key.
    ///
    /// Wired explicitly via AppKit from `AppDelegate.applicationDidFinishLaunching`'s
    /// `installMainWindowFrameAutosaveName()` — NOT relying on
    /// SwiftUI's `WindowGroup` automatic state save (which Phase 6
    /// rev 6 explicitly forbids depending on).
    static let windowFrameAutosaveName = "ManifoldMainWindow"
}

// MARK: - WindowTab enum

/// Top-level tabs of the main window. `String` raw values so
/// `@SceneStorage` can persist directly. `topology` is the default
/// selected tab.
///
/// The Power tab was merged into Battery — input adapter wattage
/// now sits inside the charge banner and the USB draw section is
/// the first card on the Battery tab — so `.power` was retired and
/// `.battery` took the ⌘4 keyboard shortcut.
enum WindowTab: String, CaseIterable, Identifiable {
    case topology
    case history
    case diagnostics
    case battery
    /// Phase 21: per-cable USB-C / Thunderbolt diagnostics (e-marker,
    /// PD power profile, transport capabilities). Backed by the
    /// `CableEngine` adapter on top of the absorbed cable-diagnostics
    /// engine — see `Manifold/Sources/Cables/`.
    case cables
    case power = "powerMonitorV2"
    case negotiation
    case display

    var id: String { rawValue }

    /// Localised display label for the tab control. Strings catalog
    /// keyed by tab.<case>.label so a translator can give them
    /// distinct names without touching code.
    var labelKey: String {
        if self == .power { return "window.tab.power.label" }
        return "window.tab.\(rawValue).label"
    }

    /// SF Symbol used in the tab control.
    var systemImageName: String {
        switch self {
        case .topology:    return "rectangle.grid.2x2"
        case .history:     return "clock.arrow.circlepath"
        case .diagnostics: return "exclamationmark.triangle"
        case .battery:     return "bolt.batteryblock"
        case .cables:      return "cable.connector"
        case .power:       return "bolt.horizontal.circle"
        case .negotiation: return "arrow.left.arrow.right"
        case .display:     return "display"
        }
    }
}
