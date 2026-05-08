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
// BatteryNotificationObserverTests.swift
//
// Unit tests for the IOPS-driven battery observer. The IOPS callback
// itself is a C API we can't easily fake from Swift, so the tests
// cover the synchronous deliver path (`deliverInitialSnapshot()`) and
// the lifecycle invariants (`stop()` idempotence, post-stop deliveries
// suppressed). The IOPS subscription is registered on init in both
// production and test paths — failure to register would surface in
// the os.log output rather than a test failure here.

import XCTest
@testable import Manifold
import ManifoldKit

private let observerTestSentinel = BatteryInfo(
    chargePercent: 73,
    chargeState: .charging,
    healthPercent: 92,
    cycleCount: 42,
    temperatureCelsius: 28.5,
    voltageVolts: 12.8,
    amperageMilliamps: 1500,
    powerWatts: 19.2,
    designCapacityMAh: 6000,
    nominalCapacityMAh: 5800,
    currentCapacityMAh: 4234,
    timeUntilFullMinutes: 30,
    timeUntilEmptyMinutes: nil,
    isExternalConnected: true,
    isFullyCharged: false,
    sampledAt: Date(timeIntervalSince1970: 0)
)

@MainActor
final class BatteryNotificationObserverTests: XCTestCase {

    @MainActor
    private final class Recorder {
        var calls: [BatteryInfo?] = []
        func record(_ info: BatteryInfo?) { calls.append(info) }
    }

    func test_deliverInitialSnapshot_invokesConsumerWithReaderResult() {
        let recorder = Recorder()
        let observer = BatteryNotificationObserver(
            reader: { observerTestSentinel },
            onSnapshot: { recorder.record($0) }
        )
        // Reset to isolate the explicit deliver call.
        recorder.calls.removeAll()
        observer.deliverInitialSnapshot()
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls.first??.chargePercent, observerTestSentinel.chargePercent)
        observer.stop()
    }

    func test_deliverInitialSnapshot_passesNilFromDesktopReader() {
        let recorder = Recorder()
        let observer = BatteryNotificationObserver(
            reader: { nil },
            onSnapshot: { recorder.record($0) }
        )
        recorder.calls.removeAll()
        observer.deliverInitialSnapshot()
        XCTAssertEqual(recorder.calls.count, 1)
        if let first = recorder.calls.first {
            XCTAssertNil(first, "Reader returned nil; observer should forward nil")
        }
        observer.stop()
    }

    func test_stop_isIdempotent() {
        let observer = BatteryNotificationObserver(
            reader: { nil },
            onSnapshot: { _ in }
        )
        observer.stop()
        observer.stop()  // second call is a no-op
    }

    func test_postStop_deliverInitialSnapshot_isNoOp() {
        let recorder = Recorder()
        let observer = BatteryNotificationObserver(
            reader: { observerTestSentinel },
            onSnapshot: { recorder.record($0) }
        )
        observer.stop()
        recorder.calls.removeAll()
        observer.deliverInitialSnapshot()
        XCTAssertTrue(
            recorder.calls.isEmpty,
            "deliverInitialSnapshot() after stop() should not invoke the consumer"
        )
    }
}
