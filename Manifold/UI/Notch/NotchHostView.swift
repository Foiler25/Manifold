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

    /// Notch dimensions resolved at present-time (per
    /// `NotchAnchor.notchFrame`). 0 / 0 in the no-notch fallback;
    /// `NotchBlendShape` handles the degenerate case.
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    /// Shape progress 0...1. Driven by the controller via the
    /// `withAnimation(open/close spring)` block in
    /// `NotchPanelController.show(...)` / `dismiss(...)`.
    let shapeProgress: CGFloat

    /// Content fade progress 0...1. Driven by a separate
    /// `.easeOut(duration: 0.26).delay(0.14)` so the content
    /// appears AFTER the shape opens (per SPEC §21.4).
    let contentOpacity: CGFloat

    /// Total panel canvas size. Sets the SwiftUI frame so the shape
    /// has a definite `rect` to draw into and the content view
    /// can position relative to it.
    let canvasSize: CGSize

    /// Caller-supplied content view rendered on top of the shape.
    let content: Content

    var body: some View {
        ZStack(alignment: .top) {
            NotchBlendShape(
                notchWidth: notchWidth,
                notchHeight: notchHeight,
                progress: shapeProgress
            )
            .fill(NotchHostViewConstants.fillColor)
            // Subtle shadow on the dropdown — SwiftUI draws this
            // since `NotchPanel.hasShadow == false` (the panel itself
            // is shadowless; SwiftUI handles the visual depth).
            .shadow(
                color: NotchHostViewConstants.shadowColor,
                radius: NotchHostViewConstants.shadowRadius,
                x: 0,
                y: NotchHostViewConstants.shadowYOffset
            )

            // Content sits below the notch silhouette top edge, fades
            // in via a delayed easeOut so the shoulders unfurl first.
            content
                .padding(.top, notchHeight + NotchHostViewConstants.contentTopPadding)
                .padding(.horizontal, NotchHostViewConstants.contentHorizontalPadding)
                .padding(.bottom, NotchHostViewConstants.contentBottomPadding)
                .opacity(contentOpacity)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
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
    /// Fill color of the dropdown silhouette. Pure black with high
    /// opacity reads as part of the notch on Apple silicon laptops
    /// (the physical notch area is very dark). Drives off
    /// `Color.manifoldSurface` so a Phase 15-style theming pass
    /// inherits any future palette refinement.
    static let fillColor: Color = Color.manifoldSurface

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

    /// Padding from the notch's lower edge to the content's top.
    /// 12pt keeps the title clear of the visible shoulder curve.
    static let contentTopPadding: CGFloat = 12.0

    /// Horizontal padding inside the content. 18pt gives the
    /// title + subtitle breathing room from the curved sides.
    static let contentHorizontalPadding: CGFloat = 18.0

    /// Bottom padding so the content doesn't hug the rounded
    /// bottom corners.
    static let contentBottomPadding: CGFloat = 16.0
}
