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
// NotchBlendShape.swift
//
// Phase 19 — SwiftUI `Shape` rendering the notch-flush dropdown.
//
// The shape is intentionally simple. The animation does not happen
// inside the shape — it happens at the SwiftUI frame level, where
// the containing view's width and height are interpolated by a
// spring. This shape just draws the canonical silhouette in
// whatever rect it's given.
//
// Silhouette (in SwiftUI top-left coordinates, where +y goes down):
//
//   • Top edge straight, sitting at `rect.minY`. The caller positions
//     the panel so this edge lines up with the notch's *lower* edge —
//     the canvas's top-left and top-right corners therefore sit at
//     the notch's lower-outer corners, producing the visual
//     continuation that reads as "unfurling from the notch".
//   • Top corners are CONCAVE quarter-ellipses sweeping inward and
//     downward. Each corner curves from `(rect.{minX,maxX}, rect.minY)`
//     to `(rect.{minX+s, maxX-s}, rect.minY + s)`, where
//     `s = shoulderRadius`. The control point sits at the right-angle
//     corner so the curve meets the canvas top edge tangentially.
//   • Body sides are straight verticals from the shoulder anchors
//     down to the bottom rounded corners.
//   • Bottom corners are CONVEX rounded corners with radius `b =
//     bottomRadius`.
//
// As the caller animates the rect from `(notchWidth, 0)` to
// `(fullWidth, fullHeight)`, the shape unfurls from a thin pill
// flush with the notch's lower edge into the full dropdown.

import SwiftUI

/// Notch-flush dropdown shape. Pure geometry — no animation logic
/// here; the panel controller drives unfurling via the containing
/// view's `.frame` modifier inside `withAnimation`.
struct NotchBlendShape: Shape {

    /// Quarter-ellipse radius for the concave top corners. The
    /// horizontal span of each shoulder is `min(shoulderRadius,
    /// rect.width / 2)`; the vertical span is the same value
    /// clamped to `rect.height`. Set this small (≈ 14pt) for a
    /// tight tuck that reads as continuous with the notch's lower
    /// corners.
    var shoulderRadius: CGFloat

    /// Quarter-ellipse radius for the convex bottom corners. ≈ 16pt
    /// matches the system's NSPopover-style bottom rounding.
    var bottomRadius: CGFloat

    /// Animatable so the corner radii can themselves be tweened if
    /// the caller ever wants to morph between two shape variants.
    /// In the current pipeline the radii stay constant and the
    /// containing view's frame is what animates.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulderRadius, bottomRadius) }
        set {
            shoulderRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        // Clamp the radii so they can never overlap each other or
        // exceed half the available width / height. Without this the
        // path produces self-intersecting curves at very small
        // animated frames.
        let s = max(0, min(min(rect.width / 2, rect.height), shoulderRadius))
        let bMaxX = max(0, (rect.width - 2 * s) / 2)
        let bMaxY = max(0, rect.height - s)
        let b = max(0, min(min(bMaxX, bMaxY), bottomRadius))

        var path = Path()

        // Move to the canvas's top-left corner. The caller positions
        // the panel so this lands at the notch's lower-left corner.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Left concave shoulder: top-left corner curves inward to
        // (s, s). Control at (s, 0) — the right-angle corner the
        // notch's vertical edge would meet if extrapolated, which
        // gives a smooth quarter-ellipse tangential to both the
        // canvas top and the body's left vertical.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + s, y: rect.minY + s),
            control: CGPoint(x: rect.minX + s, y: rect.minY)
        )

        // Body left vertical down to the bottom-left corner anchor.
        path.addLine(
            to: CGPoint(x: rect.minX + s, y: rect.maxY - b)
        )

        // Bottom-left convex rounded corner.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + s + b, y: rect.maxY),
            control: CGPoint(x: rect.minX + s, y: rect.maxY)
        )

        // Bottom edge straight across.
        path.addLine(
            to: CGPoint(x: rect.maxX - s - b, y: rect.maxY)
        )

        // Bottom-right convex rounded corner.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - s, y: rect.maxY - b),
            control: CGPoint(x: rect.maxX - s, y: rect.maxY)
        )

        // Body right vertical up to the top-right shoulder anchor.
        path.addLine(
            to: CGPoint(x: rect.maxX - s, y: rect.minY + s)
        )

        // Right concave shoulder: mirror of the left one. Control at
        // (rect.maxX - s, rect.minY) so the curve sweeps from the
        // body's top edge out to the canvas's top-right corner.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - s, y: rect.minY)
        )

        // Close the canvas top edge back to the start.
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()

        return path
    }
}

// MARK: - Constants

enum NotchBlendShapeConstants {
    /// Default shoulder radius — concave top corner sweep. Tight
    /// (~14pt) so the curve reads as a continuation of the notch's
    /// lower-corner rounding rather than a separate scoop.
    static let shoulderRadius: CGFloat = 14.0

    /// Default bottom corner radius. ~16pt matches the system's
    /// NSPopover-style overlay vocabulary.
    static let bottomRadius: CGFloat = 16.0
}
