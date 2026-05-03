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
// EventRepositoryTests.swift
//
// Pin SPEC §18 Phase 10 #2 ("events persist as they fire") + the
// per-kind payload round-trip + the retention sweep.

import XCTest
@testable import Manifold
import ManifoldKit

@MainActor
final class EventRepositoryTests: XCTestCase {

    private var tmpDir: URL!
    private var manager: DatabaseManager!
    private var repository: EventRepository!
    private var deviceRepo: DeviceRepository!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("manifold-tests-\(UUID().uuidString)")
        manager = try DatabaseManager(directory: tmpDir)
        repository = EventRepository(dbPool: manager.dbPool)
        deviceRepo = DeviceRepository(dbPool: manager.dbPool)
    }

    override func tearDown() async throws {
        repository = nil
        deviceRepo = nil
        manager = nil
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    // MARK: - .attached round-trip

    /// `.attached` writes one row with the device name in the JSON
    /// payload + the device FK. `recentEvents` reads it back with
    /// the payload decoded.
    func test_writeAttached_roundTripsThroughRecentEvents() async throws {
        let device = makeDevice(name: "Logitech MX")
        try await deviceRepo.upsert(device)
        let portID = PortID("/host/port-1")

        try await repository.write(.attached(device, at: portID), at: Date(timeIntervalSince1970: 1_000))
        let events = try await repository.recentEvents(limit: 10)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .attached)
        XCTAssertEqual(events.first?.deviceID, device.id)
        XCTAssertEqual(events.first?.portID, portID)
        if case .attached(let name, _, _) = events.first?.payload {
            XCTAssertEqual(name, "Logitech MX")
        } else {
            XCTFail("Expected .attached payload, got \(String(describing: events.first?.payload))")
        }
    }

    /// `.diagnostic` round-trip preserves severity, ruleIdentifier,
    /// title, detail.
    func test_writeDiagnostic_roundTripsPayload() async throws {
        let diag = Diagnostic(
            target: PortID("/host/port-2"),
            severity: .warning,
            ruleIdentifier: "running-at-usb-2",
            title: "Running @ USB 2.0",
            detail: "Device supports USB 3.0 but is on a USB 2.0 link.",
            triggeredAt: Date(timeIntervalSince1970: 2_000)
        )
        try await repository.write(.diagnostic(diag))

        let events = try await repository.recentEvents(limit: 10)
        XCTAssertEqual(events.count, 1)
        if case .diagnostic(let severity, let id, let title, let detail) = events.first?.payload {
            XCTAssertEqual(severity, "warning")
            XCTAssertEqual(id, "running-at-usb-2")
            XCTAssertEqual(title, "Running @ USB 2.0")
            XCTAssertEqual(detail, "Device supports USB 3.0 but is on a USB 2.0 link.")
        } else {
            XCTFail("Expected .diagnostic payload")
        }
    }

    /// `.telemetry` and `.fullRefresh` are explicitly skipped — the
    /// events table would otherwise swamp at no analytic benefit.
    func test_writeTelemetryAndFullRefresh_areSkipped() async throws {
        try await repository.write(.telemetry(PortID("/p"), TelemetrySample(timestamp: Date(), watts: nil, bitrate: nil)))
        try await repository.write(.fullRefresh)
        let events = try await repository.recentEvents(limit: 10)
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Reads

    /// `recentEvents` returns rows ordered by ts DESC and respects
    /// the `limit` argument.
    func test_recentEvents_orderedByTimestampDescending() async throws {
        let device = makeDevice()
        try await deviceRepo.upsert(device)
        try await repository.write(.attached(device, at: PortID("/p1")), at: Date(timeIntervalSince1970: 1))
        try await repository.write(.attached(device, at: PortID("/p2")), at: Date(timeIntervalSince1970: 3))
        try await repository.write(.attached(device, at: PortID("/p3")), at: Date(timeIntervalSince1970: 2))

        let events = try await repository.recentEvents(limit: 10)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].portID.rawValue, "/p2")  // ts=3 (newest first)
        XCTAssertEqual(events[1].portID.rawValue, "/p3")  // ts=2
        XCTAssertEqual(events[2].portID.rawValue, "/p1")  // ts=1
    }

    /// `events(forDevice:)` filters by device FK.
    func test_eventsForDevice_filtersByForeignKey() async throws {
        let deviceA = makeDevice(name: "A")
        let deviceB = makeDevice(name: "B")
        try await deviceRepo.upsert(deviceA)
        try await deviceRepo.upsert(deviceB)
        try await repository.write(.attached(deviceA, at: PortID("/p1")))
        try await repository.write(.attached(deviceB, at: PortID("/p2")))

        let aEvents = try await repository.events(forDevice: deviceA.id)
        XCTAssertEqual(aEvents.count, 1)
        XCTAssertEqual(aEvents.first?.deviceID, deviceA.id)
    }

    // MARK: - F24: SQL-side time-range filter

    /// Phase 14 F24 closure pin: `events(since:)` filters at the
    /// SQL layer (not in memory) so the export path doesn't need
    /// to drag every retained row through the heap. Insert two
    /// rows on either side of the cutoff; assert only the newer
    /// one comes back. Pins both the predicate AND the DESC ts
    /// ordering the caller relies on.
    func test_eventsSince_filtersBySQLAndOrdersDescending() async throws {
        let device = makeDevice()
        try await deviceRepo.upsert(device)
        try await repository.write(.attached(device, at: PortID("/old")), at: Date(timeIntervalSince1970: 100))
        try await repository.write(.attached(device, at: PortID("/new1")), at: Date(timeIntervalSince1970: 200))
        try await repository.write(.attached(device, at: PortID("/new2")), at: Date(timeIntervalSince1970: 300))

        let scoped = try await repository.events(since: Date(timeIntervalSince1970: 150))
        XCTAssertEqual(scoped.count, 2)
        XCTAssertEqual(scoped[0].portID.rawValue, "/new2", "DESC ordering: newest first")
        XCTAssertEqual(scoped[1].portID.rawValue, "/new1")
    }

    /// `since: .distantPast` returns every row (legacy "All time"
    /// semantics ExportSheet relies on).
    func test_eventsSince_distantPast_returnsEveryRow() async throws {
        let device = makeDevice()
        try await deviceRepo.upsert(device)
        try await repository.write(.attached(device, at: PortID("/p")), at: Date(timeIntervalSince1970: 100))

        let all = try await repository.events(since: .distantPast)
        XCTAssertEqual(all.count, 1)
    }

    // MARK: - Retention

    /// `deleteOlderThan` prunes only rows older than the cutoff.
    func test_deleteOlderThan_removesPrePeriodRows() async throws {
        let device = makeDevice()
        try await deviceRepo.upsert(device)
        try await repository.write(.attached(device, at: PortID("/old")), at: Date(timeIntervalSince1970: 100))
        try await repository.write(.attached(device, at: PortID("/new")), at: Date(timeIntervalSince1970: 200))

        let removed = try await repository.deleteOlderThan(Date(timeIntervalSince1970: 150))
        XCTAssertEqual(removed, 1)

        let remaining = try await repository.recentEvents(limit: 10)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.portID.rawValue, "/new")
    }

    // MARK: - Helpers

    private func makeDevice(name: String = "Test") -> Device {
        Device(
            id: DeviceID.make(vendorID: 0x1234, productID: 0x5678, serial: name, registryPath: "/test/\(name)"),
            name: name,
            kind: .other,
            vendorID: 0x1234,
            productID: 0x5678,
            serial: name,
            usbVersion: .usb2_0,
            displayInfo: nil,
            firstSeen: Date(timeIntervalSince1970: 0),
            lastSeen: Date(timeIntervalSince1970: 0)
        )
    }
}
