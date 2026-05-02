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
// TelemetrySampler.swift
//
// Per SPEC.md §8 — 1 Hz sampler (configurable 0.5–5.0 Hz). On each
// tick: walks IOKit via the existing `USBWalker`, builds a
// `TelemetrySample` per discovered device, and pushes it into the
// `EventService` stream as a `.telemetry(portID, sample)` event.
//
// Why re-walk IOKit each tick (versus caching `IOObject` handles per
// port): a fresh walk costs ~0.2 ms on M1 Max (Phase 1 leak-bench
// metrics) — well under the SPEC §18 Phase 5 acceptance #4 of "<1%
// CPU at idle". Cached IOKit handles would need lifetime management
// across hot-plug events (handles invalidate on disconnect) and
// double the IOKit-retain surface; not worth the complexity at this
// scale.
//
// `@MainActor` per SPEC §8. The Timer-driven tick scheduling and the
// `EventService.inject(_:)` call both happen on the main actor; the
// USBWalker work is brief enough that yielding it to a background
// queue would cost more in actor hops than we save in main-thread
// time. Phase 5+ profiling can revisit if a heavy device tree shows
// up in CPU samples.

import Foundation
import os
import ManifoldKit

@MainActor
final class TelemetrySampler {

    // MARK: - Dependencies

    private let walker: USBWalker
    private let eventService: EventService

    // MARK: - State

    private var timer: Timer?

    /// Hertz. Defaults to 1.0 per SPEC §8; `setSampleRate(_:)` clamps
    /// to [0.5, 5.0]. Direct assignment via `var` triggers the same
    /// clamp + restart logic via `didSet` — the recursion is bounded
    /// by the clamp guard (first call: clamps if needed; second
    /// call: equal-to-clamped, no further recursion).
    var sampleRate: Double = TelemetrySamplerConstants.defaultRate {
        didSet {
            let clamped = clamp(sampleRate)
            guard clamped == sampleRate else {
                // Recurse once with the in-range value; the next
                // didSet sees clamped == sampleRate and falls
                // through to the restart branch.
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

    init(walker: USBWalker = USBWalker(), eventService: EventService) {
        self.walker = walker
        self.eventService = eventService
    }

    // No deinit cleanup — Swift 6 strict concurrency forbids
    // accessing `Timer?` (not Sendable) from a nonisolated deinit.
    // Callers (SamplerLifecycle.shutdown / AppDelegate.applicationWillTerminate)
    // are responsible for calling `stop()`. The Timer's closure
    // captures `[weak self]` so a missed `stop()` doesn't leak the
    // sampler — the timer just becomes a no-op.

    // MARK: - Public API (SPEC §8)

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
    /// calls this on every surface event.
    func setActiveSurfaces(_ count: Int) {
        if count > 0 { start() } else { stop() }
    }

    // MARK: - Timer

    private func scheduleTimer() {
        let interval = 1.0 / sampleRate
        // Timer.scheduledTimer registers on the current run loop in
        // .common mode by default — fine for MainActor. The closure
        // hops back to MainActor explicitly so the actor isolation
        // is preserved (Timer's closure is otherwise nonisolated).
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

    /// One sampler tick. Walks IOKit, builds one TelemetrySample per
    /// device, pushes via `EventService.inject`. Errors logged and
    /// swallowed — a single failed walk shouldn't kill the sampler.
    private func tick() {
        guard let snapshots = try? walker.walk() else {
            Log.events.debug("TelemetrySampler: walk failed; skipping tick")
            return
        }
        let now = Date()
        for snapshot in snapshots {
            let sample = TelemetrySample(
                timestamp: now,
                watts: snapshot.requestedPowerMA.map {
                    Watts.fromMilliamps($0, atVolts: USBBusVoltage.standard)
                },
                bitrate: snapshot.speed.map(PortGraphBuilder.bitrate(forSpeedCode:))
            )
            eventService.inject(.telemetry(PortID(snapshot.registryPath), sample))
        }
    }

    // MARK: - Helpers

    private func clamp(_ rate: Double) -> Double {
        max(min(rate, TelemetrySamplerConstants.maxRate), TelemetrySamplerConstants.minRate)
    }
}

// MARK: - Constants

enum TelemetrySamplerConstants {
    /// SPEC §8: "Default 1.0 Hz."
    static let defaultRate: Double = 1.0

    /// SPEC §8: "Range enforced [0.5, 5.0]."
    static let minRate: Double = 0.5
    static let maxRate: Double = 5.0
}
