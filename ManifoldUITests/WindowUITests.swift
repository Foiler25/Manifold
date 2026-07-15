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
//   - Battery → populated or empty-state root
//   - Cables → cable diagnostics root
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
        // Manifold is a menu-bar app in normal use. This DEBUG-only
        // hook presents the standalone window deterministically.
        app.launchEnvironment["MANIFOLD_AUTOOPEN_WINDOW"] = "1"
        // Keep first-launch onboarding from covering the tab bar.
        app.launchArguments += ["-settings.onboarding.completed", "YES"]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        app = nil
        super.tearDown()
    }

    // MARK: - Window opens

    /// The DEBUG launch hook creates the main window on demand.
    func test_mainWindow_isPresentAfterLaunch() {
        let window = app.windows.firstMatch
        XCTAssertTrue(
            window.waitForExistence(timeout: 5),
            "Main window should appear within 5 seconds of launch."
        )
    }

    // MARK: - Tab switching

    /// Verify all current tabs exist and are clickable.
    func test_tabBar_allTabsExist() {
        XCTAssertTrue(tabButton(.topology).waitForExistence(timeout: 5))
        XCTAssertTrue(tabButton(.history).exists)
        XCTAssertTrue(tabButton(.diagnostics).exists)
        XCTAssertTrue(tabButton(.battery).exists)
        XCTAssertTrue(tabButton(.cables).exists)
        XCTAssertTrue(tabButton(.power).exists)
        XCTAssertTrue(tabButton(.negotiation).exists)
        XCTAssertTrue(tabButton(.display).exists)
    }

    /// Default tab is Topology — verify the topology header is
    /// visible right after launch (without needing a click).
    func test_defaultTab_isTopology_withHeaderVisible() {
        let header = element(identifier: "window.topology.header.model")
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

        let placeholder = element(identifier: "window.tab.history.root")
        XCTAssertTrue(
            placeholder.waitForExistence(timeout: 3),
            "After clicking History, the history view should be visible."
        )
    }

    /// Click Diagnostics tab → empty-state title appears.
    func test_clickDiagnosticsTab_showsEmptyState() {
        guard tabButton(.diagnostics).waitForExistence(timeout: 5) else {
            return XCTFail("Diagnostics tab button never appeared.")
        }
        tabButton(.diagnostics).click()

        let emptyTitle = element(identifier: "window.tab.diagnostics.root")
        XCTAssertTrue(
            emptyTitle.waitForExistence(timeout: 3),
            "After clicking Diagnostics, the diagnostics view should be visible."
        )
    }

    /// Click Cables tab → the re-synced cable diagnostics UI renders.
    func test_clickCablesTab_showsCableDiagnostics() {
        guard tabButton(.cables).waitForExistence(timeout: 5) else {
            return XCTFail("Cables tab button never appeared.")
        }
        tabButton(.cables).click()

        let cablesRoot = element(identifier: "window.tab.cables.populated")
        XCTAssertTrue(
            cablesRoot.waitForExistence(timeout: 5),
            "After clicking Cables, the cable diagnostics view should be visible."
        )
    }

    func test_proTabsRenderAndPowerDetaches() {
        let screens: [(TabKind, String)] = [
            (.power, "window.tab.power.root"),
            (.negotiation, "window.tab.negotiation.root"),
            (.display, "window.tab.display.root")
        ]
        for (tab, identifier) in screens {
            XCTAssertTrue(tabButton(tab).waitForExistence(timeout: 5))
            tabButton(tab).click()
            XCTAssertTrue(element(identifier: identifier).waitForExistence(timeout: 5))
        }

        tabButton(.power).click()
        let detach = element(identifier: "proScreen.detach.power")
        XCTAssertTrue(detach.waitForExistence(timeout: 5))
        detach.click()
        XCTAssertTrue(
            element(identifier: "proScreen.window.power").waitForExistence(timeout: 5),
            "Detached Power Monitor window should render the shared power screen."
        )
    }

    /// Round-trip: switch to History, then back to Topology, header
    /// re-appears. Pins the bidirectional switch path.
    func test_tabSwitch_topologyAfterHistory_restoresHeader() {
        guard tabButton(.history).waitForExistence(timeout: 5) else {
            return XCTFail("History tab button never appeared.")
        }
        tabButton(.history).click()
        _ = element(identifier: "window.tab.history.root").waitForExistence(timeout: 3)

        tabButton(.topology).click()
        let header = element(identifier: "window.topology.header.model")
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
        element(identifier: "window.tab.\(tab.rawValue)")
    }

    /// Query by stable identifier without coupling tests to the tab
    /// control's accessibility element type.
    private func element(identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Mirror of `Manifold.WindowTab` — duplicated here because UI
    /// tests run in a separate target that can't `@testable import
    /// Manifold` (UI tests don't link the host app).
    private enum TabKind: String {
        case topology
        case history
        case diagnostics
        case battery
        case cables
        case power = "powerMonitorV2"
        case negotiation
        case display
    }
}
