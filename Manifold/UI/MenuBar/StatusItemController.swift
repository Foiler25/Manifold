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
// StatusItemController.swift
//
// Owns the `NSStatusItem` and its lifecycle. Phase 4 extracts this
// from `AppDelegate` per SPEC.md §3 file tree, and adds the **numeric
// badge for connected device count** required by SPEC §18 Phase 4
// acceptance #1.
//
// Badge rendering: the SF Symbol icon stays as `button.image`
// (`isTemplate = true`, auto-tints with menu bar appearance); the
// count number is drawn as `button.attributedTitle` next to the icon
// (image-left, title-right). This is the same pattern macOS's built-in
// status items use (Bluetooth, Wi-Fi, etc.) — keeps the count legible
// at 16 pt.
//
// SPEC §13.1 says "Numeric badge: total connected device count,
// drawn as a NSAttributedString overlay" — flagged as deviation in
// BUILD_LOG: image-left/title-right interpreted as legible
// alternative to a true icon-overlay (which would be too small to
// read at menu-bar scale). Reviewer confirms.

import AppKit
import SwiftUI
import os
import ManifoldKit

@MainActor
final class StatusItemController {

    // MARK: - State

    /// Held strongly because `NSStatusBar` releases the slot the
    /// moment we drop the reference.
    private var statusItem: NSStatusItem?

    /// Lazily constructed on first popover open. Phase 0 deferred this
    /// to "first user click"; Phase 4 keeps the same pattern.
    private var popover: NSPopover?

    /// PortGraph reference held so `setDeviceCount` updates the badge
    /// AND so the popover content sees a live `@Observable` instance.
    private let graph: PortGraph

    /// Closures injected by AppDelegate so the popover toolbar's
    /// "open window" / "settings" buttons trigger AppKit-level
    /// activation without StatusItemController knowing about
    /// `NSApplication`.
    private let onOpenWindow: @MainActor () -> Void
    private let onOpenSettings: @MainActor () -> Void

    init(
        graph: PortGraph,
        onOpenWindow: @escaping @MainActor () -> Void,
        onOpenSettings: @escaping @MainActor () -> Void
    ) {
        self.graph = graph
        self.onOpenWindow = onOpenWindow
        self.onOpenSettings = onOpenSettings
    }

    // MARK: - Install

    /// Build the `NSStatusItem`, install the SF-Symbol icon, wire the
    /// click handler. Call once from `applicationDidFinishLaunching`.
    func install() {
        let item = NSStatusBar.system.statusItem(withLength: AppConstants.statusItemLength)

        guard let button = item.button else {
            // Headless test runs land here. Safe no-op.
            return
        }

        button.image = makeBaseIcon()
        button.imagePosition = .imageOnly
        button.imageHugsTitle = true
        button.target = self
        button.action = #selector(buttonClicked(_:))

        statusItem = item
        Log.app.info("NSStatusItem installed.")
    }

    /// Update the badge to reflect `count` total connected devices.
    /// Called from AppDelegate whenever PortGraph changes (every
    /// successful walk + apply). count == 0 → image-only; count > 0 →
    /// image-left, attributedTitle-right.
    func setDeviceCount(_ count: Int) {
        guard let button = statusItem?.button else { return }

        if count == 0 {
            button.attributedTitle = NSAttributedString()
            button.imagePosition = .imageOnly
            return
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuBarFont(ofSize: 0).withWeightApplied(.semibold),
            .foregroundColor: NSColor.labelColor
        ]
        // Leading space gives a small gap between the icon and the
        // number — the system's `imageHugsTitle` brings them flush
        // otherwise, which reads as a single run.
        button.attributedTitle = NSAttributedString(string: " \(count)", attributes: attrs)
        button.imagePosition = .imageLeft
    }

    // MARK: - Click handling

    @objc
    private func buttonClicked(_ sender: Any?) {
        let popover = popoverIfNeeded()
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func popoverIfNeeded() -> NSPopover {
        if let existing = popover { return existing }
        let popover = PopoverHostingView.makePopover(
            graph: graph,
            onOpenWindow: onOpenWindow,
            onOpenSettings: onOpenSettings
        )
        self.popover = popover
        return popover
    }

    // MARK: - Icon construction

    /// Build the SF Symbol icon used as the status-item glyph. Phase
    /// 0's bolt placeholder; Phase 15 swaps in the custom
    /// `MenuBarIcon.symbolset` brand mark.
    private func makeBaseIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: AppConstants.menuBarIconSymbolName,
            accessibilityDescription: NSLocalizedString(
                "menubar.icon.accessibility",
                comment: "Spoken description of the Manifold menu bar icon."
            )
        )
        image?.isTemplate = true
        return image
    }
}

// MARK: - Font weight helper

private extension NSFont {
    /// `NSFont.menuBarFont(ofSize: 0)` returns the canonical menu-bar
    /// font; this helper re-applies a desired weight while preserving
    /// the family + point size. Used to make the badge number stand
    /// out subtly without hardcoding the menu-bar font name (which can
    /// shift between OS versions).
    func withWeightApplied(_ weight: NSFont.Weight) -> NSFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: weight]
        ])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
