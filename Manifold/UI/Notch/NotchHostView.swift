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
// NotchHostView.swift
//
// Phase 19 — SwiftUI host content for the `NotchPanel`. Renders the
// `NotchBlendShape` silhouette + the supplied content view in a ZStack,
// driving the open / close springs (SPEC §21.4) via the controller-
// supplied `progress` binding.
//
// Click-through: an `NSHostingView` subclass (`NotchHostingView`)
// overrides `hitTest(_:)` to return nil for points outside the
// visible shape so the transparent shoulders pass clicks to the
// app underneath. The hostingController in `NotchPanelController`
// uses this subclass via a custom hostingController shape.

import AppKit
import SwiftUI

/// SwiftUI root content for the notch panel. Composes the blend
/// shape + content view + entry/exit animations. Generic over the
/// content view type so the controller can swap content per alert.
struct NotchHostView<Content: View>: View {

    /// Width of the physical notch in points. The shape's frame
    /// collapses to this width (× zero height) when `isOpen == false`,
    /// so the closed state is a thin pill of exactly the notch's
    /// horizontal extent — the open animation reads as the dropdown
    /// unfurling out from the notch's lower edge.
    let notchWidth: CGFloat

    /// Height of the physical notch in points. The canvas's top edge
    /// sits at the screen top (behind the notch), so the area from
    /// y=0 to y=notchHeight in the shape's coordinate system is the
    /// portion hidden behind the notch hardware mask. Content has to
    /// be padded past this Y to be visible. 0 when `hasNotch` is
    /// false (no masked area).
    let notchHeight: CGFloat

    /// Whether the active screen has a physical notch. Drives both
    /// the silhouette (concave-shoulder NotchBlendShape vs plain
    /// RoundedRectangle) AND the content's top padding (clear the
    /// notch mask vs a small breathing buffer).
    let hasNotch: Bool

    /// Open / closed flag. Drives the `.frame` interpolation. Caller
    /// sets this inside `withAnimation` so the spring animates the
    /// width / height transition.
    let isOpen: Bool

    /// Content fade progress 0...1. Driven by a separate
    /// `.easeOut(duration: 0.26).delay(0.14)` so the content fades in
    /// after the shape unfurls.
    let contentOpacity: CGFloat

    /// Fully-open canvas size. The frame interpolates between
    /// `(notchWidth, 0)` and this value.
    let canvasSize: CGSize

    /// Caller-supplied content view rendered on top of the shape.
    let content: Content

    var body: some View {
        let liveWidth = isOpen ? canvasSize.width : max(notchWidth, 1)
        let liveHeight = isOpen ? canvasSize.height : 0

        ZStack(alignment: .top) {
            // Notched displays get the concave-shoulder shape so the
            // top corners blend into the physical notch. Non-notched
            // displays get a plain rounded rectangle — no notch to
            // blend with, so the concave indents would just look
            // like decorative scoops. Same fill color + shadow on
            // both paths.
            Group {
                if hasNotch {
                    NotchBlendShape(
                        shoulderRadius: NotchBlendShapeConstants.shoulderRadius,
                        bottomRadius: NotchBlendShapeConstants.bottomRadius
                    )
                    .fill(NotchHostViewConstants.fillColor)
                } else {
                    RoundedRectangle(
                        cornerRadius: NotchHostViewConstants.fallbackCornerRadius,
                        style: .continuous
                    )
                    .fill(NotchHostViewConstants.fillColor)
                }
            }
            .shadow(
                color: NotchHostViewConstants.shadowColor,
                radius: NotchHostViewConstants.shadowRadius,
                x: 0,
                y: NotchHostViewConstants.shadowYOffset
            )
            .frame(width: liveWidth, height: liveHeight)

            // Content padding adapts to the screen kind:
            //   - Notched: clear the masked area at top (notchHeight)
            //     plus a small buffer below the notch's lower edge.
            //   - Non-notched: just a regular top padding — no mask
            //     to clear, so the title sits closer to the canvas
            //     top, eliminating the empty band that would
            //     otherwise feel like phantom-notch padding.
            let topPadding: CGFloat = hasNotch
                ? notchHeight + NotchHostViewConstants.contentBelowNotchPadding
                : NotchHostViewConstants.contentTopPaddingFallback
            let bottomPadding: CGFloat = hasNotch
                ? NotchHostViewConstants.contentBottomPadding
                : NotchHostViewConstants.contentBottomPaddingFallback
            content
                .padding(.top, topPadding)
                .padding(.horizontal, NotchHostViewConstants.contentHorizontalPadding)
                .padding(.bottom, bottomPadding)
                .frame(width: liveWidth, height: liveHeight, alignment: .top)
                .opacity(contentOpacity)
                .clipped()
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .top)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Click-through NSHostingView

/// `NSHostingView` subclass that returns nil from `hitTest(_:)` when
/// the point isn't inside the visible `NotchBlendShape` silhouette
/// — the transparent shoulders + the area above the notch panel
/// pass clicks through to whatever app is underneath.
///
/// The `NotchPanelController` builds the hosting controller with a
/// matching content view and registers a path-provider closure that
/// describes the current visible silhouette in this view's
/// coordinate space.
final class NotchClickThroughHostingView<Content: View>: NSHostingView<Content> {

    /// Closure returning the visible silhouette path in this view's
    /// coordinate system. Set by the controller after construction;
    /// nil falls back to default hit-testing (everything inside
    /// bounds is hit). The path provider is read on every event so
    /// it tracks the live `progress` value.
    var visiblePathProvider: (() -> Path)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let provider = visiblePathProvider else {
            return super.hitTest(point)
        }
        let path = provider()
        // Convert NSPoint to CGPoint and ask SwiftUI's Path whether
        // the point is contained. AppKit hitTest uses the parent
        // coordinate space, but since this view is the panel's
        // content view it shares its origin, so a direct contains()
        // works.
        let cgPoint = CGPoint(x: point.x, y: point.y)
        return path.contains(cgPoint) ? super.hitTest(point) : nil
    }
}

// MARK: - Constants

enum NotchHostViewConstants {
    /// Fill color of the dropdown silhouette. Pure `Color.black`
    /// (not `Color.manifoldSurface` / `#0A0A0A`) so the dropdown
    /// reads as visually continuous with the physical notch — the
    /// notch is OLED-black, anything lighter creates a visible
    /// seam where the shoulders meet the notch.
    static let fillColor: Color = Color.black

    /// Shadow color underneath the dropdown — soft black at low
    /// opacity. The opacity is intentional; a fully-opaque shadow
    /// reads as a blocky drop rather than a shipping panel.
    static let shadowColor: Color = Color.black.opacity(0.35)

    /// Shadow blur radius. 12pt matches the visual weight of the
    /// system's own NSPopover shadow.
    static let shadowRadius: CGFloat = 12.0

    /// Shadow Y offset — pushed down so the shadow falls below the
    /// dropdown rather than haloing around it.
    static let shadowYOffset: CGFloat = 4.0

    /// Padding between the notch's lower edge and the content's
    /// top. Added on TOP of `notchHeight` (the panel's canvas top
    /// is at the screen top, behind the notch — content needs to
    /// clear the masked area). Small buffer so the title doesn't
    /// hug the notch's lower edge.
    static let contentBelowNotchPadding: CGFloat = 6.0

    /// Top padding for the non-notched fallback. No physical mask
    /// to clear, so the content sits much closer to the canvas top
    /// — just enough to not crowd the rounded corner.
    static let contentTopPaddingFallback: CGFloat = 14.0

    /// Horizontal padding inside the content. Past the shoulder
    /// curves on each side plus a small text-margin.
    static let contentHorizontalPadding: CGFloat = 14.0 + 8.0

    /// Bottom padding (notched path). Tight — the visible body
    /// already starts well below the screen top because of the
    /// notch mask, so excess bottom padding reads as wasted space.
    static let contentBottomPadding: CGFloat = 8.0

    /// Bottom padding (non-notched fallback). 4pt more than the
    /// notched path because the dropdown floats free below the
    /// menu bar — without that extra breathing room the text feels
    /// like it's hugging the rounded bottom corner.
    static let contentBottomPaddingFallback: CGFloat = 12.0

    /// Corner radius for the non-notched fallback rounded rectangle.
    /// Matches `NotchBlendShapeConstants.bottomRadius` so the bottom
    /// corners are visually consistent across the notched and
    /// non-notched paths.
    static let fallbackCornerRadius: CGFloat = 16.0
}
