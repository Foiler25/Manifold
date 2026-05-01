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

    /// Size of the Phase-1 placeholder popover. Wide enough to fit a
    /// device row's fallback "VID:PID" caption on one line; tall enough
    /// for a typical 4-6 device list without scrolling. Phase 4's full
    /// popover may revisit these dimensions when `OutlineGroup` is
    /// introduced for hierarchy display.
    static let popoverContentSize: CGSize = CGSize(width: 320, height: 360)
}
