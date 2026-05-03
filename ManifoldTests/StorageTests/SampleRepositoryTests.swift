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
// SampleRepositoryTests.swift
//
// Pin SPEC §18 Phase 10 #3 ("samples persist") + the downsampling
// behavior + retention sweep. Downsampling is the algorithmic
// risk surface — group-by minute / hour edge cases are easy to
// silently mis-bucket.

import XCTest
import GRDB
@testable import Manifold
import ManifoldKit

@MainActor
final class SampleRepositoryTests: XCTestCase {

    private var tmpDir: URL!
    private var manager: DatabaseManager!
    private var repository: SampleRepository!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("manifold-tests-\(UUID().uuidString)")
        manager = try DatabaseManager(directory: tmpDir)
        repository = SampleRepository(dbPool: manager.dbPool)
    }

    override func tearDown() async throws {
        repository = nil
        manager = nil
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    // MARK: - Write + read

    /// One sample writes and reads back with watts + mbps preserved.
    /// `mbps` is derived from `Bitrate.bitsPerSecond / 1_000_000`.
    func test_write_singleSampleRoundTrips() async throws {
        let portID = PortID("/host/port-1")
        let sample = TelemetrySample(
            timestamp: Date(timeIntervalSince1970: 1_000),
            watts: Watts(2.5),
            bitrate: Bitrate(bitsPerSecond: 5_000_000_000)
        )
        try await repository.write(sample, portID: portID, deviceID: nil)

        let stored = try await repository.samples(forPort: portID, since: .distantPast, aggregation: .raw)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.watts, 2.5)
        XCTAssertEqual(stored.first?.mbps, 5000)
        XCTAssertEqual(stored.first?.aggregation, .raw)
    }

    /// `samples(forPort:since:aggregation:)` filters by port +
    /// aggregation + since. Pins all three predicates simultaneously.
    func test_samplesQuery_filtersByPortAggregationAndSince() async throws {
        let portA = PortID("/p/a")
        let portB = PortID("/p/b")

        try await repository.write(makeSample(seconds: 100, watts: 1.0), portID: portA, deviceID: nil)
        try await repository.write(makeSample(seconds: 200, watts: 2.0), portID: portA, deviceID: nil)
        try await repository.write(makeSample(seconds: 300, watts: 9.0), portID: portB, deviceID: nil)

        let aSince150 = try await repository.samples(
            forPort: portA, since: Date(timeIntervalSince1970: 150), aggregation: .raw
        )
        XCTAssertEqual(aSince150.count, 1)
        XCTAssertEqual(aSince150.first?.watts, 2.0)
    }

    // MARK: - Downsampling raw → 1-min

    /// Three raw samples in the same minute roll into one 1-min row
    /// whose `watts` is the average. The raw rows are deleted.
    func test_downsampleRawTo1Min_groupsByMinuteAndAveragesWatts() async throws {
        let portID = PortID("/p")
        // Three samples in the 16:00:00 minute (seconds 0/15/45 of
        // unix-epoch-aligned 60-second buckets).
        let baseSeconds: TimeInterval = 60 * 100  // arbitrary minute boundary
        try await repository.write(makeSample(seconds: baseSeconds + 0,  watts: 1.0), portID: portID, deviceID: nil)
        try await repository.write(makeSample(seconds: baseSeconds + 15, watts: 2.0), portID: portID, deviceID: nil)
        try await repository.write(makeSample(seconds: baseSeconds + 45, watts: 3.0), portID: portID, deviceID: nil)

        // Cutoff well in the future so all three rows downsample.
        let removed = try await repository.downsampleRawTo1Min(olderThan: Date(timeIntervalSince1970: baseSeconds + 1000))
        XCTAssertEqual(removed, 3)

        let oneMin = try await repository.samples(forPort: portID, since: .distantPast, aggregation: .oneMin)
        XCTAssertEqual(oneMin.count, 1)
        XCTAssertEqual(oneMin.first?.watts ?? 0, 2.0, accuracy: 0.001, "AVG(1,2,3) = 2.0")
        let raw = try await repository.samples(forPort: portID, since: .distantPast, aggregation: .raw)
        XCTAssertTrue(raw.isEmpty, "raw rows older than the cutoff must be deleted")
    }

    /// Samples newer than the cutoff are NOT downsampled or deleted.
    /// Pins the "older than" predicate.
    func test_downsampleRawTo1Min_skipsRowsNewerThanCutoff() async throws {
        let portID = PortID("/p")
        let cutoff = Date(timeIntervalSince1970: 1_000)
        try await repository.write(makeSample(seconds: 999, watts: 1.0),  portID: portID, deviceID: nil)
        try await repository.write(makeSample(seconds: 1001, watts: 2.0), portID: portID, deviceID: nil)

        try await repository.downsampleRawTo1Min(olderThan: cutoff)

        let raw = try await repository.samples(forPort: portID, since: .distantPast, aggregation: .raw)
        // The newer (>= cutoff) row survives.
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(raw.first?.watts, 2.0)
    }

    // MARK: - Retention

    /// `deleteOlderThan` only removes rows in the requested
    /// aggregation bucket — leaves the others alone.
    func test_deleteOlderThan_filtersByAggregation() async throws {
        let portID = PortID("/p")
        try await repository.write(makeSample(seconds: 100, watts: 1), portID: portID, deviceID: nil)
        // Manually insert a 1-min row so we have something to keep.
        try await manager.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO samples (ts, device_id, port_id, watts, mbps, aggregation)
                VALUES (?, NULL, ?, 5.0, NULL, '1min')
            """, arguments: [Date(timeIntervalSince1970: 100), portID.rawValue])
        }

        let removed = try await repository.deleteOlderThan(
            Date(timeIntervalSince1970: 200),
            aggregation: .raw
        )
        XCTAssertEqual(removed, 1)

        let oneMin = try await repository.samples(forPort: portID, since: .distantPast, aggregation: .oneMin)
        XCTAssertEqual(oneMin.count, 1, "1-min rows must NOT be removed by raw deletion")
    }

    // MARK: - Helpers

    private func makeSample(seconds: TimeInterval, watts: Double) -> TelemetrySample {
        TelemetrySample(
            timestamp: Date(timeIntervalSince1970: seconds),
            watts: Watts(watts),
            bitrate: nil
        )
    }
}
