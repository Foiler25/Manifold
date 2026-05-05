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
// NotchAnchor.swift
//
// Phase 19 — pure-geometry resolver for the physical notch (or its
// absence) on the screen containing the mouse cursor. Reads from
// `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` (macOS
// 12+; the project's `MACOSX_DEPLOYMENT_TARGET = 26.0` makes them
// unconditionally safe).
//
// Per SPEC §21.2, the resolver returns `hasNotch: false` for M1 Air,
// external displays, lid-closed clamshell setups; `NotchPanelController`
// then renders a top-of-screen rounded rectangle without the concave
// shoulders (SPEC §21.12 fallback).
//
// **Testability.** The geometry computation is split into a pure
// `compute(...)` function that takes a `(left: CGRect?, right: CGRect?,
// screenFrame: CGRect)` triple. `resolve()` reads from `NSScreen` +
// the live mouse cursor; `compute(...)` is what the unit tests
// exercise on synthetic CGRects with no AppKit lookups.

import AppKit

/// Geometry snapshot for one screen's notch (or absence). Returned
/// by `NotchAnchor.resolve()` on every `NotchPanelController.show(_:)`
/// — cheap to recompute and lets the controller pick the right
/// rendering path on the fly when the user moves the cursor between
/// notched + non-notched screens.
struct NotchAnchor: Equatable {

    /// Screen the panel will render on. `nil` only when the active
    /// screen lookup fails entirely (no `NSScreen` available),
    /// which we treat as "skip the alert" rather than crash.
    /// Wrapped in optional storage on `NotchAnchor` to keep the
    /// pure-geometry `compute(...)` signature decoupled from the
    /// `NSScreen` indirection.
    let screen: NSScreen?

    /// Origin = top-left of the physical notch in screen coordinates;
    /// size.width == notchWidth, size.height == notchHeight. `.zero`
    /// when `hasNotch == false`.
    let notchFrame: CGRect

    /// True when both auxiliary areas were non-nil and produced a
    /// positive-width notch rect. False for M1 Air, external
    /// displays, lid-closed clamshell.
    let hasNotch: Bool

    /// Live screen frame (`screen.frame`) used to position the
    /// non-notched fallback rounded rectangle at top-center per
    /// SPEC §21.12. Captured here so the controller can pin the
    /// panel frame without re-fetching `screen.frame` (which can
    /// race a screen-config change).
    let screenFrame: CGRect

    // MARK: - Resolve

    /// Pick the screen containing `NSEvent.mouseLocation` and read
    /// its auxiliary-area properties. Returns nil only when no
    /// screen is found at all (no displays attached, which can't
    /// happen for a running interactive app — the caller treats nil
    /// as "skip the alert").
    static func resolve() -> NotchAnchor? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return nil }
        let computed = compute(
            left: screen.auxiliaryTopLeftArea,
            right: screen.auxiliaryTopRightArea,
            screenFrame: screen.frame
        )
        return NotchAnchor(
            screen: screen,
            notchFrame: computed.notchFrame,
            hasNotch: computed.hasNotch,
            screenFrame: screen.frame
        )
    }

    // MARK: - Pure geometry

    /// Pure geometry — what `NotchAnchorTests` exercises. Given the
    /// two auxiliary areas + a screen frame, derive the notch rect
    /// and the `hasNotch` flag. Both nils → no notch. Either nil →
    /// no notch (degenerate case where the OS reports only one side).
    /// Both present → compute the gap between them.
    static func compute(
        left: CGRect?,
        right: CGRect?,
        screenFrame: CGRect
    ) -> NotchAnchorGeometry {
        guard let left, let right else {
            return NotchAnchorGeometry(notchFrame: .zero, hasNotch: false)
        }
        let notchHeight = max(left.height, right.height)
        let notchWidth = right.minX - left.maxX
        guard notchWidth > NotchAnchorConstants.minimumNotchWidth else {
            return NotchAnchorGeometry(notchFrame: .zero, hasNotch: false)
        }
        // Top-edge Y in NSScreen-coordinate space (origin bottom-left):
        // notch sits at the top of the screen, so its lower edge is at
        // screenFrame.maxY - notchHeight.
        let notchY = screenFrame.maxY - notchHeight
        let frame = CGRect(
            x: left.maxX,
            y: notchY,
            width: notchWidth,
            height: notchHeight
        )
        return NotchAnchorGeometry(notchFrame: frame, hasNotch: true)
    }
}

// MARK: - Pure-geometry result

/// Output of `NotchAnchor.compute(...)`. Separated from `NotchAnchor`
/// so the unit tests don't need to fabricate a `NSScreen?` value
/// (NSScreen is process-bound; tests run on a non-notched CI Mac
/// where the live `NSScreen.main.auxiliaryTopLeftArea` is nil).
struct NotchAnchorGeometry: Equatable {
    let notchFrame: CGRect
    let hasNotch: Bool
}

// MARK: - Constants

enum NotchAnchorConstants {
    /// Below this, the gap between auxiliary areas is too narrow to
    /// draw a notch silhouette against — the controller falls back
    /// to the no-notch path. 1pt threshold defends against floating-
    /// point noise on edge cases (we've seen `right.minX - left.maxX`
    /// land at `-0.0` on certain configs).
    static let minimumNotchWidth: CGFloat = 1.0
}
