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
// Phase 18 — sibling of `TelemetrySampler`. Same shape (timer-driven,
// configurable 0.5–5 Hz, idempotent start/stop, `setActiveSurfaces(_:)`
// lifecycle gate, sample-rate change re-arms the timer) but a separate
// rate, separate AppStorage key, separate sampling target.
//
// Per D18: independent rate from `TelemetrySampler` (battery state
// changes slowly; users may want 0.5 Hz battery sampling alongside 5 Hz
// USB telemetry, or vice versa). Same `SamplerLifecycle` gate so both
// pause when no UI surface is visible.
//
// `@MainActor` per the parallel SPEC §8 / §20.4 contracts. The Timer
// callback hops back to MainActor explicitly so the actor isolation is
// preserved (Timer's closure is otherwise nonisolated).

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
    /// → `portGraph.applyBattery(_:)`). Runs on MainActor — the
    /// MainActor isolation of this class plus the explicit
    /// `@MainActor` annotation on the closure together guarantee
    /// the consumer sees the sample on the main thread.
    private let onSample: @MainActor (BatteryInfo?) -> Void

    // MARK: - State

    private var timer: Timer?

    /// Hertz. Defaults to 1.0 per D18; `didSet` clamps to
    /// `[0.5, 5.0]` and re-arms the timer if the value actually
    /// changed (the recursion is bounded — first call clamps,
    /// second call sees clamped == sampleRate and falls through).
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
    /// callers control via `start()` / `stop()` /
    /// `setActiveSurfaces(_:)`.
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
    /// + assertion-friendly onSample callback. Per SPEC §20.4.
    init(
        reader: @escaping @Sendable () -> BatteryInfo?,
        onSample: @escaping @MainActor (BatteryInfo?) -> Void
    ) {
        self.reader = reader
        self.onSample = onSample
    }

    // No deinit cleanup — Swift 6 strict concurrency forbids accessing
    // `Timer?` (not Sendable) from a nonisolated deinit. Callers
    // (SamplerLifecycle.shutdown / AppDelegate.applicationWillTerminate)
    // are responsible for calling `stop()`. The Timer's closure
    // captures `[weak self]` so a missed `stop()` doesn't leak the
    // sampler — the timer just becomes a no-op.

    // MARK: - Public API (SPEC §20.4)

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

    /// Map an active-surface count to start/stop. SamplerLifecycle
    /// calls this on every surface event in lockstep with the parallel
    /// `TelemetrySampler.setActiveSurfaces` so both samplers pause
    /// together (per D18 — same lifecycle gate, independent rates).
    func setActiveSurfaces(_ count: Int) {
        if count > 0 { start() } else { stop() }
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
    /// D18 / SPEC §20.4: "Default 1.0 Hz."
    static let defaultRate: Double = 1.0

    /// D18 / SPEC §20.4: "Range enforced [0.5, 5.0]."
    static let minRate: Double = 0.5
    static let maxRate: Double = 5.0
}
