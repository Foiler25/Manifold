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
// CableEngineTests.swift
//
// Phase 21 — exercise the engine via a `StubCableProvider` so the test
// runs without IOKit. Covers: nil snapshot before start, snapshot
// arrives after start, snapshot updates as further values are
// emitted, errors land on `lastError`, `stop()` halts consumption.

import XCTest
@testable import Manifold

@MainActor
final class CableEngineTests: XCTestCase {

    func test_snapshot_isNil_beforeStart() {
        let engine = CableEngine(
            provider: StubCableProvider(snapshots: [CableSummaryFixtures.oneEmptyPort], trailingError: nil)
        )
        XCTAssertNil(engine.snapshot)
        XCTAssertFalse(engine.isRunning)
        XCTAssertNil(engine.lastError)
    }

    func test_snapshot_arrives_afterStart() async {
        let engine = CableEngine(
            provider: StubCableProvider(snapshots: [CableSummaryFixtures.oneEmptyPort], trailingError: nil)
        )
        engine.start()
        XCTAssertTrue(engine.isRunning)

        try? await waitUntil(timeout: .seconds(2)) {
            engine.snapshot != nil
        }
        XCTAssertEqual(engine.snapshot?.ports.first?.serviceName, "Port-USB-C@1")
        XCTAssertNil(engine.lastError)
    }

    func test_multipleSnapshots_areAllReceived_inOrder() async {
        let provider = StubCableProvider(
            snapshots: [
                CableSummaryFixtures.empty,
                CableSummaryFixtures.oneEmptyPort,
                CableSummaryFixtures.empty
            ],
            trailingError: nil
        )
        let engine = CableEngine(provider: provider)
        engine.start()

        try? await waitUntil(timeout: .seconds(2)) {
            !engine.isRunning && engine.snapshot != nil
        }
        // After the stream finishes, isRunning falls back to false and
        // the final snapshot is the last yielded value.
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.snapshot, CableSummaryFixtures.empty)
    }

    func test_error_landsOnLastError() async {
        let provider = StubCableProvider(
            snapshots: [],
            trailingError: StubCableProviderError(reason: "synthetic")
        )
        let engine = CableEngine(provider: provider)
        engine.start()

        try? await waitUntil(timeout: .seconds(2)) {
            engine.lastError != nil
        }
        XCTAssertNotNil(engine.lastError)
        XCTAssertEqual(
            (engine.lastError as? StubCableProviderError)?.reason,
            "synthetic"
        )
        XCTAssertFalse(engine.isRunning)
    }

    func test_stop_isIdempotent() {
        let engine = CableEngine(
            provider: StubCableProvider(snapshots: [], trailingError: nil)
        )
        engine.stop()
        engine.stop()
        XCTAssertFalse(engine.isRunning)
    }

    func test_doubleStart_isNoop() async {
        let engine = CableEngine(
            provider: StubCableProvider(snapshots: [CableSummaryFixtures.oneEmptyPort], trailingError: nil)
        )
        engine.start()
        engine.start() // second call should be a no-op, not crash
        XCTAssertTrue(engine.isRunning)

        try? await waitUntil(timeout: .seconds(2)) {
            engine.snapshot != nil
        }
        XCTAssertNotNil(engine.snapshot)
    }

    // MARK: - Helpers

    /// Polls `condition` every 50ms until it returns true or `timeout`
    /// elapses. Throws on timeout. Intentionally MainActor-isolated
    /// since the engine state we read is also MainActor-isolated.
    @MainActor
    private func waitUntil(
        timeout: Duration,
        condition: () -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        struct WaitTimeout: Error {}
        throw WaitTimeout()
    }
}
