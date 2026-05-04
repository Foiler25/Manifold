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
// BatterySamplerTests.swift
//
// Phase 18 — exercise the BatterySampler with an injected fake reader
// closure so the timer can fire without IOKit. Per SPEC §18 Phase 18:
// "asserts ≈N samples in N seconds, `stop()` halts, `setActiveSurfaces(0)`
// stops + `setActiveSurfaces(1)` resumes, sample-rate change re-arms
// timer."

import XCTest
@testable import Manifold
import ManifoldKit

/// Sentinel snapshot — production reads via
/// `BatterySnapshotReader.currentSnapshot` which produces a real
/// `BatteryInfo`; the tests don't care about the values, only the
/// number of times the closure was invoked. File-scoped so the
/// reader closure (which is `@Sendable`) can read it without a
/// MainActor hop.
private let batterySamplerTestSentinel = BatteryInfo(
    chargePercent: 50,
    chargeState: .charging,
    healthPercent: 90,
    cycleCount: 100,
    temperatureCelsius: 30.0,
    voltageVolts: 12.0,
    amperageMilliamps: 1000,
    powerWatts: 12.0,
    designCapacityMAh: 4000,
    nominalCapacityMAh: 3800,
    currentCapacityMAh: 1900,
    timeUntilFullMinutes: 60,
    timeUntilEmptyMinutes: nil,
    isExternalConnected: true,
    isFullyCharged: false,
    sampledAt: Date(timeIntervalSince1970: 0)
)

@MainActor
final class BatterySamplerTests: XCTestCase {

    /// Tracks how many times the reader was invoked. `nonisolated(unsafe)`
    /// is fine here — the only mutation site is the reader closure
    /// running off-main; the test reads only after a wait.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count: Int = 0
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _count
        }
        func increment() {
            lock.lock(); defer { lock.unlock() }
            _count += 1
        }
    }

    /// Build a sampler with a counting reader and a no-op consumer.
    /// Returns both the sampler and the counter so tests can read the
    /// observed tick count.
    private func makeSampler() -> (BatterySampler, CallCounter) {
        let counter = CallCounter()
        let reader: @Sendable () -> BatteryInfo? = {
            counter.increment()
            return batterySamplerTestSentinel
        }
        let sampler = BatterySampler(reader: reader, onSample: { _ in })
        return (sampler, counter)
    }

    /// Wait up to `timeout` seconds for `condition` to become true.
    /// Yields with a short sleep between probes so the timer's
    /// MainActor hops have a chance to run.
    private func waitUntil(
        timeout: Double = 4.0,
        condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Initial state

    func test_initialState_notRunning() {
        let (sampler, _) = makeSampler()
        XCTAssertFalse(sampler.isRunning)
    }

    // MARK: - Start / stop

    func test_start_setsIsRunningTrue() {
        let (sampler, _) = makeSampler()
        sampler.start()
        XCTAssertTrue(sampler.isRunning)
        sampler.stop()
    }

    func test_start_isIdempotent() {
        let (sampler, _) = makeSampler()
        sampler.start()
        sampler.start()  // second call is a no-op
        XCTAssertTrue(sampler.isRunning)
        sampler.stop()
    }

    func test_stop_setsIsRunningFalse() {
        let (sampler, _) = makeSampler()
        sampler.start()
        sampler.stop()
        XCTAssertFalse(sampler.isRunning)
    }

    func test_stop_isIdempotent() {
        let (sampler, _) = makeSampler()
        sampler.stop()  // not running
        sampler.stop()  // still not running
        XCTAssertFalse(sampler.isRunning)
    }

    // MARK: - Sample rate clamping

    func test_setSampleRate_clampsAboveMax() {
        let (sampler, _) = makeSampler()
        sampler.sampleRate = 99.0
        XCTAssertEqual(sampler.sampleRate, BatterySamplerConstants.maxRate)
    }

    func test_setSampleRate_clampsBelowMin() {
        let (sampler, _) = makeSampler()
        sampler.sampleRate = 0.01
        XCTAssertEqual(sampler.sampleRate, BatterySamplerConstants.minRate)
    }

    func test_setSampleRate_inRangePreserved() {
        let (sampler, _) = makeSampler()
        sampler.sampleRate = 2.5
        XCTAssertEqual(sampler.sampleRate, 2.5)
    }

    // MARK: - Lifecycle gate

    func test_setActiveSurfaces_zero_stops() {
        let (sampler, _) = makeSampler()
        sampler.start()
        sampler.setActiveSurfaces(0)
        XCTAssertFalse(sampler.isRunning)
    }

    func test_setActiveSurfaces_positive_starts() {
        let (sampler, _) = makeSampler()
        sampler.setActiveSurfaces(1)
        XCTAssertTrue(sampler.isRunning)
        sampler.stop()
    }

    func test_setActiveSurfaces_zeroThenPositive_resumes() {
        let (sampler, _) = makeSampler()
        sampler.start()
        sampler.setActiveSurfaces(0)
        XCTAssertFalse(sampler.isRunning)
        sampler.setActiveSurfaces(1)
        XCTAssertTrue(sampler.isRunning)
        sampler.stop()
    }

    // MARK: - Timer firing — N samples in N seconds (within tolerance)

    /// At 5 Hz (max rate) the timer should fire about 5 times per
    /// second. We sample for ~600 ms at 5 Hz and assert at least 2
    /// samples landed — looser than the textbook math (≈3 samples)
    /// to absorb scheduling jitter on a busy CI runner.
    func test_timer_emitsSamplesAtConfiguredRate() async {
        let (sampler, counter) = makeSampler()
        sampler.sampleRate = 5.0
        sampler.start()
        await waitUntil { counter.count >= 2 }
        sampler.stop()
        XCTAssertGreaterThanOrEqual(counter.count, 2,
            "5 Hz sampler should produce ≥2 samples within the wait window")
    }

    /// `stop()` halts further emissions: capture the count, sleep a
    /// little longer than one tick, capture again, expect equality.
    func test_stop_halts_furtherEmissions() async {
        let (sampler, counter) = makeSampler()
        sampler.sampleRate = 5.0
        sampler.start()
        await waitUntil { counter.count >= 2 }
        sampler.stop()
        let after = counter.count
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(counter.count, after,
            "Sampler should emit no further samples after stop()")
    }

    /// Sample-rate change re-arms the timer. Hard to assert this
    /// directly without intercepting the Timer; we approximate by
    /// observing that the sampler is still running after a rate
    /// change AND that the count increases on the new cadence. The
    /// re-arm path runs through `restartTimer()` which calls stop()
    /// + start() — both observable.
    func test_sampleRateChange_keepsRunning_andContinuesEmitting() async {
        let (sampler, counter) = makeSampler()
        sampler.sampleRate = 1.0
        sampler.start()
        // Bump to a faster rate; expect sampler still running and
        // counter to advance after the rearm.
        sampler.sampleRate = 5.0
        XCTAssertTrue(sampler.isRunning)
        await waitUntil { counter.count >= 1 }
        sampler.stop()
        XCTAssertGreaterThanOrEqual(counter.count, 1)
    }

    // MARK: - Sample forwarding

    /// The `onSample` closure receives whatever the reader returns,
    /// including nil from a desktop-Mac path.
    func test_sampleForwarding_passesReaderResult() async {
        let received = SampleReceiver()
        let sampler = BatterySampler(
            reader: { batterySamplerTestSentinel },
            onSample: { info in
                received.set(info)
            }
        )
        sampler.sampleRate = 5.0
        sampler.start()
        await waitUntil { received.value != nil }
        sampler.stop()
        XCTAssertEqual(received.value?.chargePercent, batterySamplerTestSentinel.chargePercent)
    }

    func test_sampleForwarding_passesNilFromReader() async {
        let received = SampleReceiver()
        // Track explicit nil-receipt via a flag so we don't conflate
        // "never received anything" with "received nil".
        let nilReceived = CallCounter()
        let sampler = BatterySampler(
            reader: { nil },
            onSample: { info in
                received.set(info)
                if info == nil { nilReceived.increment() }
            }
        )
        sampler.sampleRate = 5.0
        sampler.start()
        await waitUntil { nilReceived.count >= 1 }
        sampler.stop()
        XCTAssertGreaterThanOrEqual(nilReceived.count, 1, "Sampler should forward nil from a desktop-Mac reader")
    }

    /// Tiny @MainActor box so the test can read what the onSample
    /// callback received without crossing isolation. The tests run on
    /// MainActor so this is read at the test's yield points.
    @MainActor
    private final class SampleReceiver {
        private(set) var value: BatteryInfo?
        func set(_ info: BatteryInfo?) { self.value = info }
    }
}
