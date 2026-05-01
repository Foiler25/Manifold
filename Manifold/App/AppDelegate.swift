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
// AppDelegate.swift
//
// Owns the single `NSStatusItem` that appears in the system menu bar. The
// status item is what makes Manifold a "menu bar utility"; the standalone
// window app is hosted by `WindowGroup` in `ManifoldApp.swift`.
//
// Phase 0 scope: install the status item, render a placeholder SF Symbol
// as the menu bar icon, and leave the click handler as a no-op (just
// toggles button highlight). Phase 4 wires the click to an `NSPopover`
// hosting `PopoverRoot` (SwiftUI), per DECISIONS.md D15.
//
// Why `@MainActor` on the whole class: every AppKit interaction in this
// file (`NSStatusBar`, `NSStatusItem.button`, `NSImage`) is main-actor
// constrained in Swift 6 strict mode. Marking the class once is cleaner
// than annotating every member.

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Status item

    /// The system-vended menu bar slot. Held strongly because `NSStatusBar`
    /// otherwise releases it the moment we drop the reference.
    private var statusItem: NSStatusItem?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
    }

    // MARK: - Status item setup

    /// Builds the `NSStatusItem`, sets a templated SF Symbol as its icon,
    /// and wires (Phase 0) a no-op click handler.
    ///
    /// Template image (`isTemplate = true`) tells AppKit to invert and tint
    /// the icon to match the menu bar's appearance — required for the icon
    /// to stay legible across light/dark menu bar backgrounds.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: AppConstants.statusItemLength)

        guard let button = item.button else {
            // `NSStatusItem.button` is nil only when the status bar is
            // unavailable (headless test runs). Safe no-op in that case.
            return
        }

        let image = NSImage(
            systemSymbolName: AppConstants.menuBarIconSymbolName,
            accessibilityDescription: NSLocalizedString(
                "menubar.icon.accessibility",
                comment: "Spoken description of the Manifold menu bar icon."
            )
        )
        image?.isTemplate = true
        button.image = image

        // Phase 0 click handler is intentionally a no-op. Phase 4 replaces
        // this with an action that toggles the SwiftUI-hosted popover.
        button.target = self
        button.action = #selector(statusItemClicked(_:))

        statusItem = item
    }

    @objc
    private func statusItemClicked(_ sender: Any?) {
        // Phase 4 wires this to `togglePopover()`. Until then, the button
        // simply highlights on click — by virtue of being a target/action
        // button — and does nothing else.
    }
}
