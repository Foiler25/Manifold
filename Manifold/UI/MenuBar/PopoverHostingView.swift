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
// PopoverHostingView.swift
//
// Thin AppKit-side helper that constructs an `NSHostingController`
// wrapping `PopoverRoot`. Per SPEC.md §13.1's "NSPopover containing
// PopoverHostingView (an NSHostingController wrapping PopoverRoot)."
//
// Splitting this out from `StatusItemController` keeps the popover
// construction story discoverable in a single named function (the
// alternative — inlining `NSHostingController(rootView: …)` inside
// `StatusItemController.makePopover()` — buries the AppKit↔SwiftUI
// boundary inside a longer method).

import AppKit
import SwiftUI
import ManifoldKit

@MainActor
enum PopoverHostingView {

    /// Build an `NSPopover` whose content is a SwiftUI `PopoverRoot`
    /// observing the supplied `PortGraph`. The two callbacks run when
    /// the user taps the toolbar buttons; AppDelegate / StatusItemController
    /// owns the actual window-opening + settings-opening logic.
    static func makePopover(
        graph: PortGraph,
        onOpenWindow: @escaping @MainActor () -> Void,
        onOpenSettings: @escaping @MainActor () -> Void
    ) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = AppConstants.popoverContentSize
        popover.contentViewController = NSHostingController(
            rootView: PopoverRoot(
                graph: graph,
                onOpenWindow: onOpenWindow,
                onOpenSettings: onOpenSettings
            )
        )
        return popover
    }
}
