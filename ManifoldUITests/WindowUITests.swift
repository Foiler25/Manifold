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
// WindowUITests.swift
//
// Per SPEC.md §18 Phase 6 rev-5 acceptance: "XCTest UI tests for both
// flows now exist (deferred from Phase 4): … `ManifoldUITests/WindowUITests.swift`
// covers the window flow (open window → switch tabs → assert each
// tab's identifying view)."
//
// Drives the app via `XCUIApplication`. Tab buttons are queried by
// `accessibilityIdentifier` (set in `MainWindow.tabButton` —
// `window.tab.<rawValue>` per `WindowTab`). Identifying views per
// tab:
//   - Topology  → header model label (`window.topology.header.model`)
//   - History   → placeholder title (`window.tab.history.placeholder.title`)
//   - Diagnostics → empty-state title (`window.tab.diagnostics.empty.title`)
//
// On a clean Mac with no devices plugged in, the Topology tab still
// renders its header (the model summary line) — that's stable enough
// to assert against.

import XCTest

final class WindowUITests: XCTestCase {

    // MARK: - Lifecycle

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        // Stop on first failure — UI test cascades aren't useful;
        // every assertion failure points at the same root cause.
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        app = nil
        super.tearDown()
    }

    // MARK: - Window opens

    /// The WindowGroup creates the main window on launch by default.
    /// Verify it's present and reachable via XCUIApplication.
    func test_mainWindow_isPresentAfterLaunch() {
        let window = app.windows.firstMatch
        XCTAssertTrue(
            window.waitForExistence(timeout: 5),
            "Main window should appear within 5 seconds of launch."
        )
    }

    // MARK: - Tab switching

    /// Verify the three tabs exist and are clickable.
    func test_tabBar_threeTabsExist() {
        XCTAssertTrue(tabButton(.topology).waitForExistence(timeout: 5))
        XCTAssertTrue(tabButton(.history).exists)
        XCTAssertTrue(tabButton(.diagnostics).exists)
    }

    /// Default tab is Topology — verify the topology header is
    /// visible right after launch (without needing a click).
    func test_defaultTab_isTopology_withHeaderVisible() {
        let header = app.staticTexts["window.topology.header.model"]
        XCTAssertTrue(
            header.waitForExistence(timeout: 5),
            "Topology header should be visible by default — Topology is the default tab."
        )
    }

    /// Click History tab → placeholder title appears.
    func test_clickHistoryTab_showsPlaceholder() {
        guard tabButton(.history).waitForExistence(timeout: 5) else {
            return XCTFail("History tab button never appeared.")
        }
        tabButton(.history).click()

        let placeholder = app.staticTexts["window.tab.history.placeholder.title"]
        XCTAssertTrue(
            placeholder.waitForExistence(timeout: 3),
            "After clicking History tab, the Phase-10 placeholder title should be visible."
        )
    }

    /// Click Diagnostics tab → empty-state title appears.
    func test_clickDiagnosticsTab_showsEmptyState() {
        guard tabButton(.diagnostics).waitForExistence(timeout: 5) else {
            return XCTFail("Diagnostics tab button never appeared.")
        }
        tabButton(.diagnostics).click()

        let emptyTitle = app.staticTexts["window.tab.diagnostics.empty.title"]
        XCTAssertTrue(
            emptyTitle.waitForExistence(timeout: 3),
            "After clicking Diagnostics tab, the empty-state title should be visible."
        )
    }

    /// Round-trip: switch to History, then back to Topology, header
    /// re-appears. Pins the bidirectional switch path.
    func test_tabSwitch_topologyAfterHistory_restoresHeader() {
        guard tabButton(.history).waitForExistence(timeout: 5) else {
            return XCTFail("History tab button never appeared.")
        }
        tabButton(.history).click()
        _ = app.staticTexts["window.tab.history.placeholder.title"].waitForExistence(timeout: 3)

        tabButton(.topology).click()
        let header = app.staticTexts["window.topology.header.model"]
        XCTAssertTrue(
            header.waitForExistence(timeout: 3),
            "Topology header should reappear after switching back from History."
        )
    }

    // MARK: - Helpers

    /// Look up a tab button by `WindowTab` raw value, matching the
    /// identifier `MainWindow.tabButton` sets via
    /// `.accessibilityIdentifier("window.tab.\(tab.rawValue)")`.
    private func tabButton(_ tab: TabKind) -> XCUIElement {
        app.buttons["window.tab.\(tab.rawValue)"]
    }

    /// Mirror of `Manifold.WindowTab` — duplicated here because UI
    /// tests run in a separate target that can't `@testable import
    /// Manifold` (UI tests don't link the host app).
    private enum TabKind: String {
        case topology
        case history
        case diagnostics
    }
}
