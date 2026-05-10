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
// BatteryInterestObserverTests.swift
//
// Unit tests for the AppleSmartBattery kIOGeneralInterest observer.
// The kernel callback is a C API we can't fake from Swift, so the
// tests cover the synchronous `deliverInitialSnapshot()` path and
// the empty-diff filter that production code relies on for noise
// suppression.

import XCTest
@testable import Manifold
import ManifoldKit

private let interestTestSentinel = BatteryInfo(
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
final class BatteryInterestObserverTests: XCTestCase {

    @MainActor
    private final class Recorder {
        var calls: [BatteryInfo?] = []
        func record(_ info: BatteryInfo?) { calls.append(info) }
    }

    /// Build an observer with a programmable reader. Each test
    /// assigns to `currentSnapshot` to control what the next
    /// `deliverInitialSnapshot()` (or kernel callback) will see —
    /// kernel callbacks aren't fired in tests, but the equivalent
    /// path is `deliverInitialSnapshot()` which calls the reader.
    private final class SnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: BatteryInfo?
        var value: BatteryInfo? {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); defer { lock.unlock() }; _value = newValue }
        }
    }

    private func makeObserver(
        seed: BatteryInfo? = interestTestSentinel
    ) -> (BatteryInterestObserver, Recorder, SnapshotBox) {
        let recorder = Recorder()
        let box = SnapshotBox()
        box.value = seed
        let observer = BatteryInterestObserver(
            reader: { box.value },
            onSnapshot: { recorder.record($0) }
        )
        return (observer, recorder, box)
    }

    // MARK: - Initial delivery

    func test_deliverInitialSnapshot_invokesConsumerWithReaderResult() {
        let (observer, recorder, _) = makeObserver()
        recorder.calls.removeAll()
        observer.deliverInitialSnapshot()
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls.first??.chargePercent, interestTestSentinel.chargePercent)
        observer.stop()
    }

    func test_deliverInitialSnapshot_passesNilFromDesktopReader() {
        let (observer, recorder, _) = makeObserver(seed: nil)
        recorder.calls.removeAll()
        observer.deliverInitialSnapshot()
        XCTAssertEqual(recorder.calls.count, 1)
        if let first = recorder.calls.first {
            XCTAssertNil(first, "Reader returned nil; observer should forward nil")
        }
        observer.stop()
    }

    // MARK: - Empty-diff filter

    /// A second `deliverInitialSnapshot()` with an unchanged
    /// snapshot should NOT invoke the consumer again. This is the
    /// production noise-suppression path: the kernel fires
    /// kIOGeneralInterest for service-level events that don't
    /// correspond to a property change, and we skip those.
    func test_unchangedSnapshot_isNotForwardedTwice() {
        let (observer, recorder, _) = makeObserver()
        observer.deliverInitialSnapshot()
        recorder.calls.removeAll()
        observer.deliverInitialSnapshot()  // same value as before
        XCTAssertTrue(
            recorder.calls.isEmpty,
            "Identical snapshot should not be forwarded twice"
        )
        observer.stop()
    }

    /// `sampledAt: Date` ticks every reader call but is intentionally
    /// excluded from the diff — otherwise the noise-suppression
    /// filter would never fire. Verify the filter ignores `sampledAt`.
    func test_sampledAtChangeAlone_isFiltered() {
        let (observer, recorder, box) = makeObserver()
        observer.deliverInitialSnapshot()
        recorder.calls.removeAll()
        // Same observable state, different `sampledAt`.
        var bumped = interestTestSentinel
        bumped = BatteryInfo(
            chargePercent: bumped.chargePercent,
            chargeState: bumped.chargeState,
            healthPercent: bumped.healthPercent,
            cycleCount: bumped.cycleCount,
            temperatureCelsius: bumped.temperatureCelsius,
            voltageVolts: bumped.voltageVolts,
            amperageMilliamps: bumped.amperageMilliamps,
            powerWatts: bumped.powerWatts,
            designCapacityMAh: bumped.designCapacityMAh,
            nominalCapacityMAh: bumped.nominalCapacityMAh,
            currentCapacityMAh: bumped.currentCapacityMAh,
            timeUntilFullMinutes: bumped.timeUntilFullMinutes,
            timeUntilEmptyMinutes: bumped.timeUntilEmptyMinutes,
            isExternalConnected: bumped.isExternalConnected,
            isFullyCharged: bumped.isFullyCharged,
            sampledAt: Date(timeIntervalSince1970: 1_000_000)
        )
        box.value = bumped
        observer.deliverInitialSnapshot()
        XCTAssertTrue(
            recorder.calls.isEmpty,
            "sampledAt-only delta should not propagate to the consumer"
        )
        observer.stop()
    }

    /// Real field change (e.g., percent drop) DOES forward.
    func test_meaningfulChange_isForwarded() {
        let (observer, recorder, box) = makeObserver()
        observer.deliverInitialSnapshot()
        recorder.calls.removeAll()
        var changed = interestTestSentinel
        changed = BatteryInfo(
            chargePercent: 72,  // dropped 73 → 72
            chargeState: changed.chargeState,
            healthPercent: changed.healthPercent,
            cycleCount: changed.cycleCount,
            temperatureCelsius: changed.temperatureCelsius,
            voltageVolts: changed.voltageVolts,
            amperageMilliamps: changed.amperageMilliamps,
            powerWatts: changed.powerWatts,
            designCapacityMAh: changed.designCapacityMAh,
            nominalCapacityMAh: changed.nominalCapacityMAh,
            currentCapacityMAh: changed.currentCapacityMAh,
            timeUntilFullMinutes: changed.timeUntilFullMinutes,
            timeUntilEmptyMinutes: changed.timeUntilEmptyMinutes,
            isExternalConnected: changed.isExternalConnected,
            isFullyCharged: changed.isFullyCharged,
            sampledAt: Date(timeIntervalSince1970: 1_000_000)
        )
        box.value = changed
        observer.deliverInitialSnapshot()
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls.first??.chargePercent, 72)
        observer.stop()
    }

    /// Going from non-nil → nil (battery disappears, e.g., during
    /// transient IOKit churn) is always meaningful and should fire.
    func test_nilFlip_isForwarded() {
        let (observer, recorder, box) = makeObserver()
        observer.deliverInitialSnapshot()
        recorder.calls.removeAll()
        box.value = nil
        observer.deliverInitialSnapshot()
        XCTAssertEqual(recorder.calls.count, 1)
        if let first = recorder.calls.first {
            XCTAssertNil(first)
        }
        observer.stop()
    }

    // MARK: - Lifecycle

    func test_stop_isIdempotent() {
        let (observer, _, _) = makeObserver()
        observer.stop()
        observer.stop()
    }

    func test_postStop_deliverInitialSnapshot_isNoOp() {
        let (observer, recorder, _) = makeObserver()
        observer.stop()
        recorder.calls.removeAll()
        observer.deliverInitialSnapshot()
        XCTAssertTrue(
            recorder.calls.isEmpty,
            "deliverInitialSnapshot() after stop() should not invoke the consumer"
        )
    }
}
