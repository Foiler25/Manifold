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
// ─────────────────────────────────────────────────────────────────────
// NotchAnchorTests.swift
//
// Phase 19 — pure-geometry tests for `NotchAnchor.compute(...)`.
// Doesn't call `NSScreen.main` or `NotchAnchor.resolve()` — runs the
// math against synthetic CGRect inputs so a non-notched CI Mac can
// still pin the spec contract.

import XCTest
import AppKit
@testable import Manifold

final class NotchAnchorTests: XCTestCase {

    // MARK: - Notched path

    func test_notchedScreen_yieldsHasNotchTrueAndComputesFrame() {
        // Synthetic 1512x982 screen with auxiliary areas that
        // sandwich a 200pt-wide / 36pt-tall notch in the middle.
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let leftAux = CGRect(x: 0, y: 946, width: 656, height: 36)
        let rightAux = CGRect(x: 856, y: 946, width: 656, height: 36)

        let geometry = NotchAnchor.compute(
            left: leftAux,
            right: rightAux,
            screenFrame: screenFrame
        )

        XCTAssertTrue(geometry.hasNotch)
        XCTAssertEqual(geometry.notchFrame.width, 200, accuracy: 0.01)
        XCTAssertEqual(geometry.notchFrame.height, 36, accuracy: 0.01)
        // Notch sits at top of screen (origin bottom-left), so
        // notchFrame.minY == screenFrame.maxY - notchHeight = 946.
        XCTAssertEqual(geometry.notchFrame.minY, 946, accuracy: 0.01)
        XCTAssertEqual(geometry.notchFrame.minX, 656, accuracy: 0.01)
    }

    func test_notchedScreen_withDifferentLeftRightHeights_picksMax() {
        // Edge case: the OS reports slightly different heights for
        // the two auxiliary areas. We use max() so the notch height
        // covers both.
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let left = CGRect(x: 0, y: 950, width: 656, height: 32)
        let right = CGRect(x: 856, y: 946, width: 656, height: 36)

        let geometry = NotchAnchor.compute(
            left: left,
            right: right,
            screenFrame: screenFrame
        )

        XCTAssertTrue(geometry.hasNotch)
        XCTAssertEqual(geometry.notchFrame.height, 36, accuracy: 0.01,
                       "Should pick the larger of the two heights")
    }

    // MARK: - Non-notched path

    func test_bothAuxiliaryAreasNil_returnsHasNotchFalse() {
        // M1 Air, external display, lid-closed clamshell — both
        // auxiliary areas are nil.
        let screenFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let geometry = NotchAnchor.compute(
            left: nil,
            right: nil,
            screenFrame: screenFrame
        )
        XCTAssertFalse(geometry.hasNotch)
        XCTAssertEqual(geometry.notchFrame, .zero)
    }

    func test_oneAuxiliaryNil_returnsHasNotchFalse() {
        // Defensive case — if the OS only reports one side, treat
        // as no-notch rather than guess at the missing geometry.
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let left = CGRect(x: 0, y: 946, width: 656, height: 36)

        let geometry = NotchAnchor.compute(
            left: left,
            right: nil,
            screenFrame: screenFrame
        )
        XCTAssertFalse(geometry.hasNotch)
    }

    func test_zeroWidthGap_returnsHasNotchFalse() {
        // Pathological case where the two aux areas touch — the
        // gap between them is below the minimum-width threshold
        // (1pt) so we treat as no-notch.
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let left = CGRect(x: 0, y: 946, width: 756, height: 36)
        let right = CGRect(x: 756, y: 946, width: 756, height: 36)

        let geometry = NotchAnchor.compute(
            left: left,
            right: right,
            screenFrame: screenFrame
        )
        XCTAssertFalse(geometry.hasNotch,
                       "0pt gap should fall below the threshold")
    }

    func test_negativeGap_returnsHasNotchFalse() {
        // Pathological case where left.maxX > right.minX (overlap)
        // — gap is negative, well below the threshold.
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let left = CGRect(x: 0, y: 946, width: 800, height: 36)
        let right = CGRect(x: 700, y: 946, width: 700, height: 36)

        let geometry = NotchAnchor.compute(
            left: left,
            right: right,
            screenFrame: screenFrame
        )
        XCTAssertFalse(geometry.hasNotch)
    }

    // MARK: - Bezier control point spot-check

    func test_notchFrame_minXEqualsLeftMaxX() {
        // Per SPEC §21.2 "compute" comment: notchX = left.maxX.
        // Spot-check this invariant against a synthetic screen.
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let left = CGRect(x: 0, y: 870, width: 620, height: 30)
        let right = CGRect(x: 820, y: 870, width: 620, height: 30)

        let geometry = NotchAnchor.compute(
            left: left,
            right: right,
            screenFrame: screenFrame
        )
        XCTAssertEqual(geometry.notchFrame.minX, left.maxX, accuracy: 0.01)
        XCTAssertEqual(geometry.notchFrame.maxX, right.minX, accuracy: 0.01)
    }
}
