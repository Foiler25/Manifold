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
// PopoverDelegateAdapter.swift
//
// Phase 18 — `NSPopoverDelegate` adapter shared by both status-item
// controllers. Lifted out of `StatusItemController.swift` (where it
// was a nested private type) so `BatteryStatusItemController` can
// reuse it without duplicating the bridging boilerplate (per D17 +
// SPEC §20.6).
//
// Why this isn't a closure-on-NSPopover: NSPopover.delegate is a
// `weak` property typed `NSPopoverDelegate?`. We need a concrete
// reference type to live somewhere with at least the popover's
// lifetime. `PopoverDelegateAdapter` holds that reference and
// forwards the `NSObject`-typed callbacks through to MainActor-typed
// closures, which is what the controllers actually want to call.

import AppKit

/// `NSPopoverDelegate` adapter. Bridges NSPopoverDelegate's
/// Objective-C callbacks to a Swift closure pair. Both
/// `StatusItemController` and `BatteryStatusItemController` retain
/// one of these alongside the popover so the delegate stays alive as
/// long as the popover does — `NSPopover.delegate` is `weak`.
@MainActor
final class PopoverDelegateAdapter: NSObject, NSPopoverDelegate {
    private let onShow: @MainActor () -> Void
    private let onClose: @MainActor () -> Void

    init(
        onShow: @escaping @MainActor () -> Void = {},
        onClose: @escaping @MainActor () -> Void = {}
    ) {
        self.onShow = onShow
        self.onClose = onClose
    }

    nonisolated func popoverDidShow(_ notification: Notification) {
        Task { @MainActor in onShow() }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in onClose() }
    }
}

// MARK: - NSFont weight helper

extension NSFont {
    /// `NSFont.menuBarFont(ofSize: 0)` returns the canonical menu-bar
    /// font; this helper re-applies a desired weight while preserving
    /// the family + point size. Used to make the badge number stand
    /// out subtly without hardcoding the menu-bar font name (which can
    /// shift between OS versions).
    ///
    /// Lives here (next to `PopoverDelegateAdapter`, the other shared
    /// menubar helper) so both `StatusItemController` and
    /// `BatteryStatusItemController` can reach it. Phase 18 lift —
    /// previously a `fileprivate extension` inside
    /// `StatusItemController.swift`.
    func withWeightApplied(_ weight: NSFont.Weight) -> NSFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: weight]
        ])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
