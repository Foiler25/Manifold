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
// VolumeMountObserver.swift
//
// DiskArbitration callback subscription that fires whenever the OS
// mounts or unmounts a volume, or changes a volume's description
// (volume name appearing post-mount, ejection completing, etc.).
//
// Why this exists: Manifold previously relied on a fixed-delay /
// staggered-poll rebuild after each `.attached` event to catch DA's
// asynchronous volume mount and pick up the user's volume label
// ("PlanckSSD") instead of the USB product string ("Creator SSD").
// The polls were fragile — slow drives slipped past the 10 s window;
// fast drives wasted rebuild cycles. DA itself fires a callback the
// instant a mount completes; subscribing to that callback eliminates
// the timing guesswork entirely.
//
// The DA session is scheduled on the main run loop so callbacks
// land on the main thread (and therefore on the MainActor's serial
// executor in macOS). Bursts of callbacks during a single plug
// event (DA fires `disk-appeared` + `description-changed` for each
// LUN of a multi-volume drive) are coalesced via a 250 ms debounce
// — the rebuild only runs once after the burst settles.

import Foundation
import DiskArbitration
import os

@MainActor
final class VolumeMountObserver {

    /// Active DA session, nil before `start()` succeeds. The session
    /// holds the registered callbacks; CFRetain semantics keep them
    /// alive until we unschedule on `stop()`.
    private var session: DASession?

    /// Caller's "DA fired something" callback. Always invoked on
    /// MainActor. Wrapped by an internal debouncer so the caller
    /// doesn't have to coalesce DA's natural callback bursts.
    private let onChange: () -> Void

    /// Debounce task — cancelled and replaced on each callback so
    /// only the last task in a burst actually fires `onChange`.
    private var debounceTask: Task<Void, Never>?

    /// Debounce window. Tuned so DA's typical burst at mount time
    /// (disk-appeared + description-changed for each LUN) collapses
    /// to one trailing `onChange`. 100 ms is well below the
    /// human-visible threshold for plug events while still wide
    /// enough to absorb DA's typical 30–80 ms cluster.
    ///
    /// Originally 250 ms, reduced after a user report that the row
    /// took ~10 s to update on PlanckSSD hot-plug — DA was firing
    /// description-changed callbacks for unrelated keys (medium
    /// changed, size changed) every few hundred ms during the
    /// file-system scan, which kept resetting a longer debounce
    /// window. The watch-key filter on
    /// `DARegisterDiskDescriptionChangedCallback` (volume-name only)
    /// is the primary fix; this shorter debounce just keeps the
    /// burst-coalescing case tight.
    private static let debounceMs: UInt64 = 100

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        start()
    }

    /// Tear down the DA subscription. Safe to call multiple times;
    /// subsequent calls no-op. Also called by AppDelegate from
    /// `applicationWillTerminate`.
    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        if let session {
            DASessionUnscheduleFromRunLoop(
                session,
                RunLoop.main.getCFRunLoop(),
                CFRunLoopMode.defaultMode.rawValue
            )
            self.session = nil
        }
    }

    // MARK: - Setup

    private func start() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session

        // The DA C callback receives an opaque context pointer; we
        // use it to recover the observer instance via Unmanaged.
        // `passUnretained` is correct here — AppDelegate holds the
        // strong reference, so we never want the C callback to keep
        // us alive. If self is deallocated before unscheduling, we
        // crash; but `stop()` is wired to `applicationWillTerminate`
        // and the session is unscheduled before self drops.
        let context = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(session, nil, { _, ctx in
            VolumeMountObserver.deliver(from: ctx)
        }, context)

        DARegisterDiskDisappearedCallback(session, nil, { _, ctx in
            VolumeMountObserver.deliver(from: ctx)
        }, context)

        // Description-changed catches the volume-name-appeared case
        // explicitly — DA emits a description-changed event when a
        // file system finishes mounting and the volume name becomes
        // queryable.
        //
        // The third argument is the *watch* array: only changes to
        // keys in this list fire our callback. Without it, DA fires
        // description-changed every time *any* property changes —
        // and during the file-system scan that runs after a USB
        // drive mounts (especially big ExFAT volumes), DA fires
        // mediaSize / mediaContent / mediaWritable updates every few
        // hundred milliseconds for several seconds. Those don't
        // interest us, but they still reset our debounce timer, so
        // the rebuild gets pushed out by the duration of the scan.
        // Watching only the volume-name key cuts those out — we
        // hear about mounts and renames, nothing else.
        let watchKeys: CFArray = [kDADiskDescriptionVolumeNameKey] as CFArray
        DARegisterDiskDescriptionChangedCallback(session, nil, watchKeys, { _, _, ctx in
            VolumeMountObserver.deliver(from: ctx)
        }, context)

        DASessionScheduleWithRunLoop(
            session,
            RunLoop.main.getCFRunLoop(),
            CFRunLoopMode.defaultMode.rawValue
        )
    }

    /// C-callback bridge. Recovers the observer from the context
    /// pointer and hops onto MainActor to invoke the debounced
    /// notify path. The DA callback fires on the main run loop's
    /// thread (we scheduled it there), so `assumeIsolated` is
    /// sound — but we go through `Task { @MainActor }` rather than
    /// the more aggressive `MainActor.assumeIsolated` so a future
    /// scheduling change doesn't crash silently.
    private nonisolated static func deliver(from ctx: UnsafeMutableRawPointer?) {
        guard let ctx else { return }
        let observer = Unmanaged<VolumeMountObserver>.fromOpaque(ctx).takeUnretainedValue()
        Task { @MainActor in
            observer.notify()
        }
    }

    /// Schedule (or replace) the debounced fire. Multiple notifications
    /// inside the debounce window collapse to one `onChange` call.
    private func notify() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.debounceMs)))
            guard !Task.isCancelled, let self else { return }
            Log.discovery.debug("VolumeMountObserver: DA event fired onChange after debounce")
            self.onChange()
        }
    }
}
