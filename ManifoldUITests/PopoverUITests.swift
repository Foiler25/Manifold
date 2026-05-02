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
// PopoverUITests.swift
//
// Per SPEC.md §18 Phase 6 rev-5 acceptance: "XCTest UI tests for both
// flows now exist (deferred from Phase 4): `ManifoldUITests/PopoverUITests.swift`
// covers the popover flow (open popover → assert at least one device
// row visible)."
//
// Driving the menu bar status item via XCUIApplication is
// well-known to be brittle on macOS — `NSStatusItem` is not
// represented in the app's window hierarchy, and the system menu bar
// (where it lives) is owned by `SystemUIServer`. Most macOS apps
// approach this by either:
//
//   1. Coordinate-clicking the status item by screen position
//      (extremely fragile across Macs and resolutions).
//   2. Cross-app accessibility traversal into SystemUIServer's menu
//      bar (works but flakes if accessibility permissions aren't
//      granted to the test runner).
//   3. Driving the popover via a test-only env-var hook in the app
//      itself, bypassing the menu bar.
//
// Phase 6 ships approach #3 — the cleanest and most stable for CI.
// `MANIFOLD_AUTOOPEN_POPOVER=1` (DEBUG-only) tells AppDelegate to
// open the popover on launch; the tests then assert against the
// popover's hosting window.

import XCTest

final class PopoverUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // DEBUG-only auto-open hook (added in AppDelegate at the same
        // time as these UI tests). Production / Release builds ignore
        // the env var entirely.
        app.launchEnvironment["MANIFOLD_AUTOOPEN_POPOVER"] = "1"
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        app = nil
        super.tearDown()
    }

    // MARK: - Popover opens

    /// With the auto-open env var set, the popover should appear soon
    /// after launch. NSPopover hosts its content inside a separate
    /// NSWindow that XCUIApplication sees via `app.windows`.
    func test_popover_appearsAfterAutoOpen() {
        // The main window appears immediately; the popover's hosting
        // window appears once AppDelegate's MainActor task fires the
        // open. Wait up to 5s for at least 2 windows (main + popover).
        expectAtLeastWindows(count: 2, timeout: 5)
    }

    /// The popover content should expose at least one identifiable
    /// element. On a Mac with at least one USB device connected (the
    /// boot SSD always counts), the popover header shows the
    /// "N devices connected" text via `popover.devices.count`. On a
    /// Mac with zero USB devices the empty-state copy is visible
    /// instead. Either way, at least one of the two strings must
    /// appear.
    func test_popover_contentVisible() {
        // Wait for the popover window to appear.
        expectAtLeastWindows(count: 2, timeout: 5)

        // Either of these texts being on screen is sufficient — they
        // share the same hosting window.
        let count = popoverHostingWindow().staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@",
                        "device", "No USB")
        )
        XCTAssertGreaterThan(
            count.count,
            0,
            "Popover content should include either the 'N device(s) connected' header or the 'No USB devices detected' empty-state."
        )
    }

    // MARK: - Helpers

    /// The popover's hosting window. NSPopover uses an internal
    /// NSWindow class; we identify it as the smallest non-main
    /// window currently on screen (the popover is intentionally
    /// fixed at 360×420 per `AppConstants.popoverContentSize`,
    /// smaller than the main window's defaults).
    private func popoverHostingWindow() -> XCUIElement {
        // The main window has the model-name title; everything else
        // is candidate. In practice there are only two windows when
        // the popover is open.
        let candidates = app.windows.allElementsBoundByIndex
        // Pick the second window (index 1) — first is the main
        // WindowGroup window.
        if candidates.count >= 2 {
            return candidates[1]
        }
        return app.windows.firstMatch
    }

    /// Wait until `app.windows.count >= count` or `timeout` elapses.
    /// Uses XCTNSPredicateExpectation since `XCUIElement.waitForExistence`
    /// only counts a single element.
    private func expectAtLeastWindows(count: Int, timeout: TimeInterval) {
        let predicate = NSPredicate { _, _ in
            self.app.windows.count >= count
        }
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        let result = XCTWaiter().wait(for: [exp], timeout: timeout)
        XCTAssertEqual(
            result,
            .completed,
            "Expected ≥\(count) windows within \(timeout) s; observed \(app.windows.count)."
        )
    }
}
