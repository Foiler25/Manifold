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
// AppConstants.swift
//
// Named constants for the App module. Per builder.md, magic numbers and
// stringly-typed identifiers belong in a per-module Constants file rather
// than scattered through call sites. As more App-layer code arrives in
// later phases (PopoverRoot frame size, animation durations, app-group
// identifier reuse, etc.) it lands here.

import Foundation
import AppKit

enum AppConstants {

    /// Width of the status bar slot in points. `NSStatusItem.variableLength`
    /// asks AppKit to size to the icon's intrinsic width — what we want for
    /// a square SF Symbol icon, and also what we will need from Phase 4 on
    /// when the icon gains a numeric badge that changes its width.
    static let statusItemLength: CGFloat = NSStatusItem.variableLength

    /// SF Symbol used as the menu bar icon during Phase 0.
    ///
    /// `bolt.horizontal.circle.fill` was picked for the placeholder because
    /// it reads as "power flowing through a port" at 16 pt and stays
    /// legible as a template image in both light and dark menu bars. It is
    /// explicitly a placeholder; Phase 15 (Polish) replaces it with the
    /// brand mark — the concentric-circle-plus-radiating-strokes manifold
    /// motif from BRIEF.md's Iconography section.
    static let menuBarIconSymbolName: String = "bolt.horizontal.circle.fill"

    /// App Group identifier shared between the host app and the widget
    /// extension for snapshot file IO. Defined here so both targets agree
    /// on the same string. Used in earnest from Phase 13.
    static let appGroupIdentifier: String = "group.com.Loofa.Manifold"

    /// Initial seed size for the popover. Width 360 pt per SPEC §13.1
    /// ("Fixed width 360pt"); height is just the first-frame value
    /// before SwiftUI computes the real size — `PopoverRoot` drives
    /// the actual height via `NSHostingController.preferredContentSize`,
    /// scaling to fit the visible rows.
    static let popoverContentSize: CGSize = CGSize(width: 360, height: 360)

    /// Number of port rows visible in the popover before the inner
    /// scroll view starts scrolling. Above this count the scroll
    /// section pins at `popoverPortRowHeight × popoverScrollThreshold`
    /// and the popover stops growing taller.
    static let popoverScrollThreshold: Int = 3

    /// Approximate visual height of one port row in the popover scroll
    /// section: the row's header HStack + 6 pt spacing + the inline
    /// TelemetryChart (72 pt) + 4+4 pt vertical padding from the
    /// `.padding(.vertical, 4)` modifier wrapping each row. Used to
    /// compute the scroll section's frame height so the popover hugs
    /// its content for ≤ N rows and locks at N rows above.
    static let popoverPortRowHeight: CGFloat = 130
}
