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
// EventService.swift
//
// Per SPEC.md §7 — the single source of `PortEvent` emissions for the
// whole app. Owns:
//
//   - `IOKitNotificationCenter` (and through it, the dedicated
//     CFRunLoop thread that IOKit notification ports require).
//   - The multiplexed `AsyncStream<PortEvent>` machinery — multiple
//     consumers each get their own stream; one yield-call dispatches
//     to all of them.
//
// `@unchecked Sendable` per SPEC.md §7's pre-approved exception. The
// IOKit-touching state is single-threaded by construction (only the
// notification center's dedicated thread invokes the callbacks); the
// continuation map is guarded by an `NSLock`. Reviewer pre-approved
// the unchecked annotation in §7 itself.
//
// Thread model:
//   - `init` registers IOUSBHostDevice notifications and synchronously
//     blocks until the dedicated thread is ready (handled by the
//     notification center).
//   - IOKit callbacks fire on the dedicated thread → `emit(_:)` yields
//     to every active stream continuation.
//   - Consumers iterate via `for await event in service.events()`,
//     which moves them onto whatever actor the loop runs in. AppDelegate
//     iterates on `@MainActor` so the per-event mutation hits MainActor
//     before touching `PortGraph`.

import Foundation
import IOKit
import os
import ManifoldKit

final class EventService: @unchecked Sendable {

    // MARK: - Dependencies

    /// Optional so tests can pass `nil` and skip IOKit registration
    /// (the live notification center spins up a dedicated CFRunLoop
    /// thread, which we don't want firing in CI). Production callers
    /// rely on the default-constructed instance.
    private let notificationCenter: IOKitNotificationCenter?

    // MARK: - State

    /// Lock for the continuations dict. Held briefly on every yield;
    /// IOKit callback frequency tops out at <100/s under stress (per
    /// the SPEC §18 Phase 3 hub-stress test), so contention is
    /// non-issue.
    private let lock = NSLock()

    /// Active subscriber continuations. Each `events()` call adds one.
    /// Closure-based termination handler removes the entry when the
    /// consumer cancels (`for await … in` loop break).
    private var continuations: [UUID: AsyncStream<PortEvent>.Continuation] = [:]

    /// Token returned by `notificationCenter.register(...)` for the
    /// IOUSBHostDevice subscription. Released on `shutdown()`.
    private var usbToken: NotificationToken?

    /// Phase 20: token for the `AppleSDXCBlockStorageDevice` subscription
    /// — fires on SD card insert / eject. Released on `shutdown()`.
    private var sdToken: NotificationToken?

    /// True once `shutdown()` has been called. Subsequent `requestRefresh`
    /// or `events()` calls become no-ops.
    private var stopped = false

    // MARK: - Init / shutdown

    /// Pass `notificationCenter: nil` for test mode — the multiplexed
    /// stream still works, hot-plug events just have to be injected via
    /// `inject(_:)`. Production constructs with the default-built
    /// `IOKitNotificationCenter()` which spawns the dedicated CFRunLoop
    /// thread and registers IOUSBHostDevice notifications.
    init(notificationCenter: IOKitNotificationCenter? = IOKitNotificationCenter()) {
        self.notificationCenter = notificationCenter
        guard notificationCenter != nil else {
            Log.events.debug("EventService initialised in test mode; no IOKit registrations.")
            return
        }
        do {
            try registerUSBNotifications()
            Log.events.notice("EventService initialised; IOUSBHostDevice notifications registered.")
        } catch {
            // Notification registration is the one path that can fail
            // at init time and we don't want a hard crash here — log
            // loudly and keep going. The .fullRefresh path still works,
            // so the app is degraded but functional.
            Log.events.error("EventService failed to register notifications: \(String(describing: error), privacy: .public)")
        }
        // Phase 20: SD card insert / eject subscription. Independent
        // of USB registration — soft-fails so the rest of EventService
        // stays functional on Macs without an internal SD reader (the
        // matching dict simply never fires `onMatch`).
        do {
            try registerSDCardNotifications()
            Log.events.notice("EventService initialised; AppleSDXCBlockStorageDevice notifications registered.")
        } catch {
            Log.events.error("EventService failed to register SD notifications: \(String(describing: error), privacy: .public)")
        }
    }

    /// Tear down notifications, stop the IOKit run loop, terminate every
    /// active stream. Idempotent.
    func shutdown() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let token = usbToken
        usbToken = nil
        let sdReleaseToken = sdToken
        sdToken = nil
        let conts = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()

        if let token, let nc = notificationCenter {
            nc.unregister(token)
        }
        if let sdReleaseToken, let nc = notificationCenter {
            nc.unregister(sdReleaseToken)
        }
        notificationCenter?.shutdown()

        for c in conts {
            c.finish()
        }

        Log.events.notice("EventService shutdown complete; iterators released, streams terminated.")
    }

    // MARK: - Public API (SPEC §7)

    /// Vend a fresh `AsyncStream<PortEvent>` for this caller. Multiple
    /// callers OK; each gets its own stream that sees the same events.
    /// Stream continues until the consumer's `for await` loop exits or
    /// `shutdown()` is called.
    func events() -> AsyncStream<PortEvent> {
        AsyncStream { continuation in
            let id = UUID()
            self.lock.lock()
            if self.stopped {
                self.lock.unlock()
                continuation.finish()
                return
            }
            self.continuations[id] = continuation
            self.lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    /// Trigger a `.fullRefresh` emission. The consumer is responsible
    /// for re-walking via `DiscoveryService.walk()` and calling
    /// `PortGraph.replace(...)`; `EventService` only emits the signal.
    /// Per SPEC §4.6.1's `.fullRefresh` behavior table.
    func requestRefresh() {
        emit(.fullRefresh)
    }

    // MARK: - IOKit notification handlers

    /// Register first-match + terminated notifications for IOUSBHostDevice.
    /// The first-match drain that happens during register fires once
    /// per currently-connected device — those land as `.attached`
    /// events to seed any active subscribers. (Phase 3 typical flow:
    /// AppDelegate calls `requestRefresh()` immediately after subscribing,
    /// which triggers the discovery walk → replace; the seed-attach
    /// events are coalesced into that replace.)
    private func registerUSBNotifications() throws {
        guard let nc = notificationCenter else { return }
        usbToken = try nc.register(
            matchingClass: USBDiscoveryConstants.hostDeviceClassName,
            onMatch: { [weak self] entry in
                self?.handleAttached(entry: entry)
            },
            onTerminated: { [weak self] entry in
                self?.handleDetached(entry: entry)
            }
        )
    }

    /// Phase 20: register first-match + terminated notifications for
    /// `AppleSDXCBlockStorageDevice` — the IOService node that
    /// represents an inserted SD card (child of `AppleSDXCSlot`).
    /// We don't synthesize a `.attached` / `.detached` event from
    /// the IOKit entry directly because the SD slot's identity isn't
    /// captured in our existing PortID-derived-from-USB-registry-path
    /// model. Instead, both insert and eject emit `.fullRefresh`,
    /// which triggers a full re-walk and lets the SD walker pick up
    /// the new state cleanly. The 200 ms IOReg-settle delay applied
    /// by AppDelegate before `rebuildGraph` covers chassis vs IOUSB
    /// propagation for the same reason it covers the USB side.
    ///
    /// On Macs without an internal SD reader the matching dictionary
    /// matches zero services and `onMatch` / `onTerminated` simply
    /// never fire. Registration itself succeeds (a no-op subscription).
    private func registerSDCardNotifications() throws {
        guard let nc = notificationCenter else { return }
        sdToken = try nc.register(
            matchingClass: "AppleSDXCBlockStorageDevice",
            onMatch: { [weak self] _ in
                self?.emit(.fullRefresh)
            },
            onTerminated: { [weak self] _ in
                self?.emit(.fullRefresh)
            }
        )
    }

    /// Build a `Device` from the IOKit entry and emit `.attached`.
    /// Reuses `USBWalker.makeSnapshot` + `PortGraphBuilder.makeDevice`
    /// so the hot-plug path produces identical Devices to the initial
    /// walk. Skipped silently if the entry has no VID — usually a
    /// stale orphan from rapid disconnect.
    private func handleAttached(entry: borrowing IOObject) {
        guard let snapshot = LiveIOKitUSBSource.makeSnapshot(from: entry) else {
            return
        }
        // Resolve mounted-volume names so a hot-plugged storage device's
        // friendly name (e.g. "PlanckSSD") is populated on the very
        // first `.attached` event, not delayed until the next walk.
        // The DA enumeration is fast — a handful of mounted volumes.
        let volumeNames = VolumeNameResolver.mountedVolumeNamesByDeviceModel()
        let device = PortGraphBuilder.makeDevice(
            from: snapshot,
            volumeNames: volumeNames,
            timestamp: .now
        )
        let portID = PortID(snapshot.registryPath)

        Log.events.notice(
            "attached \(snapshot.vendorID, format: .hex(minDigits: 4), privacy: .public):\(snapshot.productID, format: .hex(minDigits: 4), privacy: .public) — \(snapshot.productName ?? "<unnamed>", privacy: .public)"
        )
        emit(.attached(device, at: portID))
    }

    /// Build a `DeviceID` from the (still-readable) terminated entry
    /// and emit `.detached`. The terminated registry entry may have
    /// already lost some properties; we read what we can. If even VID
    /// is unreadable we drop silently — there's no useful event to
    /// emit without a stable ID.
    private func handleDetached(entry: borrowing IOObject) {
        guard let snapshot = LiveIOKitUSBSource.makeSnapshot(from: entry) else {
            return
        }
        let deviceID = DeviceID.make(
            vendorID: snapshot.vendorID,
            productID: snapshot.productID,
            serial: snapshot.serial,
            registryPath: snapshot.registryPath
        )
        let portID = PortID(snapshot.registryPath)

        Log.events.notice(
            "detached \(snapshot.vendorID, format: .hex(minDigits: 4), privacy: .public):\(snapshot.productID, format: .hex(minDigits: 4), privacy: .public) — \(snapshot.productName ?? "<unnamed>", privacy: .public)"
        )
        emit(.detached(deviceID: deviceID, from: portID))
    }

    // MARK: - Multiplexed yield

    /// Yield `event` to every active continuation. Snapshot-then-yield
    /// pattern: hold the lock only long enough to copy the dict
    /// values, then release before invoking `yield(_:)` — avoids
    /// holding the lock across consumer code that might re-enter
    /// `events()` synchronously.
    private func emit(_ event: PortEvent) {
        lock.lock()
        let conts = Array(continuations.values)
        lock.unlock()
        for c in conts {
            c.yield(event)
        }
    }

    // MARK: - Back-channel publisher (SPEC §8 wording)

    /// Inject a `PortEvent` into the multiplexed stream from outside
    /// the IOKit notification path. Per SPEC §8: "The sampler emits
    /// samples through the same `AsyncStream<PortEvent>` as
    /// `EventService`, via a back-channel publisher." `TelemetrySampler`
    /// uses this on every tick; `EventStreamTests` use it to script
    /// attach/detach sequences without spinning up the live CFRunLoop
    /// thread.
    ///
    /// Phase 3 named this `inject(_:)`; Phase 5 renamed to
    /// `inject(_:)` because production code (the sampler) is now also
    /// a legitimate caller. Same yield semantics as the IOKit-side
    /// path — every active continuation gets the event.
    func inject(_ event: PortEvent) {
        emit(event)
    }
}
