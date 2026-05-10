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
// BatteryInterestObserver.swift
//
// Push-driven observer for the AppleSmartBattery service via
// `IOServiceAddInterestNotification(..., kIOGeneralInterest, ...)`.
// macOS's AppleSmartBattery driver fires the interest callback on
// every property update — percent, charging state, plug state,
// temperature, voltage, instantaneous current/power, cycle count,
// raw mAh — so this observer covers every field the BatteryView
// surfaces, including the IOPS-API-only ones (state) AND the
// AppleSmartBattery-only ones (temperature, voltage, etc.).
//
// Validated empirically with a 39-hour bake (Phase 21.7 PoC, May
// 2026): 712 callbacks delivered diffs covering pct, state, ext,
// mA, V, W, °C, hp, mAh, and time-remaining values; the underlying
// IOKit message type was uniformly `kIOPMMessageBatteryStatusHasChanged`
// (0xE0024100). Roughly 20–35 % of callbacks have an empty diff
// (lifecycle / non-property events), so this observer skips
// forwarding when the visible fields are unchanged.
//
// `BatteryNotificationObserver` (IOPS) is kept registered alongside
// this one as belt-and-suspenders: if a future macOS revision
// changes how AppleSmartBattery exposes interest notifications, the
// IOPS path keeps the menu-bar icon and alert engine alive on the
// well-documented public API.
//
// Architecture mirrors `SDCardSlotInterestObserver` — same
// IONotificationPort + run-loop-source pattern, same `Unmanaged`
// context bridge.

import Foundation
import IOKit
import ManifoldKit
import os

@MainActor
final class BatteryInterestObserver {

    /// Snapshot reader — production reads via `BatterySnapshotReader`;
    /// tests inject a programmable closure.
    private let reader: @Sendable () -> BatteryInfo?

    /// Consumer invoked on MainActor whenever the kernel publishes a
    /// snapshot whose visible fields differ from the previous one.
    /// Empty-diff callbacks are filtered out before the consumer is
    /// invoked — they're noise from non-property service events.
    private let onSnapshot: @MainActor (BatteryInfo?) -> Void

    /// IOKit notification port. Scheduled on the main run loop so
    /// callbacks land on the main thread.
    private var notifyPort: IONotificationPortRef?

    /// Matched `AppleSmartBattery` IOService handle. Released in
    /// `stop()`. Zero on desktop Macs (unmatched short-circuits start).
    private var serviceRef: io_service_t = 0

    /// Interest-notification handle. Released in `stop()`.
    private var notificationRef: io_object_t = 0

    /// Last snapshot the observer forwarded. The empty-diff filter
    /// compares each new snapshot against this and skips the
    /// consumer when the visible fields haven't changed.
    private var lastForwardedSnapshot: BatteryInfo?

    /// Has the consumer ever been invoked? `false` before the first
    /// real snapshot (or `deliverInitialSnapshot()` call). When false,
    /// the next snapshot — even nil — is forwarded so the consumer
    /// always sees an initial value.
    private var hasForwarded: Bool = false

    /// Has the observer been torn down? Late-firing callbacks racing
    /// with `stop()` get short-circuited.
    private var isShutDown: Bool = false

    // MARK: - Init

    /// Production-flavor convenience: reads via
    /// `BatterySnapshotReader.currentSnapshot`. Registers the IOKit
    /// subscription on init so the callback is wired up before any
    /// organic event arrives.
    convenience init(onSnapshot: @escaping @MainActor (BatteryInfo?) -> Void) {
        self.init(
            reader: { BatterySnapshotReader.currentSnapshot() },
            onSnapshot: onSnapshot
        )
    }

    /// DI-friendly init — tests inject a programmable reader closure
    /// + assertion-friendly onSnapshot callback. Mirrors the
    /// `BatterySnapshotReader.currentSnapshot` shape so production
    /// and test code paths share the same surface.
    init(
        reader: @escaping @Sendable () -> BatteryInfo?,
        onSnapshot: @escaping @MainActor (BatteryInfo?) -> Void
    ) {
        self.reader = reader
        self.onSnapshot = onSnapshot
        register()
    }

    // MARK: - Lifecycle

    /// Force a fresh read + forward. AppDelegate calls this once at
    /// startup so the consumer has a non-nil snapshot before SwiftUI's
    /// first frame, even if no organic interest event has fired yet.
    /// Idempotent — safe to call after `stop()` (becomes a no-op).
    func deliverInitialSnapshot() {
        guard !isShutDown else { return }
        forward(reader())
    }

    /// Tear down the IOKit subscription. Safe to call multiple times.
    /// Wired to `applicationWillTerminate` in AppDelegate.
    func stop() {
        guard !isShutDown else { return }
        isShutDown = true
        if notificationRef != 0 {
            IOObjectRelease(notificationRef)
            notificationRef = 0
        }
        if let port = notifyPort {
            if let unmanagedSource = IONotificationPortGetRunLoopSource(port) {
                CFRunLoopRemoveSource(
                    CFRunLoopGetMain(),
                    unmanagedSource.takeUnretainedValue(),
                    CFRunLoopMode.defaultMode
                )
            }
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        if serviceRef != 0 {
            IOObjectRelease(serviceRef)
            serviceRef = 0
        }
    }

    // MARK: - Internals

    private func register() {
        guard let matching = IOServiceMatching("AppleSmartBattery") else {
            Log.app.error("BatteryInterestObserver: matching dict failed")
            return
        }
        // `IOServiceMatching` returns +1; `IOServiceGetMatchingService`
        // consumes it (unlike `IOServiceGetMatchingServices`), so no
        // explicit release of `matching` is needed.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            // Desktop Mac path — no AppleSmartBattery service exists,
            // so the observer becomes a permanent no-op. The Battery
            // tab is hidden on desktop Macs anyway (gated on
            // `graph.battery != nil`).
            Log.app.info("BatteryInterestObserver: no AppleSmartBattery service (desktop Mac)")
            return
        }
        self.serviceRef = service

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            Log.app.error("BatteryInterestObserver: IONotificationPortCreate failed")
            return
        }
        self.notifyPort = port

        if let unmanagedSource = IONotificationPortGetRunLoopSource(port) {
            CFRunLoopAddSource(
                CFRunLoopGetMain(),
                unmanagedSource.takeUnretainedValue(),
                CFRunLoopMode.defaultMode
            )
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        var notification: io_object_t = 0
        let cb: IOServiceInterestCallback = { ctx, _, _, _ in
            guard let ctx else { return }
            let observer = Unmanaged<BatteryInterestObserver>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in observer.handleCallback() }
        }
        let kr = IOServiceAddInterestNotification(
            port,
            service,
            kIOGeneralInterest,
            cb,
            context,
            &notification
        )
        if kr == KERN_SUCCESS {
            self.notificationRef = notification
            Log.app.info("BatteryInterestObserver: registered kIOGeneralInterest on AppleSmartBattery")
        } else {
            Log.app.error("BatteryInterestObserver: IOServiceAddInterestNotification failed kr=\(kr, privacy: .public)")
        }
    }

    private func handleCallback() {
        guard !isShutDown else { return }
        forward(reader())
    }

    /// Forward the snapshot to the consumer if its visible fields
    /// differ from the last forwarded one. The first call always
    /// forwards (so consumers see an initial value); subsequent
    /// calls skip when the diff is empty, suppressing the noise
    /// callbacks the kernel fires for non-property service events.
    private func forward(_ snapshot: BatteryInfo?) {
        if hasForwarded, !meaningfullyDiffers(lastForwardedSnapshot, snapshot) {
            return
        }
        hasForwarded = true
        lastForwardedSnapshot = snapshot
        onSnapshot(snapshot)
    }

    /// True when `a` and `b` differ in any field that drives a UI
    /// surface or alert decision. Skips `sampledAt` (ticks every
    /// read), `designCapacityMAh`, and `nominalCapacityMAh` (don't
    /// change at runtime). A nil/non-nil flip is always meaningful.
    private nonisolated func meaningfullyDiffers(_ a: BatteryInfo?, _ b: BatteryInfo?) -> Bool {
        if (a == nil) != (b == nil) { return true }
        guard let a, let b else { return false }
        return a.chargePercent != b.chargePercent
            || a.chargeState != b.chargeState
            || a.isExternalConnected != b.isExternalConnected
            || a.amperageMilliamps != b.amperageMilliamps
            || a.voltageVolts != b.voltageVolts
            || a.powerWatts != b.powerWatts
            || a.temperatureCelsius != b.temperatureCelsius
            || a.cycleCount != b.cycleCount
            || a.healthPercent != b.healthPercent
            || a.currentCapacityMAh != b.currentCapacityMAh
            || a.timeUntilFullMinutes != b.timeUntilFullMinutes
            || a.timeUntilEmptyMinutes != b.timeUntilEmptyMinutes
            || a.isFullyCharged != b.isFullyCharged
    }
}
