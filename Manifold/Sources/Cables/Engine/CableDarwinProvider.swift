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
// Portions of this file derive from WhatCable
// (https://github.com/darrylmorley/whatcable) by Darryl Morley,
// originally distributed under the MIT licence. See
// `Manifold/Sources/Cables/ATTRIBUTION.md` for the full original
// copyright + permission notice.
//
// ─────────────────────────────────────────────────────────────────────
public import Foundation
import Combine

/// macOS implementation of `CableSnapshotProvider`. Wraps the four IOKit
/// watcher classes and assembles their state into a `CableSnapshot`.
///
/// `snapshot()` starts the watchers once, refreshes them, and reads.
/// `watch()` keeps them started and yields a fresh snapshot whenever any
/// watcher signals a state change via Combine `objectWillChange` — plus
/// a 5-second backstop poll as a safety net for any property-change
/// path the IOKit notifications might miss on unusual hardware. The
/// previous implementation polled every 1 s; the watchers themselves
/// are already event-driven (each registers `IOServiceAddMatching-
/// Notification` and most also register `IOServiceAddInterest-
/// Notification` for property changes), so the per-second wake was
/// pure waste in steady state.
public final class CableDarwinProvider: CableSnapshotProvider, @unchecked Sendable {
    public init() {}

    @MainActor
    private final class State {
        let portWatcher = CablePortWatcher()
        let powerWatcher = PowerSourceWatcher()
        let pdWatcher = PDIdentityWatcher()
        let usbWatcher = USBWatcher()
        let tbWatcher = ThunderboltWatcher()
        var started = false

        /// Active wakeup continuation for the `watch()` loop. Resumed
        /// when any watcher signals a change OR when the backstop
        /// timer fires. Single-shot — replaced on every iteration of
        /// the loop. Nil while the loop is running its body (between
        /// the previous wake and the next `waitForChange`).
        private var pendingWake: CheckedContinuation<Void, Never>?

        /// Combine subscriptions that sink each watcher's
        /// `objectWillChange` into `wake()`. Held strongly so the
        /// subscriptions live as long as the singleton state.
        private var cancellables: Set<AnyCancellable> = []

        func ensureStarted() {
            guard !started else { return }
            portWatcher.start()
            powerWatcher.start()
            pdWatcher.start()
            usbWatcher.start()
            tbWatcher.start()

            // Subscribe each watcher's `objectWillChange` to `wake()`
            // so any IOKit-driven mutation of a watcher's @Published
            // property unblocks the watch() loop. `objectWillChange`
            // fires synchronously on the main thread (the watchers
            // are MainActor-isolated), so the sink closure runs on
            // MainActor without an explicit hop.
            //
            // The sink fires BEFORE the @Published assignment lands,
            // but the loop's subsequent `state.read()` re-walks the
            // IORegistry independently — it doesn't depend on the
            // already-assigned @Published value — so the ordering is
            // benign.
            portWatcher.objectWillChange
                .sink { [weak self] in self?.wake() }
                .store(in: &cancellables)
            powerWatcher.objectWillChange
                .sink { [weak self] in self?.wake() }
                .store(in: &cancellables)
            pdWatcher.objectWillChange
                .sink { [weak self] in self?.wake() }
                .store(in: &cancellables)
            usbWatcher.objectWillChange
                .sink { [weak self] in self?.wake() }
                .store(in: &cancellables)
            tbWatcher.objectWillChange
                .sink { [weak self] in self?.wake() }
                .store(in: &cancellables)

            started = true
        }

        func read() -> CableSnapshot {
            // USBCPort property changes are now caught via the per-
            // port `IOServiceAddInterestNotification` registrations
            // inside `CablePortWatcher`, but the explicit refresh on
            // each read remains a cheap consistency guard. The other
            // watchers' refresh() calls are likewise notification-
            // driven but cheap to repeat.
            portWatcher.refresh()
            powerWatcher.refresh()
            pdWatcher.refresh()
            tbWatcher.refresh()
            return CableSnapshot(
                ports: portWatcher.ports,
                powerSources: powerWatcher.sources,
                identities: pdWatcher.identities,
                usbDevices: usbWatcher.devices,
                adapter: SystemPower.currentAdapter(),
                thunderboltSwitches: tbWatcher.switches
            )
        }

        /// Suspend until a watcher signals a change OR `backstopSeconds`
        /// elapses. The backstop covers the (theoretical) case where
        /// some hardware quirk causes a watcher's IOKit notification
        /// not to fire on a state change — a stale snapshot would
        /// otherwise persist until the next user-initiated refresh.
        func waitForChange(backstopSeconds: Double = 5.0) async {
            let backstopTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(backstopSeconds))
                // `try?` swallows `CancellationError`, so without this
                // guard the cancelled task's `wake()` would still fire
                // — racing back into the loop body and producing an
                // infinite poll instead of an idle 5 s wait.
                guard !Task.isCancelled else { return }
                self?.wake()
            }
            defer { backstopTask.cancel() }

            await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    pendingWake = cont
                }
            } onCancel: {
                // Outer task was cancelled (consumer dropped the
                // stream). Resume the continuation so the awaiting
                // task can finish promptly. The cancellation handler
                // is nonisolated, so hop to MainActor.
                Task { @MainActor [weak self] in self?.wake() }
            }
        }

        /// Resume the pending continuation if any. No-op when the
        /// loop body is mid-iteration (continuation is nil between
        /// wakes). Bursts collapse to one wake per loop turn.
        private func wake() {
            if let cont = pendingWake {
                pendingWake = nil
                cont.resume()
            }
        }
    }

    @MainActor
    private static let state = State()

    @MainActor
    public func snapshot() async throws -> CableSnapshot {
        Self.state.ensureStarted()
        return Self.state.read()
    }

    public func watch() -> AsyncThrowingStream<CableSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                Self.state.ensureStarted()
                var last: CableSnapshot? = nil
                while !Task.isCancelled {
                    let snap = Self.state.read()
                    if last != snap {
                        continuation.yield(snap)
                        last = snap
                    }
                    await Self.state.waitForChange()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

/// Default backend on Darwin platforms. CLI / GUI call this rather than
/// naming `CableDarwinProvider` directly.
public func makeDefaultSnapshotProvider() -> any CableSnapshotProvider {
    CableDarwinProvider()
}
