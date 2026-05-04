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
// BatteryPopoverHostingView.swift
//
// Phase 18 — sibling of `PopoverHostingView` for the battery menubar
// slot. Constructs an `NSPopover` whose content is `BatteryPopoverRoot`.
// Smaller seed size (~280 pt) than the primary popover (~360 pt) per
// SPEC §20.6 / Plan §18.

import AppKit
import SwiftUI
import ManifoldKit

@MainActor
enum BatteryPopoverHostingView {

    /// Build the battery popover. The closure runs when the user
    /// taps the toolbar "Open Manifold" button — AppDelegate /
    /// BatteryStatusItemController owns the actual window-opening
    /// logic.
    static func makePopover(
        graph: PortGraph,
        onOpenWindow: @escaping @MainActor () -> Void
    ) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let hosting = NSHostingController(
            rootView: BatteryPopoverRoot(
                graph: graph,
                onOpenWindow: onOpenWindow
            )
        )
        // Match the primary popover's sizing model so the popover
        // grows / shrinks with the rendered content.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentSize = AppConstants.batteryPopoverContentSize
        popover.contentViewController = hosting
        return popover
    }
}
