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
// PowerDeficitRuleTests.swift
//
// Per SPEC.md §9 power-deficit rule. Three cases: requested >
// available (positive), requested ≤ available (negative), absent
// budget (edge — must not fire per Port.availablePower's
// "absent budget treated as infinite" doc).

import XCTest
@testable import Manifold
import ManifoldKit

final class PowerDeficitRuleTests: XCTestCase {

    private let rule = PowerDeficitRule()

    /// Positive: device requests 4.5 W on a port that only supplies
    /// 2.5 W → deficit, critical diagnostic.
    func test_positive_requestExceedsAvailable_emitsDiagnostic() {
        let port = DiagnosticTestFixtures.port(
            id: "/deficit-port",
            powerDrawWatts: 4.5,
            availablePowerWatts: 2.5
        )
        let diagnostics = rule.evaluate(against: DiagnosticTestFixtures.host(ports: [port]))

        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.target, port.id)
        XCTAssertEqual(diagnostics.first?.severity, .critical)
        XCTAssertEqual(diagnostics.first?.ruleIdentifier, "power-deficit")
    }

    /// Negative: device requests less than the port supplies. The
    /// expected steady-state for most peripherals.
    func test_negative_requestUnderAvailable_isClean() {
        let port = DiagnosticTestFixtures.port(
            powerDrawWatts: 2.5,
            availablePowerWatts: 4.5
        )
        XCTAssertTrue(rule.evaluate(against: DiagnosticTestFixtures.host(ports: [port])).isEmpty)
    }

    /// Edge: port doesn't advertise a budget. Per
    /// `Port.availablePower` doc the rule treats absent budget as
    /// "infinite" — must not fire even when requested power is high.
    func test_edge_nilAvailablePower_isClean() {
        let port = DiagnosticTestFixtures.port(
            powerDrawWatts: 100.0,
            availablePowerWatts: nil
        )
        XCTAssertTrue(rule.evaluate(against: DiagnosticTestFixtures.host(ports: [port])).isEmpty)
    }

    /// Edge: equal request and available is NOT a deficit (strict
    /// greater-than per SPEC). Pins the comparison operator.
    func test_edge_equalRequestAndAvailable_isClean() {
        let port = DiagnosticTestFixtures.port(
            powerDrawWatts: 2.5,
            availablePowerWatts: 2.5
        )
        XCTAssertTrue(rule.evaluate(against: DiagnosticTestFixtures.host(ports: [port])).isEmpty)
    }
}
