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
// DeviceRepositoryTests.swift
//
// **F10 closure pin.** The reconcile contract is the headline:
// upserting an existing device must NOT clobber `first_seen`. The
// other tests cover insert + read shapes.

import XCTest
@testable import Manifold
import ManifoldKit

@MainActor
final class DeviceRepositoryTests: XCTestCase {

    private var tmpDir: URL!
    private var manager: DatabaseManager!
    private var repository: DeviceRepository!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("manifold-tests-\(UUID().uuidString)")
        manager = try DatabaseManager(directory: tmpDir)
        repository = DeviceRepository(dbPool: manager.dbPool)
    }

    override func tearDown() async throws {
        repository = nil
        manager = nil
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    // MARK: - F10 pin

    /// Insert a device, then upsert the same DeviceID with a *later*
    /// `firstSeen` timestamp. The persisted `firstSeen` must remain
    /// the original (earliest) value. Pins F10.
    func test_upsert_existingDevice_preservesFirstSeen() async throws {
        let original = makeDevice(firstSeen: Date(timeIntervalSince1970: 1_000_000))
        try await repository.upsert(original)

        let later = Device(
            id: original.id,
            name: original.name + " (renamed)",
            kind: original.kind,
            vendorID: original.vendorID,
            productID: original.productID,
            serial: original.serial,
            usbVersion: original.usbVersion,
            displayInfo: original.displayInfo,
            firstSeen: Date(timeIntervalSince1970: 2_000_000),  // later than original
            lastSeen: Date(timeIntervalSince1970: 2_500_000)
        )
        try await repository.upsert(later)

        let stored = try await repository.device(id: original.id)
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.firstSeen, original.firstSeen, "first_seen must NOT advance on re-upsert")
        XCTAssertEqual(stored?.lastSeen, later.lastSeen, "last_seen must update on re-upsert")
        XCTAssertEqual(stored?.name, later.name, "name should reflect the latest observation")
    }

    /// New device → new row, and every column round-trips through the
    /// upsert / fetch path.
    func test_upsert_newDevice_persistsEveryField() async throws {
        let device = makeDevice(
            name: "Test Device",
            vendorID: 0x05AC,
            productID: 0x024F,
            serial: "SN12345",
            usbVersion: .usb3_0,
            firstSeen: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await repository.upsert(device)

        let stored = try await repository.device(id: device.id)
        XCTAssertEqual(stored?.id, device.id)
        XCTAssertEqual(stored?.name, device.name)
        XCTAssertEqual(stored?.vendorID, device.vendorID)
        XCTAssertEqual(stored?.productID, device.productID)
        XCTAssertEqual(stored?.serial, device.serial)
        XCTAssertEqual(stored?.usbVersion, device.usbVersion)
    }

    /// Missing device → nil (not throw).
    func test_device_missingID_returnsNil() async throws {
        let result = try await repository.device(id: DeviceID("nonexistent"))
        XCTAssertNil(result)
    }

    /// `allDevices` returns rows ordered by `last_seen DESC`. Distinct
    /// serials so the two upserts produce two distinct DeviceIDs (the
    /// composite ID hashes serial when present, so same-serial inputs
    /// would dedup into one row).
    func test_allDevices_sortedByLastSeenDescending() async throws {
        let older = makeDevice(name: "older", serial: "OLD-SN", lastSeen: Date(timeIntervalSince1970: 1_000_000))
        let newer = makeDevice(name: "newer", serial: "NEW-SN", lastSeen: Date(timeIntervalSince1970: 2_000_000))
        try await repository.upsert(older)
        try await repository.upsert(newer)

        let all = try await repository.allDevices()
        XCTAssertEqual(all.first?.name, "newer")
        XCTAssertEqual(all.last?.name,  "older")
    }

    // MARK: - Helpers

    private func makeDevice(
        name: String = "Test",
        vendorID: UInt16 = 0x1234,
        productID: UInt16 = 0x5678,
        serial: String? = "TEST-SERIAL",
        usbVersion: USBVersion? = .usb2_0,
        firstSeen: Date = Date(timeIntervalSince1970: 0),
        lastSeen: Date? = nil
    ) -> Device {
        Device(
            id: DeviceID.make(vendorID: vendorID, productID: productID, serial: serial, registryPath: "/test/\(name)"),
            name: name,
            kind: .other,
            vendorID: vendorID,
            productID: productID,
            serial: serial,
            usbVersion: usbVersion,
            displayInfo: nil,
            firstSeen: firstSeen,
            lastSeen: lastSeen ?? firstSeen
        )
    }
}
