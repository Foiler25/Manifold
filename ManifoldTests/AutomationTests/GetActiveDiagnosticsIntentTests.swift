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
// GetActiveDiagnosticsIntentTests.swift

import XCTest
@testable import Manifold
import ManifoldKit

@MainActor
final class GetActiveDiagnosticsIntentTests: XCTestCase {

    private var stub: StubIntentDataSource!

    override func setUp() async throws {
        try await super.setUp()
        stub = StubIntentDataSource()
        IntentEnvironment.dataSource = stub
    }

    override func tearDown() async throws {
        IntentEnvironment.dataSource = nil
        stub = nil
        try await super.tearDown()
    }

    /// Returns every active diagnostic with title + severity + detail
    /// preserved through the entity projection.
    func test_perform_returnsEveryDiagnostic() async throws {
        stub.diagnostics = [
            Diagnostic(
                target: PortID("/p1"), severity: .warning,
                ruleIdentifier: "running-at-usb-2", title: "Running @ USB 2.0",
                detail: "device is on a USB 2.0 link"
            ),
            Diagnostic(
                target: PortID("/p2"), severity: .critical,
                ruleIdentifier: "power-deficit", title: "Power deficit",
                detail: "device requests 4.5W but port supplies 2.5W"
            )
        ]
        let intent = GetActiveDiagnosticsIntent()
        let result = try await intent.perform()
        let value = try intentValue(of: result, as: [DiagnosticEntity].self)
        XCTAssertEqual(value.count, 2)
        XCTAssertEqual(value.map(\.title).sorted(), ["Power deficit", "Running @ USB 2.0"])
        XCTAssertEqual(value.first { $0.title == "Power deficit" }?.severity, "critical")
    }

    /// Empty diagnostics list → empty array.
    func test_perform_emptyDiagnostics_returnsEmptyArray() async throws {
        stub.diagnostics = []
        let intent = GetActiveDiagnosticsIntent()
        let result = try await intent.perform()
        let value = try intentValue(of: result, as: [DiagnosticEntity].self)
        XCTAssertTrue(value.isEmpty)
    }

    /// Cold-launch path (no IntentEnvironment.dataSource set) →
    /// empty array, no crash.
    func test_perform_noDataSource_returnsEmptyArray() async throws {
        IntentEnvironment.dataSource = nil
        let intent = GetActiveDiagnosticsIntent()
        let result = try await intent.perform()
        let value = try intentValue(of: result, as: [DiagnosticEntity].self)
        XCTAssertTrue(value.isEmpty)
    }
}
