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
// BatteryNotificationObserver.swift
//
// Push-driven replacement for the previous BatterySampler timer for
// power-source state changes. Subscribes to
// `IOPSNotificationCreateRunLoopSource` — macOS publishes a
// notification the moment the kernel observes a change to any power-
// source attribute exposed via IOPS (percent, charging state,
// time-remaining, external-power flip). The callback fires on the
// main run loop; we hop to MainActor and forward a fresh
// `BatterySnapshotReader.currentSnapshot()` to the consumer.
//
// IOPS does NOT publish updates for AppleSmartBattery-only fields
// (temperature, voltage, cycle count, instantaneous current /
// power). Those continue to flow through the slow `BatterySampler`
// safety poll. This observer covers the fast-path: anything that
// drives the menu-bar icon, the alert engine, or popover state
// transitions.

import Foundation
import IOKit
import IOKit.ps
import ManifoldKit
import os

@MainActor
final class BatteryNotificationObserver {

    /// Consumer callback — invoked on MainActor each time IOPS
    /// publishes a new state. Argument is whatever
    /// `BatterySnapshotReader.currentSnapshot()` reads at that moment.
    /// Nil on desktop Macs (no AppleSmartBattery service).
    private let onSnapshot: @MainActor (BatteryInfo?) -> Void

    /// Snapshot reader. Default reads via `BatterySnapshotReader`;
    /// tests inject a fake closure to drive the observer without
    /// touching real IOKit.
    private let reader: @Sendable () -> BatteryInfo?

    /// CFRunLoopSource returned by `IOPSNotificationCreateRunLoopSource`.
    /// `+1` retained on receipt; we release in `stop()` via Unmanaged.
    private var runLoopSource: CFRunLoopSource?

    /// Has the observer been torn down? Guards against late-firing
    /// callbacks racing with `stop()`.
    private var isShutDown: Bool = false

    // MARK: - Init

    /// Production path — reads via `BatterySnapshotReader.currentSnapshot`.
    convenience init(onSnapshot: @escaping @MainActor (BatteryInfo?) -> Void) {
        self.init(
            reader: { BatterySnapshotReader.currentSnapshot() },
            onSnapshot: onSnapshot
        )
    }

    /// DI-friendly init — tests inject a programmable reader. The
    /// observer registers the IOPS run-loop source on init so the
    /// callback is wired up before the first `start()`-equivalent
    /// event arrives. Mirrors the SDCardSlotInterestObserver shape.
    init(
        reader: @escaping @Sendable () -> BatteryInfo?,
        onSnapshot: @escaping @MainActor (BatteryInfo?) -> Void
    ) {
        self.reader = reader
        self.onSnapshot = onSnapshot
        register()
    }

    // MARK: - Lifecycle

    /// Tear down the IOPS subscription. Safe to call multiple times.
    /// Wired to `applicationWillTerminate` in AppDelegate.
    func stop() {
        guard !isShutDown else { return }
        isShutDown = true
        if let source = runLoopSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                source,
                CFRunLoopMode.defaultMode
            )
            // `IOPSNotificationCreateRunLoopSource` returns a +1
            // retained reference. Match it here.
            runLoopSource = nil
        }
    }

    /// Force a fresh read + delivery now. AppDelegate calls this once
    /// at startup so the graph has a non-nil battery snapshot before
    /// the first organic IOPS event lands. Idempotent — safe to call
    /// after `stop()` (becomes a no-op).
    func deliverInitialSnapshot() {
        guard !isShutDown else { return }
        deliver()
    }

    // MARK: - Internals

    private func register() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanaged = IOPSNotificationCreateRunLoopSource(
            { ctx in
                BatteryNotificationObserver.bridgeCallback(ctx: ctx)
            },
            context
        ) else {
            Log.app.error("BatteryNotificationObserver: IOPSNotificationCreateRunLoopSource returned nil")
            return
        }
        let source = unmanaged.takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.defaultMode)
        self.runLoopSource = source
        Log.app.info("BatteryNotificationObserver: subscribed to IOPS notifications")
    }

    /// C-callback bridge. IOPS hands us the context pointer we passed
    /// at registration; recover the observer and hop to MainActor to
    /// fetch + deliver the new snapshot.
    private nonisolated static func bridgeCallback(ctx: UnsafeMutableRawPointer?) {
        guard let ctx else { return }
        let observer = Unmanaged<BatteryNotificationObserver>.fromOpaque(ctx).takeUnretainedValue()
        Task { @MainActor in
            observer.deliver()
        }
    }

    private func deliver() {
        guard !isShutDown else { return }
        let snapshot = reader()
        onSnapshot(snapshot)
    }
}
