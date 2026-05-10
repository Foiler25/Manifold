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
// SamplerLifecycle.swift
//
// Per SPEC.md §8: tracks active UI surfaces (popover open, window
// visible, widget reload pending) and pauses the USB telemetry
// sampler when the count hits zero. Satisfies SPEC §18 Phase 5
// acceptance #3.
//
// Why a counter, not a set: a UI surface might fire its "did open"
// callback twice (popover that auto-reopens after a transient close),
// and we want the sampler to stay running across that race. The
// counter approach is robust to bursts; only when the count
// genuinely drops to zero do we stop.
//
// Battery sampling does not go through this gate — both push paths
// (`BatteryInterestObserver` for kIOGeneralInterest on
// AppleSmartBattery and `BatteryNotificationObserver` for IOPS) run
// always-on, and `applyBattery(_:)` is idempotent on duplicate
// values.

import Foundation

@MainActor
final class SamplerLifecycle {

    // MARK: - State

    /// Sampler this lifecycle drives. Held weakly so a sampler can
    /// outlive the lifecycle (or vice versa) without a retain cycle.
    private weak var sampler: TelemetrySampler?

    /// Active surface count. `private(set)` so tests can observe
    /// without exposing a setter.
    private(set) var activeSurfaceCount: Int = 0

    /// Pending widget-reload pulse tasks. Cancelled if `shutdown`
    /// fires while a 5 s window is still active. Keyed by UUID so
    /// each task can prune its own slot on completion (Task is a
    /// value type, so ObjectIdentifier doesn't apply; UUID is the
    /// next-simplest identifier). F15 closure (Phase 5 review).
    private var pendingWidgetTasks: [UUID: Task<Void, Never>] = [:]

    /// Has the lifecycle been shut down? Subsequent calls are no-ops
    /// after the first shutdown.
    private(set) var isShutDown: Bool = false

    // MARK: - Init

    init(sampler: TelemetrySampler? = nil) {
        self.sampler = sampler
    }

    /// Late-binding setter so AppDelegate can construct lifecycle and
    /// sampler in either order without a circular init.
    func attach(sampler: TelemetrySampler) {
        self.sampler = sampler
        // If a surface is already active when we attach, kick the
        // sampler so it starts immediately.
        applyState()
    }

    // MARK: - Surface events

    func popoverDidOpen() {
        increment()
    }

    func popoverDidClose() {
        decrement()
    }

    func windowDidAppear() {
        increment()
    }

    func windowDidDisappear() {
        decrement()
    }

    /// Brief active window so a widget snapshot reload sees fresh
    /// data. SPEC §8: "widgetReloadRequested → brief 5s active window
    /// for snapshot freshness." After 5 seconds the surface count
    /// decrements again — typically back to zero (no popover/window
    /// open), pausing the sampler.
    func widgetReloadRequested() {
        increment()
        // F15 closure (Phase 5 review, due Phase 13): each pulse
        // task removes its own dictionary slot on completion. The
        // earlier `removeAll { $0.isCancelled }` only pruned
        // cancelled tasks, leaking handles for every successful
        // reload pulse.
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(SamplerLifecycleConstants.widgetReloadActiveWindow))
            guard let self else { return }
            self.decrement()
            self.pendingWidgetTasks.removeValue(forKey: id)
        }
        pendingWidgetTasks[id] = task
    }

    /// Cancel any pending widget pulse, drop count to zero, stop the
    /// sampler. Intended for `applicationWillTerminate` cleanup.
    /// Idempotent.
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        for task in pendingWidgetTasks.values { task.cancel() }
        pendingWidgetTasks.removeAll()
        activeSurfaceCount = 0
        sampler?.stop()
    }

    // MARK: - Internals

    private func increment() {
        guard !isShutDown else { return }
        activeSurfaceCount += 1
        applyState()
    }

    private func decrement() {
        guard !isShutDown else { return }
        // Floor at 0 in case of unbalanced did-open/did-close pairs —
        // belt-and-braces against UI lifecycle quirks.
        if activeSurfaceCount == 0 {
            return
        }
        activeSurfaceCount -= 1
        applyState()
    }

    /// Translate `activeSurfaceCount` into a sampler start/stop call.
    /// Idempotent — `start()` and `stop()` are no-ops when already in
    /// the requested state.
    private func applyState() {
        let active = activeSurfaceCount > 0
        if let sampler {
            if active { sampler.start() } else { sampler.stop() }
        }
    }
}

// MARK: - Constants

enum SamplerLifecycleConstants {
    /// SPEC §8: "brief 5s active window for snapshot freshness." Used
    /// by `widgetReloadRequested()` to keep the sampler alive long
    /// enough for the widget timeline provider to read.
    static let widgetReloadActiveWindow: Double = 5.0
}
