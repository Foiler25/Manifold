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
// CableEngine.swift
//
// Phase 21 — `@MainActor @Observable` adapter that bridges the absorbed
// cable-diagnostics provider (`CableSnapshotProvider`, default
// `CableDarwinProvider`) into Manifold's UI layer.
//
// The provider emits `CableSnapshot` values via an `AsyncThrowingStream`.
// `CableEngine` consumes that stream on a `Task`, drops each snapshot
// onto its `@Observable snapshot` property, and surfaces any error in
// `lastError`. `CablesView` and friends bind to those properties.
//
// Lifecycle: `start()` is idempotent — repeat calls are no-ops while the
// engine is already running. `stop()` cancels the Task; the provider
// stream's `onTermination` handler tears down the underlying IOKit
// notifications. Together this matches Manifold's "samplers pause when
// no UI surface is visible" contract — see `CableEngineLifecycle`.
//
// Concurrency boundary:
//   - `CableSnapshot` lives in absorbed code with a `// TODO: Sendable`
//     comment. The struct is composed of plain value types that are
//     conceptually `Sendable`, but the upstream author hasn't added the
//     conformance yet. We declare an `@unchecked Sendable` extension at
//     the bottom of this file so the stream can cross the actor hop.
//     This is the only place outside `CableDarwinProvider.swift` that
//     uses `@unchecked Sendable` — see DECISIONS.md D24.

import Foundation
import os

@MainActor
@Observable
final class CableEngine {

    // MARK: - Observable state

    /// Latest snapshot from the provider. `nil` before the first
    /// successful read. SwiftUI views bind to this directly.
    private(set) var snapshot: CableSnapshot?

    /// Most-recent error from the provider stream. Cleared on each
    /// successful snapshot. Surfaced in the Cables tab as a banner.
    private(set) var lastError: Error?

    /// True between `start()` and `stop()`. Idempotency check + UI hint.
    private(set) var isRunning: Bool = false

    // MARK: - Dependencies

    /// Stored as `any CableSnapshotProvider` so tests can swap in a
    /// fake. Production callers use the default-init that constructs
    /// a `CableDarwinProvider`.
    private let provider: any CableSnapshotProvider

    /// The currently-running consumer task. `nil` when stopped.
    private var consumerTask: Task<Void, Never>?

    /// Bootstrap fetch task. Runs in parallel with the watch consumer
    /// to seed `snapshot` within ~50ms instead of waiting up to the
    /// provider's full 1s poll cycle.
    private var bootstrapTask: Task<Void, Never>?

    // MARK: - Init

    init(provider: any CableSnapshotProvider = CableDarwinProvider()) {
        self.provider = provider
    }

    // MARK: - Lifecycle

    /// Starts consuming the provider's `watch()` stream. Idempotent.
    /// Each yielded snapshot lands on `self.snapshot` on the main
    /// actor. Stream errors land on `self.lastError` and end the task.
    func start() {
        guard !isRunning else {
            Log.app.info("CableEngine.start — already running, no-op")
            return
        }
        isRunning = true
        Log.app.info("CableEngine.start — begin")

        // Bootstrap: do an immediate `snapshot()` call so the UI
        // doesn't sit on the empty-state for the full poll cycle.
        // Runs in parallel with the watch() consumer; even if the
        // watch loop also yields the same snapshot first, the result
        // is idempotent (writing the same value twice is harmless).
        let provider = self.provider
        bootstrapTask = Task { [weak self] in
            do {
                let snap = try await provider.snapshot()
                await MainActor.run {
                    guard let self else { return }
                    if self.snapshot == nil {
                        self.snapshot = snap
                        Log.app.info("CableEngine.bootstrap — first snapshot delivered (\(snap.ports.count, privacy: .public) ports)")
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.lastError = error
                    Log.app.error("CableEngine.bootstrap — snapshot() threw: \(String(describing: error), privacy: .public)")
                }
            }
        }

        let stream = provider.watch()
        consumerTask = Task { [weak self] in
            Log.app.info("CableEngine.consumer — task started, awaiting first yield")
            do {
                for try await snap in stream {
                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        guard let self else { return }
                        let wasNil = self.snapshot == nil
                        self.snapshot = snap
                        self.lastError = nil
                        if wasNil {
                            Log.app.info("CableEngine.consumer — first watch() yield received (\(snap.ports.count, privacy: .public) ports)")
                        }
                    }
                }
                Log.app.info("CableEngine.consumer — stream finished cleanly")
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.lastError = error
                    Log.app.error("CableEngine.consumer — stream threw: \(String(describing: error), privacy: .public)")
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.isRunning = false
            }
        }
    }

    /// Cancels the consumer task. The provider stream's
    /// `onTermination` handler tears down IOKit watchers as a side
    /// effect of cancellation. Idempotent.
    func stop() {
        Log.app.info("CableEngine.stop — cancelling tasks")
        consumerTask?.cancel()
        consumerTask = nil
        bootstrapTask?.cancel()
        bootstrapTask = nil
        isRunning = false
    }
}

// MARK: - Sendability boundary

/// `CableSnapshot` is composed of value types that are conceptually
/// `Sendable` but the absorbed code hasn't added the explicit
/// conformance yet (see the `// TODO: Sendable` comment on the
/// upstream type). The struct is immutable post-init, never mutated
/// through reference semantics, and only crosses the actor boundary
/// when yielded by `provider.watch()` — so an `@unchecked` declaration
/// is safe. Tracked in DECISIONS.md D24; refactored away when
/// the upstream conformance is added or contributed.
extension CableSnapshot: @unchecked Sendable {}
