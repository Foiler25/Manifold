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
// BatterySampler.swift
//
// Slow safety-net poll for the AppleSmartBattery IORegistry-only
// fields — temperature, voltage, cycle count, raw mAh, instantaneous
// current / power. The fast path (percent, charging state, plug /
// unplug, time-remaining) is push-driven by `BatteryNotificationObserver`
// via `IOPSNotificationCreateRunLoopSource`, so this sampler exists
// purely to refresh the secondary fields the notification API does
// not publish.
//
// Always-on at a single rate — no foreground / background split, no
// `SamplerLifecycle` gate. The IOPS-driven path covers everything the
// menu-bar icon and alert engine react to; this sampler's only job is
// keeping the BatteryView's stat cells from going stale on a quiet
// machine. 1 Hz default keeps the steady-state cost negligible while
// matching the kernel's actual update cadence well enough that the
// numbers track real hardware within a second.
//
// `@MainActor` so the consumer callback fires on MainActor — the
// Timer's closure is otherwise nonisolated, so we hop explicitly.

import Foundation
import ManifoldKit

@MainActor
final class BatterySampler {

    // MARK: - Dependencies

    /// Closure that reads a fresh battery snapshot. Production wires
    /// `BatterySnapshotReader.currentSnapshot`; tests inject a fake
    /// `() -> BatteryInfo?` returning a programmable value so the
    /// timer can fire without IOKit.
    private let reader: @Sendable () -> BatteryInfo?

    /// Forwarded each sample to the consumer (production: AppDelegate
    /// → `portGraph.applyBattery(_:)`). Runs on MainActor.
    private let onSample: @MainActor (BatteryInfo?) -> Void

    // MARK: - State

    private var timer: Timer?

    /// Hertz. `didSet` clamps to `[minRate, maxRate]` and re-arms the
    /// timer when the value actually changes (the recursion is bounded
    /// — first call clamps, second call sees clamped == sampleRate
    /// and falls through).
    var sampleRate: Double = BatterySamplerConstants.defaultRate {
        didSet {
            let clamped = clamp(sampleRate)
            guard clamped == sampleRate else {
                sampleRate = clamped
                return
            }
            if oldValue != sampleRate, timer != nil {
                restartTimer()
            }
        }
    }

    /// True while the timer is scheduled. Read-only externally —
    /// callers control via `start()` / `stop()`.
    var isRunning: Bool { timer != nil }

    // MARK: - Init

    /// Production-flavor convenience: reads via
    /// `BatterySnapshotReader.currentSnapshot`. The `reader:` /
    /// `onSample:` overload is preferred in tests.
    convenience init(onSample: @escaping @MainActor (BatteryInfo?) -> Void) {
        self.init(
            reader: { BatterySnapshotReader.currentSnapshot() },
            onSample: onSample
        )
    }

    /// DI-friendly init — tests inject a programmable reader closure
    /// + assertion-friendly onSample callback.
    init(
        reader: @escaping @Sendable () -> BatteryInfo?,
        onSample: @escaping @MainActor (BatteryInfo?) -> Void
    ) {
        self.reader = reader
        self.onSample = onSample
    }

    // No deinit cleanup — Swift 6 strict concurrency forbids accessing
    // `Timer?` (not Sendable) from a nonisolated deinit. Callers
    // (`AppDelegate.applicationWillTerminate`) are responsible for
    // calling `stop()`. The Timer's closure captures `[weak self]` so
    // a missed `stop()` doesn't leak the sampler — the timer just
    // becomes a no-op.

    // MARK: - Public API

    /// Start the periodic sampler. No-op if already running.
    func start() {
        guard timer == nil else { return }
        scheduleTimer()
    }

    /// Stop the periodic sampler. Idempotent.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Timer

    private func scheduleTimer() {
        let interval = 1.0 / sampleRate
        // Timer.scheduledTimer registers on the current run loop in
        // .common mode by default — fine for MainActor. The closure
        // hops back to MainActor explicitly so the actor isolation is
        // preserved (Timer's closure is otherwise nonisolated).
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        timer = t
    }

    private func restartTimer() {
        stop()
        start()
    }

    /// One sampler tick. Calls the injected reader closure and forwards
    /// the result. Reader may run nonisolated (production: the
    /// `nonisolated static` `currentSnapshot()` on
    /// `BatterySnapshotReader`); the result lands on MainActor before
    /// being forwarded to `onSample`.
    private func tick() {
        let reader = self.reader
        let sample = reader()
        onSample(sample)
    }

    // MARK: - Helpers

    private func clamp(_ rate: Double) -> Double {
        max(min(rate, BatterySamplerConstants.maxRate), BatterySamplerConstants.minRate)
    }
}

// MARK: - Constants

enum BatterySamplerConstants {
    /// Default 1 Hz. Push-driven `BatteryNotificationObserver` covers
    /// the fast path (state changes — percent, charging, plug/unplug)
    /// at near-zero latency, so this sampler exists only to keep the
    /// secondary IORegistry-only fields (temperature, voltage, cycle
    /// count, instantaneous current / power) refreshed on a quiet
    /// machine. The kernel publishes those fields every several
    /// seconds at most, so 1 Hz catches every real update with at
    /// most ~1 s of latency while keeping the cost trivial.
    static let defaultRate: Double = 1.0

    /// User-facing slider range. Lower bound is "every 5 s" — slow
    /// enough that idle cost is invisible. Upper bound is 2 Hz
    /// because the kernel never publishes faster than that, and
    /// allowing higher rates just polls the same numbers more often.
    static let minRate: Double = 0.2
    static let maxRate: Double = 2.0
}
