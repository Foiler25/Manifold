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
// SnapshotCoordinator.swift
//
// Per SPEC §18 Phase 13 #3: "writes snapshot.json atomically on
// every PortGraph update (debounced to ≤2 Hz to avoid widget reload
// thrash)". This class owns the debounce timer, the disk write
// pipeline, and the WidgetKit reload trigger.
//
// Why ≤2 Hz: WidgetKit's reload budget is generous but not free;
// hot-plug churn or a 1-Hz telemetry tick that mutates `powerDraw`
// would otherwise produce one snapshot write + one widget reload
// per second. 500ms debounce coalesces those into ≤2 writes per
// second worst-case, well under the system's reload throttling.
//
// AppDelegate calls `requestUpdate()` whenever it has a reason to
// believe the graph changed (post-walk, post-event, after a
// diagnostic re-run); the coordinator schedules a debounced write
// + reload. Cancellation on shutdown leaves the on-disk file in
// whatever state the last successful write produced.

import Foundation
import WidgetKit
import os
import ManifoldKit

@MainActor
final class SnapshotCoordinator {

    /// 500 ms debounce window. SPEC §18 #3 caps at 2 Hz; this is
    /// the matching interval. Longer would reduce widget freshness
    /// without measurable savings; shorter would risk hitting
    /// WidgetKit's reload throttling.
    static let debounceInterval: TimeInterval = 0.5

    private weak var graph: PortGraph?
    private let containerURL: URL?
    private var pendingTask: Task<Void, Never>?
    private var lastEventAt: Date?

    /// Tracks the last successfully-written snapshot's payload so a
    /// repeat update with no observable change skips the disk
    /// write. Optional because the first write has no baseline.
    /// `SnapshotV1: Equatable` makes the dedup compare cheap.
    private var lastWrittenPayload: SnapshotV1?

    init(graph: PortGraph, containerURL: URL? = Snapshot.resolvedContainerURL()) {
        self.graph = graph
        self.containerURL = containerURL
    }

    // MARK: - Public surface

    /// Schedule a debounced snapshot write. Subsequent calls inside
    /// the debounce window collapse into one write (the last call's
    /// graph snapshot wins). Caller is AppDelegate's event consumer
    /// + rebuildGraph paths.
    func requestUpdate() {
        pendingTask?.cancel()
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(SnapshotCoordinator.debounceInterval))
            guard !Task.isCancelled else { return }
            self?.performWrite()
        }
    }

    /// Update the cached "most recent event timestamp" without
    /// scheduling a write. Lets AppDelegate keep `lastEventAt`
    /// fresh on every event arrival; `requestUpdate()` later
    /// includes it in the snapshot.
    func recordEventTimestamp(_ date: Date) {
        lastEventAt = date
    }

    /// Cancel any pending debounce. Called from
    /// `AppDelegate.applicationWillTerminate` so a half-pending
    /// write doesn't fire after the app is on its way out.
    func shutdown() {
        pendingTask?.cancel()
        pendingTask = nil
    }

    // MARK: - Write pipeline

    private func performWrite() {
        guard let graph, let containerURL else { return }
        // Stamp `writtenAt = .now` once per write so a no-op rewrite
        // would only differ in that field — dedup against the prior
        // payload using a `writtenAt`-normalized comparison so an
        // idle Mac doesn't churn snapshots forever.
        let snapshot = SnapshotPublisher.makeSnapshot(
            from: graph,
            lastEventAt: lastEventAt
        )
        if let lastWrittenPayload, isEffectivelyEqual(snapshot, lastWrittenPayload) {
            return
        }
        do {
            try Snapshot.v1(snapshot).write(to: containerURL)
            lastWrittenPayload = snapshot
            // SPEC §18 Phase 13 #8: reload all timelines when the
            // snapshot changes. WidgetCenter is process-wide; the
            // reload propagates to every active widget instance.
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            Log.app.error("SnapshotCoordinator write failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Compare two snapshot payloads ignoring `writtenAt` (which
    /// changes every call by definition). All other fields drive
    /// widget visuals, so any difference there is a real reason to
    /// rewrite + reload.
    private func isEffectivelyEqual(_ lhs: SnapshotV1, _ rhs: SnapshotV1) -> Bool {
        lhs.totalPowerDraw == rhs.totalPowerDraw
            && lhs.connectedDeviceCount == rhs.connectedDeviceCount
            && lhs.activeDiagnosticCount == rhs.activeDiagnosticCount
            && lhs.lastEventAt == rhs.lastEventAt
            && lhs.topDevicesByPower == rhs.topDevicesByPower
    }
}
