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
// HubOvercommitRuleTests.swift
//
// Per SPEC.md §9 hub-overcommit rule. Three cases: children draw
// exceeds budget (positive), children draw under budget (negative),
// no advertised budget → falls back to 4.5 W default (edge).

import XCTest
@testable import Manifold
import ManifoldKit

final class HubOvercommitRuleTests: XCTestCase {

    private let rule = HubOvercommitRule()

    /// Positive: a hub-port whose two children sum to 10 W on a port
    /// that advertises only 4.5 W → diagnostic.
    func test_positive_childrenExceedAdvertisedBudget_emitsDiagnostic() {
        let childA = DiagnosticTestFixtures.port(id: "/hub/childA", powerDrawWatts: 6.0)
        let childB = DiagnosticTestFixtures.port(id: "/hub/childB", powerDrawWatts: 4.0)
        let hub = DiagnosticTestFixtures.port(
            id: "/hub",
            availablePowerWatts: 4.5,
            children: [childA, childB]
        )
        let diagnostics = rule.evaluate(against: DiagnosticTestFixtures.host(ports: [hub]))

        let hubDiagnostics = diagnostics.filter { $0.target == hub.id }
        XCTAssertEqual(hubDiagnostics.count, 1)
        XCTAssertEqual(hubDiagnostics.first?.severity, .warning)
        XCTAssertEqual(hubDiagnostics.first?.ruleIdentifier, "hub-overcommit")
    }

    /// Negative: a hub-port whose two children sum well under the
    /// advertised budget → clean.
    func test_negative_childrenUnderBudget_isClean() {
        let childA = DiagnosticTestFixtures.port(id: "/hub/childA", powerDrawWatts: 0.5)
        let childB = DiagnosticTestFixtures.port(id: "/hub/childB", powerDrawWatts: 0.5)
        let hub = DiagnosticTestFixtures.port(
            id: "/hub",
            availablePowerWatts: 4.5,
            children: [childA, childB]
        )
        let diagnostics = rule.evaluate(against: DiagnosticTestFixtures.host(ports: [hub]))

        XCTAssertTrue(diagnostics.filter { $0.target == hub.id }.isEmpty)
    }

    /// Edge: hub doesn't advertise a budget → falls back to the
    /// 4.5 W USB 3.x default. Children summing to 5 W triggers.
    /// Pins the SPEC default-budget fallback path.
    func test_edge_nilBudgetFallsBackToUSB3Default_emitsDiagnostic() {
        let childA = DiagnosticTestFixtures.port(id: "/hub/childA", powerDrawWatts: 3.0)
        let childB = DiagnosticTestFixtures.port(id: "/hub/childB", powerDrawWatts: 2.0)
        let hub = DiagnosticTestFixtures.port(
            id: "/hub",
            availablePowerWatts: nil,
            children: [childA, childB]
        )
        let diagnostics = rule.evaluate(against: DiagnosticTestFixtures.host(ports: [hub]))

        XCTAssertEqual(diagnostics.filter { $0.target == hub.id }.count, 1)
    }

    /// Edge: leaf port (no children) is by definition not a hub.
    /// Even if its `powerDraw` is high, no hub-overcommit diagnostic.
    func test_edge_leafPortIsClean() {
        let port = DiagnosticTestFixtures.port(powerDrawWatts: 10.0, availablePowerWatts: 0.5)
        XCTAssertTrue(rule.evaluate(against: DiagnosticTestFixtures.host(ports: [port])).isEmpty)
    }
}
