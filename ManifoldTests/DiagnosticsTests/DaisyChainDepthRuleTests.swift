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
// DaisyChainDepthRuleTests.swift
//
// Per SPEC.md §9 daisy-chain-depth rule. Three cases: 7-deep chain
// (positive), 6-deep chain (negative — exactly at the spec limit),
// 1-deep chain (edge — leaf).

import XCTest
@testable import Manifold
import ManifoldKit

final class DaisyChainDepthRuleTests: XCTestCase {

    private let rule = DaisyChainDepthRule()

    /// Build a single linear chain of `depth` ports nested by
    /// `children`. The host-rooted port is at depth 1; the leaf at
    /// depth `depth`.
    private func linearChain(depth: Int) -> ManifoldKit.Port {
        var node = DiagnosticTestFixtures.port(id: "/chain/leaf", children: [])
        for i in (0..<(depth - 1)).reversed() {
            node = DiagnosticTestFixtures.port(id: "/chain/\(i)", children: [node])
        }
        return node
    }

    /// Positive: a 7-deep chain rooted at one host port → one
    /// diagnostic targeting the root.
    func test_positive_sevenDeepChain_emitsDiagnostic() {
        let root = linearChain(depth: 7)
        let diagnostics = rule.evaluate(against: DiagnosticTestFixtures.host(ports: [root]))

        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.target, root.id)
        XCTAssertEqual(diagnostics.first?.severity, .critical)
        XCTAssertEqual(diagnostics.first?.ruleIdentifier, "daisy-chain-depth")
    }

    /// Negative: a 6-deep chain is exactly at the TB spec limit and
    /// must NOT trigger. Pins the strict-greater-than comparison
    /// (off-by-one in either direction breaks the rule).
    func test_negative_sixDeepChain_isClean() {
        let root = linearChain(depth: 6)
        XCTAssertTrue(rule.evaluate(against: DiagnosticTestFixtures.host(ports: [root])).isEmpty)
    }

    /// Edge: single host-rooted port (depth 1, no children). No
    /// diagnostic. Verifies the rule doesn't accidentally double-count
    /// the root.
    func test_edge_singlePortIsClean() {
        let port = DiagnosticTestFixtures.port()
        XCTAssertTrue(rule.evaluate(against: DiagnosticTestFixtures.host(ports: [port])).isEmpty)
    }
}
