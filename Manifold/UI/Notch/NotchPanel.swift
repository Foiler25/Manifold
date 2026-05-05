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
// NotchPanel.swift
//
// Phase 19 — `NSPanel` subclass that hosts the notch-pop SwiftUI
// content. Configuration values pinned per SPEC §21.1 — Reviewer
// reads each one against this file. The panel itself is a transparent
// rectangle; `NotchHostView` (the SwiftUI content) draws the visible
// silhouette via `NotchBlendShape`. The `.statusBar` window level +
// `.fullScreenAuxiliary` collection behavior let the panel float
// above fullscreen apps without becoming key (D19).

import AppKit

/// Borderless, non-activating panel that hosts a SwiftUI notch
/// dropdown. Owned by `NotchPanelController`; the controller is
/// responsible for sizing + positioning + animating the panel in/out.
final class NotchPanel: NSPanel {

    /// Initialize with a content rect (controller computes from
    /// `NotchAnchor.resolve()`). Style mask + level + collection
    /// behavior are fixed per SPEC §21.1 — the values below are
    /// load-bearing for the float-above-fullscreen behavior and the
    /// "never steals focus" guarantee.
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // `.popUpMenu` (101) is above the system menubar (24) and
        // above `.statusBar` (25) — using `.statusBar` produced a
        // race where the panel was z-ordered behind the menubar on
        // some macOS Tahoe builds. `.popUpMenu` is what NSMenu /
        // NSPopover use for transient overlays and reliably wins.
        self.level = .popUpMenu
        // `.canJoinAllSpaces` deliberately omitted: it triggers an
        // AppKit cross-workspace layout cascade on `orderFront` that
        // hits a Swift 6 strict-concurrency runtime bug in SwiftUI
        // (executor-isolation check reads a freed `SerialExecutor`
        // and crashes inside MainWindow's segmented Picker on macOS
        // Tahoe). `.moveToActiveSpace` is enough to put the panel on
        // whatever Space the user is currently on — the cost is the
        // panel doesn't follow them if they switch Spaces while it
        // is open, which is fine given the 3-second auto-dismiss.
        self.collectionBehavior = [
            .moveToActiveSpace,
            .fullScreenAuxiliary
        ]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.hidesOnDeactivate = false
        self.isMovableByWindowBackground = false
        self.isReleasedWhenClosed = false
    }

    // MARK: - Focus

    /// Never steals key — the panel is a passive overlay that auto-
    /// dismisses on a timer; making it key would consume keyboard
    /// focus from whatever app is in front.
    override var canBecomeKey: Bool { false }

    /// Mirror of `canBecomeKey` for main-window status; we don't
    /// want this panel showing up in the application's main-window
    /// chain.
    override var canBecomeMain: Bool { false }
}
