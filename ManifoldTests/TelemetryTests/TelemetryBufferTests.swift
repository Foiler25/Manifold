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
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// ─────────────────────────────────────────────────────────────────────
// TelemetryBufferTests.swift
//
// Per SPEC.md §17 test-strategy table for Telemetry: "TelemetryBuffer
// ring-buffer behavior". Pins capacity, append-overflow drop-oldest,
// latest accessor, and FIFO ordering — the load-bearing properties
// the sparkline depends on.

import XCTest
@testable import Manifold
import ManifoldKit

final class TelemetryBufferTests: XCTestCase {

    // MARK: - Default capacity

    /// SPEC §8: default capacity 60.
    func test_defaultCapacity_isSixty() {
        let buffer = TelemetryBuffer()
        XCTAssertEqual(buffer.capacity, 60)
    }

    // MARK: - Append behavior

    /// Below capacity: every append accumulates.
    func test_append_belowCapacity_accumulates() {
        var buffer = TelemetryBuffer(capacity: 5)
        for i in 0..<3 {
            buffer.append(makeSample(at: TimeInterval(i)))
        }
        XCTAssertEqual(buffer.samples.count, 3)
    }

    /// At capacity: append drops the oldest (FIFO ring).
    func test_append_atCapacity_dropsOldest() {
        var buffer = TelemetryBuffer(capacity: 3)
        for i in 0..<3 {
            buffer.append(makeSample(at: TimeInterval(i)))
        }
        // Capacity is full; appending sample #4 drops sample #0.
        buffer.append(makeSample(at: TimeInterval(3)))
        XCTAssertEqual(buffer.samples.count, 3)
        XCTAssertEqual(buffer.samples.first?.timestamp, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(buffer.samples.last?.timestamp, Date(timeIntervalSince1970: 3))
    }

    /// Repeated overflow: the buffer keeps the last `capacity` samples
    /// in insertion order. Pinning the FIFO contract because the
    /// sparkline draws left-to-right in this order.
    func test_append_overflowMany_keepsLastCapacityInOrder() {
        var buffer = TelemetryBuffer(capacity: 4)
        for i in 0..<10 {
            buffer.append(makeSample(at: TimeInterval(i)))
        }
        XCTAssertEqual(buffer.samples.count, 4)
        let timestamps = buffer.samples.map { Int($0.timestamp.timeIntervalSince1970) }
        XCTAssertEqual(timestamps, [6, 7, 8, 9])
    }

    // MARK: - Latest

    /// Empty buffer → nil latest.
    func test_latest_emptyBuffer_isNil() {
        let buffer = TelemetryBuffer()
        XCTAssertNil(buffer.latest)
    }

    /// Latest is the most recently appended sample.
    func test_latest_isMostRecentlyAppended() {
        var buffer = TelemetryBuffer(capacity: 5)
        buffer.append(makeSample(at: 1, watts: 1.0))
        buffer.append(makeSample(at: 2, watts: 2.0))
        buffer.append(makeSample(at: 3, watts: 3.0))
        XCTAssertEqual(buffer.latest?.watts?.value, 3.0)
        XCTAssertEqual(buffer.latest?.timestamp, Date(timeIntervalSince1970: 3))
    }

    // MARK: - Custom capacity

    /// Capacity 1: only the most recent sample is ever kept.
    func test_capacityOne_keepsOnlyLatest() {
        var buffer = TelemetryBuffer(capacity: 1)
        buffer.append(makeSample(at: 1, watts: 1.0))
        buffer.append(makeSample(at: 2, watts: 2.0))
        XCTAssertEqual(buffer.samples.count, 1)
        XCTAssertEqual(buffer.latest?.watts?.value, 2.0)
    }

    // MARK: - Sendable / value semantics

    /// `TelemetryBuffer` is `Sendable`, which means it must behave as
    /// a value type — modifying a local copy doesn't affect the
    /// original. Tests pin this so a future refactor that adds
    /// reference indirection (e.g., a class-backed buffer) breaks
    /// loudly here.
    func test_valueSemantics_localCopyDoesNotMutateOriginal() {
        var original = TelemetryBuffer(capacity: 3)
        original.append(makeSample(at: 1))

        var copy = original
        copy.append(makeSample(at: 2))
        copy.append(makeSample(at: 3))

        XCTAssertEqual(original.samples.count, 1)
        XCTAssertEqual(copy.samples.count, 3)
    }

    // MARK: - Helpers

    private func makeSample(at timeInterval: TimeInterval, watts: Double = 0.0) -> TelemetrySample {
        TelemetrySample(
            timestamp: Date(timeIntervalSince1970: timeInterval),
            watts: Watts(watts),
            bitrate: nil
        )
    }
}
