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
// DownsamplingJob.swift
//
// Per SPEC §10.2 + §18 Phase 10: 10-minute Timer-driven downsampler
// + retention sweeper. Each tick:
//   1. Promote raw → 1-min for raw rows older than `policy.rawRetention`.
//   2. Promote 1-min → 1-hour for 1-min rows older than `policy.oneMinRetention`.
//   3. Delete 1-hour rows older than `policy.oneHourRetention`.
//   4. Delete events older than the longest retention horizon (1 year).
//
// `start()` schedules the first tick on a 10-minute repeating Timer
// and ALSO fires one immediately so the first sweep doesn't have to
// wait for the cadence. `stop()` invalidates the timer and is
// idempotent.

import Foundation
import os

@MainActor
final class DownsamplingJob {

    /// 10 minutes per SPEC §10.2 final line.
    static let cadence: TimeInterval = 600

    private let sampleRepository: SampleRepository
    private let eventRepository: EventRepository
    private var policy: RetentionPolicy
    private var timer: Timer?

    init(
        sampleRepository: SampleRepository,
        eventRepository: EventRepository,
        policy: RetentionPolicy = .default
    ) {
        self.sampleRepository = sampleRepository
        self.eventRepository = eventRepository
        self.policy = policy
    }

    // MARK: - Lifecycle

    /// Schedule the repeating timer and fire one immediate tick.
    /// Idempotent — calling start() while running is a no-op.
    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.cadence,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tickAsync() }
        }
        self.timer = timer
        // Run one tick immediately so a fresh launch starts pruning
        // without waiting 10 minutes.
        tickAsync()
    }

    /// Invalidate the timer. Safe to call repeatedly.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Policy update

    /// Swap in a new retention policy (e.g., from the HistoryPane
    /// sliders). Takes effect on the next tick.
    func updatePolicy(_ newPolicy: RetentionPolicy) {
        policy = newPolicy
    }

    // MARK: - Tick

    /// MainActor `tick` wrapper that fires the async work without
    /// blocking the timer callback. Errors are logged + swallowed —
    /// retention is best-effort, and the next tick will retry.
    private func tickAsync() {
        Task { @MainActor [policy, sampleRepository, eventRepository] in
            do {
                let now = Date()
                _ = try await sampleRepository.downsampleRawTo1Min(
                    olderThan: policy.cutoffDate(for: .raw, now: now)
                )
                _ = try await sampleRepository.downsample1MinTo1Hour(
                    olderThan: policy.cutoffDate(for: .oneMin, now: now)
                )
                _ = try await sampleRepository.deleteOlderThan(
                    policy.cutoffDate(for: .oneHour, now: now),
                    aggregation: .oneHour
                )
                _ = try await eventRepository.deleteOlderThan(
                    policy.cutoffDate(for: .oneHour, now: now)
                )
            } catch {
                Log.app.error("DownsamplingJob tick failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
