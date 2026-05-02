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
// CableBottleneckRuleTests.swift
//
// Per SPEC.md §9 cable-bottleneck rule. Three cases: TB port linked
// at TB3 (positive), TB port linked at TB4 (negative — full speed),
// USB-C port linked at TB3-equivalent string (edge — wrong port
// kind, must not fire).

import XCTest
@testable import Manifold
import ManifoldKit

final class CableBottleneckRuleTests: XCTestCase {

    private let rule = CableBottleneckRule()

    /// Positive: TB port currently linked at Thunderbolt 3 → cable
    /// or device can negotiate higher than current state. Diagnostic
    /// emitted at warning severity.
    func test_positive_tbPortLinkedAtTB3_emitsDiagnostic() {
        let port = DiagnosticTestFixtures.port(
            id: "/tb-port",
            kind: .thunderbolt,
            protocolName: "Thunderbolt 3"
        )
        let diagnostics = rule.evaluate(against: DiagnosticTestFixtures.host(ports: [port]))

        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.target, port.id)
        XCTAssertEqual(diagnostics.first?.severity, .warning)
        XCTAssertEqual(diagnostics.first?.ruleIdentifier, "cable-bottleneck")
    }

    /// Negative: TB port linked at Thunderbolt 4 — the device is
    /// hitting full available speed, no diagnostic.
    func test_negative_tbPortLinkedAtTB4_isClean() {
        let port = DiagnosticTestFixtures.port(
            kind: .thunderbolt,
            protocolName: "Thunderbolt 4"
        )
        XCTAssertTrue(rule.evaluate(against: DiagnosticTestFixtures.host(ports: [port])).isEmpty)
    }

    /// Edge: a USB-C port string-named "Thunderbolt 3" should NOT
    /// fire — the rule only considers ports whose kind is
    /// `.thunderbolt`. Pins the kind-gate so future protocolName
    /// label changes don't accidentally widen the rule's scope.
    func test_edge_usbCPortWithTB3LabelIsIgnored() {
        let port = DiagnosticTestFixtures.port(
            kind: .usbC,
            protocolName: "Thunderbolt 3"
        )
        XCTAssertTrue(rule.evaluate(against: DiagnosticTestFixtures.host(ports: [port])).isEmpty)
    }

    /// Edge: empty TB port (no connected device) is not a complaint.
    func test_edge_emptyTBPortIsClean() {
        let port = DiagnosticTestFixtures.port(
            kind: .thunderbolt,
            device: nil,
            protocolName: "Thunderbolt 3"
        )
        XCTAssertTrue(rule.evaluate(against: DiagnosticTestFixtures.host(ports: [port])).isEmpty)
    }
}
