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
// GetPowerDrawIntentTests.swift
//
// Pin SPEC §11.2: returns Measurement<UnitPower> with watts unit.
// Three cases: total sum, host filter, device filter.

import XCTest
@testable import Manifold
import ManifoldKit

@MainActor
final class GetPowerDrawIntentTests: XCTestCase {

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

    /// No filter → sum across every port's powerDraw.
    func test_perform_totalSum_acrossEveryPort() async throws {
        stub.hosts = [
            IntentTestFixtures.host(ports: [
                IntentTestFixtures.port(id: "/p1", device: IntentTestFixtures.device(name: "A"), powerDraw: Watts(1.5)),
                IntentTestFixtures.port(id: "/p2", device: IntentTestFixtures.device(name: "B"), powerDraw: Watts(0.5))
            ])
        ]
        let intent = GetPowerDrawIntent()
        let result = try await intent.perform()
        let value = try intentValue(of: result, as: Measurement<UnitPower>.self)
        XCTAssertEqual(value.value, 2.0, accuracy: 0.001)
        XCTAssertEqual(value.unit, .watts)
    }

    /// Host filter → only ports on matching host contribute.
    func test_perform_hostFilter_sumsOnlyMatchingHost() async throws {
        stub.hosts = [
            IntentTestFixtures.host(id: "h1", ports: [
                IntentTestFixtures.port(id: "/p1", device: IntentTestFixtures.device(name: "A"), powerDraw: Watts(1.0))
            ]),
            IntentTestFixtures.host(id: "h2", ports: [
                IntentTestFixtures.port(id: "/p2", device: IntentTestFixtures.device(name: "B"), powerDraw: Watts(99.0))
            ])
        ]
        let intent = GetPowerDrawIntent()
        intent.host = HostEntity(host: stub.hosts[0])  // h1 only
        let result = try await intent.perform()
        let value = try intentValue(of: result, as: Measurement<UnitPower>.self)
        XCTAssertEqual(value.value, 1.0, accuracy: 0.001)
    }

    /// Device filter → only the port whose connectedDevice matches
    /// contributes. Pins the per-device read used by Shortcuts to
    /// monitor a single device's draw.
    func test_perform_deviceFilter_sumsOnlyMatchingDevice() async throws {
        let target = IntentTestFixtures.device(name: "Target")
        let other  = IntentTestFixtures.device(name: "Other")
        stub.hosts = [
            IntentTestFixtures.host(ports: [
                IntentTestFixtures.port(id: "/p1", device: target, powerDraw: Watts(2.5)),
                IntentTestFixtures.port(id: "/p2", device: other,  powerDraw: Watts(99.0))
            ])
        ]
        let intent = GetPowerDrawIntent()
        intent.device = DeviceEntity(device: target, powerDrawWatts: 2.5)
        let result = try await intent.perform()
        let value = try intentValue(of: result, as: Measurement<UnitPower>.self)
        XCTAssertEqual(value.value, 2.5, accuracy: 0.001)
    }
}
