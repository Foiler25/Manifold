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
// WatchForDeviceConnectIntentTests.swift
//
// Pin the watcher's three filter modes (name / vendorID / productID)
// + the live-graph fallback when the persistent event log is empty.

import XCTest
@testable import Manifold
import ManifoldKit

@MainActor
final class WatchForDeviceConnectIntentTests: XCTestCase {

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

    // MARK: - Live graph fallback

    /// Empty event log + matching live device → returns the live
    /// device. Pins the cold-launch fallback path.
    func test_perform_emptyEventLog_returnsMatchingLiveDevice() async throws {
        let target = IntentTestFixtures.device(name: "Logitech MX")
        stub.hosts = [
            IntentTestFixtures.host(ports: [IntentTestFixtures.port(id: "/p1", device: target)])
        ]

        let intent = WatchForDeviceConnectIntent()
        intent.nameContains = "logitech"
        let result = try await intent.perform()
        let value = try intentValue(of: result, as: DeviceEntity?.self)
        XCTAssertEqual(value?.name, "Logitech MX")
    }

    // MARK: - Per-filter

    /// nameContains is case-insensitive.
    func test_perform_nameFilter_isCaseInsensitive() async throws {
        let target = IntentTestFixtures.device(name: "SanDisk Extreme")
        stub.hosts = [
            IntentTestFixtures.host(ports: [IntentTestFixtures.port(id: "/p1", device: target)])
        ]
        let intent = WatchForDeviceConnectIntent()
        intent.nameContains = "sandisk"
        let result = try await intent.perform()
        let value = try intentValue(of: result, as: DeviceEntity?.self)
        XCTAssertEqual(value?.name, "SanDisk Extreme")
    }

    /// vendorID filter — only devices whose VID matches survive.
    func test_perform_vendorFilter_returnsMatchingDevice() async throws {
        let logitech = IntentTestFixtures.device(name: "Mouse", vendorID: 0x046D)
        let other    = IntentTestFixtures.device(name: "Other", vendorID: 0xDEAD)
        stub.hosts = [
            IntentTestFixtures.host(ports: [
                IntentTestFixtures.port(id: "/p1", device: logitech),
                IntentTestFixtures.port(id: "/p2", device: other)
            ])
        ]
        let intent = WatchForDeviceConnectIntent()
        intent.vendorID = 0x046D
        let result = try await intent.perform()
        let value = try intentValue(of: result, as: DeviceEntity?.self)
        XCTAssertEqual(value?.name, "Mouse")
    }

    /// productID filter — only devices whose PID matches survive.
    /// Pins the third filter path so a refactor can't accidentally
    /// drop one of the three matchers.
    func test_perform_productFilter_returnsMatchingDevice() async throws {
        let target = IntentTestFixtures.device(name: "Keyboard", productID: 0xC52B)
        let other  = IntentTestFixtures.device(name: "Mouse",    productID: 0x1234)
        stub.hosts = [
            IntentTestFixtures.host(ports: [
                IntentTestFixtures.port(id: "/p1", device: target),
                IntentTestFixtures.port(id: "/p2", device: other)
            ])
        ]
        let intent = WatchForDeviceConnectIntent()
        intent.productID = 0xC52B
        let result = try await intent.perform()
        let value = try intentValue(of: result, as: DeviceEntity?.self)
        XCTAssertEqual(value?.name, "Keyboard")
    }

    /// No matching device anywhere → nil result, not an error.
    func test_perform_noMatch_returnsNil() async throws {
        stub.hosts = [
            IntentTestFixtures.host(ports: [IntentTestFixtures.port(id: "/p1", device: IntentTestFixtures.device(name: "Mouse"))])
        ]
        let intent = WatchForDeviceConnectIntent()
        intent.nameContains = "Studio Display"
        let result = try await intent.perform()
        let value = try intentValue(of: result, as: DeviceEntity?.self)
        XCTAssertNil(value)
    }
}
