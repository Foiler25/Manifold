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
// Phase 19 — SwiftUI `Shape` rendering the notch-flush dropdown
// silhouette. Independently re-derived from the geometric description
// in SPEC §21.3:
//
//   - **Top edge** straight, flush against the physical notch (or
//     the screen-top in the no-notch fallback).
//   - **Shoulders** quadratic Bézier curves that sweep concave from
//     the inset of the notch width out to the canvas edge. Effective
//     shoulder radius ~14pt — the control point sits at the corner
//     where the notch's vertical edge would meet the panel's top
//     plane, producing the "blended into the notch" look.
//   - **Bottom corners** rounded with radius ~16pt — standard
//     rounded-rectangle bottom geometry.
//
// Math (independently derived, not transcribed):
//   Place the notch on the top edge of the canvas, centered. Let
//   `nw = notchWidth`, `nh = notchHeight`, `W = rect.width`, `H =
//   rect.height`, `s = NotchBlendShapeConstants.shoulderRadius`,
//   `b = NotchBlendShapeConstants.bottomRadius`. The notch span
//   on the top edge runs from `xL = (W - nw) / 2` to `xR = (W + nw) / 2`.
//
//   The shoulder anchor on the top edge is `(xL, nh)` (the
//   notch's lower-inner corner) and the shoulder anchor on the
//   left vertical face of the canvas is `(xL - s, nh + s)`. The
//   quadratic Bézier control point is `(xL, nh + s)` — i.e., the
//   right-angle corner the notch would terminate in if there were no
//   curve. Sweeping from `(xL, nh)` through that control to
//   `(xL - s, nh + s)` produces a concave curve that meets the
//   notch edge tangentially. The right shoulder mirrors.
//
// `progress` interpolates the shape from "closed pill" (height = 0,
// width = notchWidth) to "open dropdown" (full geometry). SwiftUI's
// `animatableData` drives the spring (SPEC §21.4).

import SwiftUI

/// Notch-flush dropdown shape. Pure geometry — no animation logic
/// here; the panel controller drives `progress` via `.animation(...)`.
struct NotchBlendShape: Shape {

    /// Width of the physical notch in points. Pulled from
    /// `NotchAnchor.notchFrame.width` by the controller. Set to 0
    /// for the non-notched fallback (per SPEC §21.12 — the path
    /// implementation handles `notchWidth == 0` as a degenerate
    /// case rendering a plain rounded rectangle without shoulders).
    var notchWidth: CGFloat

    /// Height of the physical notch — the offset of the panel's
    /// straight top edge below the screen's true top. Always reads
    /// the notch's `auxiliaryTopLeftArea.height`-style value, never
    /// hardcoded.
    var notchHeight: CGFloat

    /// 0 = closed (off-screen / pill); 1 = open (full dropdown).
    /// SwiftUI interpolates this for the open/close springs.
    var progress: CGFloat

    /// Animatable data — single CGFloat so SwiftUI's spring driver
    /// can interpolate. `progress` is the only animatable input;
    /// notch dimensions are screen-dependent and don't change
    /// mid-animation.
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let p = max(0, min(1, progress))

        // Effective panel height + width: at progress=0 the canvas
        // collapses to a thin pill matching the notch dimensions; at
        // progress=1 the canvas expands to the full rect.
        let liveHeight = rect.height * p
        // Width interpolates from notchWidth to rect.width. When
        // notchWidth is 0 (no-notch fallback), this becomes a plain
        // rounded-rect from a 0-width line to full width.
        let liveWidth = notchWidth + (rect.width - notchWidth) * p
        // Center the live shape horizontally in the canvas — keeps
        // the notch centered + the shoulders mirroring left/right.
        let leftEdge = (rect.width - liveWidth) / 2
        let rightEdge = leftEdge + liveWidth

        // Constants
        let shoulderRadius = NotchBlendShapeConstants.shoulderRadius
        let bottomRadius = NotchBlendShapeConstants.bottomRadius

        // Notch span — clamp to the live width so a hugely wide notch
        // value never overflows the panel.
        let notchSpan = min(notchWidth, liveWidth)
        let xL = leftEdge + (liveWidth - notchSpan) / 2
        let xR = xL + notchSpan

        // Top edge Y (notch's lower edge / panel top under the notch).
        // When notchHeight is 0 (no-notch fallback) this is just 0 →
        // the path's top edge sits at rect.minY.
        let topY: CGFloat = notchHeight

        // Bottom edge Y (clamped to liveHeight so the shape collapses
        // cleanly at progress=0).
        let bottomY = max(topY, liveHeight)

        // Path traversal — clockwise starting from the notch's
        // lower-left inner corner.
        //
        //   • Move to (xL, topY)
        //   • Top straight under the notch  → (xR, topY)
        //   • Right shoulder Bézier         → (rightEdge, topY + shoulderRadius)
        //   • Right vertical down           → (rightEdge, bottomY - bottomRadius)
        //   • Right bottom corner Bézier    → (rightEdge - bottomRadius, bottomY)
        //   • Bottom straight               → (leftEdge + bottomRadius, bottomY)
        //   • Left bottom corner Bézier     → (leftEdge, bottomY - bottomRadius)
        //   • Left vertical up              → (leftEdge, topY + shoulderRadius)
        //   • Left shoulder Bézier          → (xL, topY)
        //   • Close

        path.move(to: CGPoint(x: xL, y: topY))
        path.addLine(to: CGPoint(x: xR, y: topY))

        // Right shoulder — Bézier from notch corner to canvas edge.
        // Control point at (xR + shoulderRadius, topY) — the
        // right-angle corner the notch's vertical edge would meet.
        // The quadratic curves naturally meet the notch tangentially.
        let rightShoulderEnd = CGPoint(
            x: min(xR + shoulderRadius, rightEdge),
            y: topY + shoulderRadius
        )
        let rightShoulderControl = CGPoint(
            x: min(xR + shoulderRadius, rightEdge),
            y: topY
        )
        path.addQuadCurve(
            to: rightShoulderEnd,
            control: rightShoulderControl
        )

        // Right vertical down to where the bottom corner begins.
        path.addLine(
            to: CGPoint(x: rightEdge, y: max(rightShoulderEnd.y, bottomY - bottomRadius))
        )

        // Right bottom corner.
        path.addQuadCurve(
            to: CGPoint(x: rightEdge - bottomRadius, y: bottomY),
            control: CGPoint(x: rightEdge, y: bottomY)
        )

        // Bottom straight.
        path.addLine(to: CGPoint(x: leftEdge + bottomRadius, y: bottomY))

        // Left bottom corner.
        path.addQuadCurve(
            to: CGPoint(x: leftEdge, y: bottomY - bottomRadius),
            control: CGPoint(x: leftEdge, y: bottomY)
        )

        // Left vertical up.
        let leftShoulderEnd = CGPoint(
            x: max(xL - shoulderRadius, leftEdge),
            y: topY + shoulderRadius
        )
        path.addLine(to: leftShoulderEnd)

        // Left shoulder — mirror of the right shoulder. Control at
        // (xL - shoulderRadius, topY).
        let leftShoulderControl = CGPoint(
            x: max(xL - shoulderRadius, leftEdge),
            y: topY
        )
        path.addQuadCurve(
            to: CGPoint(x: xL, y: topY),
            control: leftShoulderControl
        )

        path.closeSubpath()
        return path
    }
}

// MARK: - Constants

enum NotchBlendShapeConstants {
    /// Shoulder Bézier radius. ~14pt produces the "blended" sweep
    /// from the notch's vertical edge out to the panel's edge,
    /// matching the visual rhythm of the macOS Dynamic-Island-style
    /// notch overlays the user already sees in macOS's own UI.
    /// Pulled from SPEC §21.3.
    static let shoulderRadius: CGFloat = 14.0

    /// Bottom corner radius. ~16pt matches the proportion the
    /// system uses on similar overlay surfaces (NSPopover, etc.) so
    /// the dropdown reads as part of the same visual family.
    static let bottomRadius: CGFloat = 16.0
}
