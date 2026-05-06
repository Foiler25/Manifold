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
// SDCardSlotInterestObserver.swift
//
// Subscribes to IOKit "general interest" messages on the
// `AppleSDXCSlot` service. Property changes on the slot — most
// importantly `Card Present` flipping between Yes and No — deliver
// to a single callback, debounced. No polling, no timers.
//
// Why this exists: the existing service-match subscription on
// `AppleSDXCBlockStorageDevice` (in `EventService`) doesn't fire
// reliably for card removal in one specific sequence:
//
//   1. User Finder-ejects an SD card → volume unmounts, but
//      `AppleSDXCBlockStorageDevice` instance stays in IOReg.
//   2. User physically pulls the card out.
//   3. macOS leaves the BlockStorageDevice in IOReg as a stale
//      instance; the `kIOTerminatedNotification` we registered for
//      never fires.
//
// `AppleSDXCSlot.Card Present` does flip to No in this scenario, so
// subscribing to the slot's general-interest messages catches the
// transition that the service-match subscription misses. Bonus: it
// also catches insert events the same way — the existing
// `BlockStorageDevice` first-match notification still fires on a
// clean insert too, so the two paths reinforce each other rather
// than competing.

import Foundation
import IOKit
import os

@MainActor
final class SDCardSlotInterestObserver {

    /// Caller's "slot fired a property change" callback. Always
    /// invoked on MainActor. Wrapped by an internal debouncer so a
    /// single card insertion (which fires several interest messages
    /// in a burst — Card Present, Card Configured, Card
    /// Characteristics, etc.) collapses to one `onChange`.
    private let onChange: () -> Void

    /// IOKit notification port. Scheduled on the main run loop so
    /// callbacks land on the main thread (and therefore on the
    /// MainActor's serial executor in macOS).
    private var notifyPort: IONotificationPortRef?

    /// The matched `AppleSDXCSlot` IOService handle. Released in
    /// `stop()`. Zero on Macs without an SD reader (unmatched case
    /// short-circuits start).
    private var serviceRef: io_service_t = 0

    /// The interest-notification handle. Released in `stop()` —
    /// IOKit requires the caller to drop this when the subscription
    /// ends.
    private var notificationRef: io_object_t = 0

    /// Debounce task — cancelled and replaced on each interest
    /// callback so only the last task in a burst fires `onChange`.
    private var debounceTask: Task<Void, Never>?

    /// Debounce window. AppleSDXCSlot fires a small flurry of
    /// property-change messages during card insert / configure
    /// (typically 30–80 ms apart). 100 ms is well below the
    /// human-visible threshold while wide enough to absorb the burst.
    private static let debounceMs: UInt64 = 100

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        start()
    }

    /// Tear down the IOKit subscription. Safe to call multiple
    /// times. Wired to `applicationWillTerminate` in AppDelegate.
    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        if notificationRef != 0 {
            IOObjectRelease(notificationRef)
            notificationRef = 0
        }
        if let port = notifyPort {
            // Unschedule from the main run loop, then destroy.
            // `IONotificationPortGetRunLoopSource` returns an
            // unretained ref — we mirror its lifetime via the
            // explicit add/remove here.
            if let unmanagedSource = IONotificationPortGetRunLoopSource(port) {
                let source = unmanagedSource.takeUnretainedValue()
                CFRunLoopRemoveSource(
                    CFRunLoopGetMain(),
                    source,
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

    // MARK: - Setup

    private func start() {
        // Find AppleSDXCSlot. `IOServiceMatching` returns a +1
        // retained dict; `IOServiceGetMatchingService` consumes it
        // (unlike `IOServiceGetMatchingServices`), so we don't
        // release `matching` ourselves.
        guard let matching = IOServiceMatching("AppleSDXCSlot") else {
            Log.discovery.debug("SDCardSlotInterestObserver: matching dict failed")
            return
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            // Mac without an internal SD reader. No work to do —
            // the observer becomes a permanent no-op.
            return
        }
        self.serviceRef = service

        // Create the notification port + schedule on the main run
        // loop. The runloop source is +0 retained from
        // `IONotificationPortGetRunLoopSource`; we'll match the
        // remove call in `stop()`.
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            Log.discovery.debug("SDCardSlotInterestObserver: port create failed")
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

        // Register the general-interest callback. The C bridge
        // recovers the observer from `refCon` and hops onto the
        // MainActor before invoking `notify()`.
        let context = Unmanaged.passUnretained(self).toOpaque()
        var notification: io_object_t = 0
        let kr = IOServiceAddInterestNotification(
            port,
            service,
            kIOGeneralInterest,
            { ctx, _, _, _ in
                SDCardSlotInterestObserver.deliver(from: ctx)
            },
            context,
            &notification
        )
        if kr == KERN_SUCCESS {
            self.notificationRef = notification
        } else {
            Log.discovery.debug(
                "SDCardSlotInterestObserver: IOServiceAddInterestNotification failed kr=\(kr, privacy: .public)"
            )
        }
    }

    /// C-callback bridge. Recovers the observer from `refCon` and
    /// hops onto MainActor to invoke the debounced notify path.
    private nonisolated static func deliver(from ctx: UnsafeMutableRawPointer?) {
        guard let ctx else { return }
        let observer = Unmanaged<SDCardSlotInterestObserver>.fromOpaque(ctx).takeUnretainedValue()
        Task { @MainActor in
            observer.notify()
        }
    }

    /// Schedule (or replace) the debounced fire. AppleSDXCSlot's
    /// burst of messages during a single user action collapses to
    /// one `onChange` call.
    private func notify() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.debounceMs)))
            guard !Task.isCancelled, let self else { return }
            Log.discovery.debug("SDCardSlotInterestObserver: fired onChange after debounce")
            self.onChange()
        }
    }
}
