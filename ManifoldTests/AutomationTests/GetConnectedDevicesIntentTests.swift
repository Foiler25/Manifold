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
// GetConnectedDevicesIntentTests.swift
//
// Pin SPEC §11.2 + §17 "Each App Intent has a perform() test using
// a mocked PortGraph". Three cases per intent: happy path, host
// filter, empty graph.

import XCTest
@testable import Manifold
import ManifoldKit

@MainActor
final class GetConnectedDevicesIntentTests: XCTestCase {

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

    /// Happy path: two devices across two ports → returns both as
    /// DeviceEntities.
    func test_perform_returnsEveryConnectedDevice() async throws {
        let mouse = IntentTestFixtures.device(name: "Mouse")
        let ssd   = IntentTestFixtures.device(name: "SSD")
        stub.hosts = [
            IntentTestFixtures.host(ports: [
                IntentTestFixtures.port(id: "/p1", device: mouse),
                IntentTestFixtures.port(id: "/p2", device: ssd)
            ])
        ]

        let intent = GetConnectedDevicesIntent()
        let result = try await intent.perform()
        let value = try intentValue(of: result, as: [DeviceEntity].self)
        XCTAssertEqual(value.map(\.name).sorted(), ["Mouse", "SSD"])
    }

    /// Host filter: when the intent's `host` parameter is set, only
    /// devices on that host are returned. Pins the SPEC §11.2
    /// `@Parameter(title: "Filter by host")` semantics.
    func test_perform_hostFilter_returnsOnlyMatchingHost() async throws {
        let mouseA = IntentTestFixtures.device(name: "MouseA")
        let mouseB = IntentTestFixtures.device(name: "MouseB")
        stub.hosts = [
            IntentTestFixtures.host(id: "h1", ports: [IntentTestFixtures.port(id: "/p1", device: mouseA)]),
            IntentTestFixtures.host(id: "h2", ports: [IntentTestFixtures.port(id: "/p2", device: mouseB)])
        ]

        let intent = GetConnectedDevicesIntent()
        intent.host = HostEntity(host: stub.hosts[1])  // filter to h2
        let result = try await intent.perform()
        let value = try intentValue(of: result, as: [DeviceEntity].self)
        XCTAssertEqual(value.map(\.name), ["MouseB"])
    }

    /// Empty graph (cold-launch state) → returns an empty array,
    /// not nil and not an error.
    func test_perform_emptyGraph_returnsEmptyArray() async throws {
        stub.hosts = []
        let intent = GetConnectedDevicesIntent()
        let result = try await intent.perform()
        let value = try intentValue(of: result, as: [DeviceEntity].self)
        XCTAssertTrue(value.isEmpty)
    }
}
