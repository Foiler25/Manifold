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
// SnapshotV1RoundTripTests.swift
//
// Pin SPEC §12 wire-format invariants:
//   - schemaVersion always emits as 1.
//   - encode → decode round-trips every field.
//   - atomic write produces a readable file on disk.
//   - load() throws LoadError.unknownSchemaVersion on a future v2.
//   - Forward-compat: a future v2 file doesn't crash; widget reader
//     pattern-matches on LoadError to fall back to a placeholder.

import XCTest
@testable import ManifoldKit

final class SnapshotV1RoundTripTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("manifold-snapshot-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        tmpDir = nil
        super.tearDown()
    }

    // MARK: - Codable round-trip

    /// Every field round-trips through encode → decode without loss.
    /// schemaVersion stays 1 explicitly.
    func test_codable_roundTripsEveryField() throws {
        let original = makeSampleSnapshot()
        let encoded = try SnapshotCodec.encode(.v1(original))
        let decoded = try SnapshotCodec.decode(encoded)
        guard case .v1(let payload) = decoded else {
            XCTFail("Expected v1 case after decode")
            return
        }
        XCTAssertEqual(payload.schemaVersion, 1)
        XCTAssertEqual(payload, original)
    }

    /// Top-level JSON object always carries `"schemaVersion": 1`.
    /// Pinned because a future codec change must NOT silently
    /// promote past v1 files.
    func test_encoded_jsonAlwaysHasSchemaVersion1() throws {
        let encoded = try SnapshotCodec.encode(.v1(makeSampleSnapshot()))
        let parsed = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertEqual(parsed?["schemaVersion"] as? Int, 1)
    }

    // MARK: - Atomic write + load

    /// `Snapshot.write(to:)` produces a file that `Snapshot.load`
    /// reads back to the same payload. Pins the SPEC §12.3 atomic
    /// write contract.
    func test_writeThenLoad_roundTripsThroughDisk() throws {
        let original = makeSampleSnapshot()
        try Snapshot.v1(original).write(to: tmpDir)

        let loaded = try Snapshot.load(from: tmpDir)
        guard case .v1(let payload) = loaded else {
            XCTFail("Expected v1 case after load")
            return
        }
        XCTAssertEqual(payload, original)
    }

    /// Re-writing replaces the file in place (no stray .tmp files
    /// left in the directory). Pins the cleanup half of the atomic
    /// write.
    func test_writeMultipleTimes_leavesNoTempFiles() throws {
        for i in 0..<5 {
            var snapshot = makeSampleSnapshot()
            snapshot = SnapshotV1(
                schemaVersion: 1,
                writtenAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                totalPowerDraw: snapshot.totalPowerDraw,
                connectedDeviceCount: snapshot.connectedDeviceCount,
                topDevicesByPower: snapshot.topDevicesByPower,
                activeDiagnosticCount: snapshot.activeDiagnosticCount,
                lastEventAt: snapshot.lastEventAt
            )
            try Snapshot.v1(snapshot).write(to: tmpDir)
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        // Exactly one file (`snapshot.json`); no `.tmp.*` leftovers.
        XCTAssertEqual(contents, [Snapshot.filename])
    }

    /// Atomic write means a partially-written file is never
    /// observable. We can't directly stress-test a concurrent
    /// reader, but we can verify the temp-file pattern matches the
    /// SPEC: write to a `.tmp.UUID` file, then `replaceItemAt` the
    /// target. After a successful write the temp is gone.
    func test_atomicWrite_tempFileNotPresentAfterReplace() throws {
        try Snapshot.v1(makeSampleSnapshot()).write(to: tmpDir)
        let contents = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        XCTAssertFalse(contents.contains { $0.hasPrefix(".\(Snapshot.filename).tmp") },
                       "Atomic write must remove its temp file on success")
    }

    // MARK: - Forward compat

    /// A future-v2 file landed by a newer Manifold against this
    /// binary surfaces as `LoadError.unknownSchemaVersion(2)`.
    /// Pinned so the widget extension's pattern-match keeps working.
    func test_load_unknownSchemaVersion_throwsLoadError() throws {
        let url = tmpDir.appendingPathComponent(Snapshot.filename)
        let futureJSON = #"{"schemaVersion": 2, "futureField": "ignored"}"#
        try futureJSON.data(using: .utf8)!.write(to: url)

        do {
            _ = try Snapshot.load(from: tmpDir)
            XCTFail("Expected throw")
        } catch Snapshot.LoadError.unknownSchemaVersion(let version) {
            XCTAssertEqual(version, 2)
        } catch {
            XCTFail("Expected LoadError.unknownSchemaVersion, got \(error)")
        }
    }

    // MARK: - File size

    /// Realistic snapshot stays well under the SPEC §18 #10 10KB
    /// budget. 10 devices × 30 samples × ~30 chars per number =
    /// ~9KB worst case in pretty-printed; compact (release) is
    /// ~3KB. The fixture here uses 4 devices (the cap) at 30
    /// samples each — representative of the medium-widget feed.
    func test_typicalSnapshotSize_underTenKilobytes() throws {
        let snapshot = makeSampleSnapshot()
        let encoded = try SnapshotCodec.encode(.v1(snapshot))
        XCTAssertLessThan(encoded.count, 10_240, "snapshot \(encoded.count) bytes exceeds 10KB SPEC bound")
    }

    // MARK: - Helpers

    private func makeSampleSnapshot() -> SnapshotV1 {
        let topDevices = (0..<4).map { i in
            SnapshotV1.TopDevice(
                id: DeviceID("VID:PID:device-\(i)"),
                name: "Device \(i)",
                powerDraw: Watts(Double(i + 1) * 0.5),
                kind: .other,
                recentSamples: (0..<30).map { Double($0) * 0.01 }
            )
        }
        return SnapshotV1(
            schemaVersion: 1,
            writtenAt: Date(timeIntervalSince1970: 1_700_000_000),
            totalPowerDraw: Watts(5.0),
            connectedDeviceCount: 4,
            topDevicesByPower: topDevices,
            activeDiagnosticCount: 1,
            lastEventAt: Date(timeIntervalSince1970: 1_699_999_500)
        )
    }
}
