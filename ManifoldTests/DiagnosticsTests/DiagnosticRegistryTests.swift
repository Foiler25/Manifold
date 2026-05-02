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
// DiagnosticRegistryTests.swift
//
// Verifies the §9 registry: register stores rules in order;
// evaluateAll concatenates per-rule output; the SPEC §18 Phase 8
// "All 5 rules registered" acceptance is checkable mechanically via
// `phase8Registry().rules.count`.

import XCTest
@testable import Manifold
import ManifoldKit

@MainActor
final class DiagnosticRegistryTests: XCTestCase {

    /// Phase 8 acceptance criterion #2: all 5 SPEC §9 rules are
    /// registered in `phase8Registry()`.
    func test_phase8Registry_registersAll5Rules() {
        let registry = DiagnosticRegistry.phase8Registry()
        let identifiers = Set(registry.rules.map(\.identifier))
        XCTAssertEqual(identifiers, [
            "running-at-usb-2",
            "power-deficit",
            "cable-bottleneck",
            "daisy-chain-depth",
            "hub-overcommit"
        ])
    }

    /// `evaluateAll` concatenates each rule's output. Two rules that
    /// both fire on the same input should produce two diagnostics
    /// (one per rule). Pins the "no implicit dedup at the registry
    /// level" contract — dedup is PortGraph.applyDiagnostic's job.
    func test_evaluateAll_concatenatesPerRuleOutput() {
        let registry = DiagnosticRegistry()
        registry.register(USB2OnUSB3DeviceRule())
        registry.register(PowerDeficitRule())

        // Port that triggers BOTH rules: USB3 device on USB 2.0 link
        // AND request 5 W with 1 W available.
        let port = DiagnosticTestFixtures.port(
            id: "/dual-trigger",
            device: DiagnosticTestFixtures.device(usbVersion: .usb3_0),
            protocolName: "USB 2.0",
            powerDrawWatts: 5.0,
            availablePowerWatts: 1.0
        )

        let diagnostics = registry.evaluateAll(against: DiagnosticTestFixtures.host(ports: [port]))
        XCTAssertEqual(diagnostics.count, 2)
        let identifiers = Set(diagnostics.map(\.ruleIdentifier))
        XCTAssertEqual(identifiers, ["running-at-usb-2", "power-deficit"])
    }

    /// Empty graph → no diagnostics. The simplest sanity check; pins
    /// the "no rules ever fire on an empty input" guarantee.
    func test_evaluateAll_emptyGraph_returnsEmpty() {
        let registry = DiagnosticRegistry.phase8Registry()
        XCTAssertTrue(registry.evaluateAll(against: []).isEmpty)
    }
}
