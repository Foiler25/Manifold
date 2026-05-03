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
// NotificationPort.swift
//
// Per SPEC.md §5.1 (rev 7) — closes the F11 boundary tension that's
// been carrying since Phase 1. The C-level surface IOKit notifications
// require (`IOServiceAddMatchingNotification`, the
// `IOServiceMatchingCallback` C function pointer with `void *refcon`,
// per-callback `IOIteratorNext` drain, per-entry `IOObjectRelease`)
// is exactly the boilerplate the §5 invariant exists to contain.
// Rather than carve out a per-file exception in `Manifold/Sources/Events/`,
// the wrappers live here; `IOKitNotificationCenter` becomes a thin
// dispatcher that holds these and forwards Swift closures.
//
// The grep invariant — `IOObjectRelease`, `IOIteratorNext`,
// `IOServiceAddMatchingNotification`, `IORegistryEntryCreateCFProperty`,
// `IONotificationPortCreate`, `IONotificationPortDestroy`,
// `IONotificationPortGetRunLoopSource` outside this directory — must
// return ZERO hits. Reviewer enforces.

import Foundation
import IOKit

// MARK: - NotificationPort

/// Owns an `IONotificationPortRef` and its `CFRunLoopSource`.
/// Schedules the source on the supplied run loop in the supplied
/// mode at init; tears down on `deinit`.
///
/// `~Copyable` for the same reason `IOObject` is: prevents accidental
/// aliasing of the kernel handle and the matching double-release on
/// `IONotificationPortDestroy`.
struct NotificationPort: ~Copyable {

    fileprivate let raw: IONotificationPortRef
    fileprivate let runLoopSource: CFRunLoopSource
    fileprivate let runLoop: CFRunLoop
    fileprivate let mode: CFRunLoopMode

    /// Create + schedule. Throws `IOKitError.notificationRegistrationFailed`
    /// if either `IONotificationPortCreate` or
    /// `IONotificationPortGetRunLoopSource` fail (rare —
    /// `IONotificationPortCreate` returning nil is documented as a
    /// "kernel out of memory" failure path).
    init(scheduledOn runLoop: CFRunLoop, mode: CFRunLoopMode = .defaultMode) throws {
        // `IONotificationPortCreate` returns `IONotificationPortRef!`
        // (implicitly unwrapped optional) in Swift bridging; treat as
        // optional explicitly so we surface kernel-OOM as a thrown
        // error rather than a force-unwrap crash.
        guard let port: IONotificationPortRef = IONotificationPortCreate(kIOMainPortDefault) else {
            throw IOKitError.notificationRegistrationFailed(KERN_FAILURE)
        }
        guard let unmanagedSource = IONotificationPortGetRunLoopSource(port) else {
            IONotificationPortDestroy(port)
            throw IOKitError.notificationRegistrationFailed(KERN_FAILURE)
        }
        let source = unmanagedSource.takeUnretainedValue()
        CFRunLoopAddSource(runLoop, source, mode)
        self.raw = port
        self.runLoopSource = source
        self.runLoop = runLoop
        self.mode = mode
    }

    deinit {
        // Order matters: remove the source from the run loop FIRST so
        // any pending callback drains can't fire mid-destroy, THEN
        // destroy the port (which would invalidate `runLoopSource`'s
        // backing store).
        CFRunLoopRemoveSource(runLoop, runLoopSource, mode)
        IONotificationPortDestroy(raw)
    }
}

// MARK: - MatchNotificationToken

/// One active match-or-terminated subscription. Holds the iterator
/// (released on deinit) and a strong reference to the closure box
/// (kept alive so the C callback can keep finding it via
/// `Unmanaged.fromOpaque(refcon)`).
///
/// `~Copyable` so the iterator can't be double-released. Pair with
/// `IOKitNotificationCenter.NotificationToken` (which composes one
/// `MatchNotificationToken` for first-match + one for terminated).
struct MatchNotificationToken: ~Copyable {

    fileprivate let iterator: io_iterator_t
    fileprivate let context: AnyObject  // CallbackBox — keeps the closure alive

    deinit {
        // IOObjectRelease first: after this returns, IOKit won't
        // deliver any more callbacks for this iterator, so it's safe
        // for ARC to free the closure box at end-of-deinit.
        if iterator != 0 {
            IOObjectRelease(iterator)
        }
        // The box is kept alive by `context`'s strong ARC reference —
        // the IOKit refcon was registered with `passUnretained`, so
        // there is no unmanaged retain to balance. Phase 8 review F20
        // closure: an earlier `passRetained` pairing would have left
        // a permanent +1 retain that this deinit could not balance
        // without an awkward downcast.
    }
}

// MARK: - addMatchNotification

/// Register a match-or-terminated notification on the supplied port.
/// `kind` is `kIOFirstMatchNotification` or `kIOTerminatedNotification`.
/// `match` is a `CFDictionary` from `IOServiceMatching(...)` (consumed
/// +1). `perEntry` is invoked for each `io_object_t` the iterator
/// yields, both at initial drain (so already-present services are
/// seen) and on every subsequent fire. Per-entry release is automatic
/// via the `forEachEntry` machinery.
///
/// Returns a `MatchNotificationToken` whose `deinit` releases the
/// iterator and drops the closure box. Caller stores the token to
/// keep the subscription alive; dropping it deregisters cleanly.
func addMatchNotification(
    on port: borrowing NotificationPort,
    kind: String,
    match: CFDictionary,
    perEntry: @escaping @Sendable (borrowing IOObject) -> Void
) throws -> MatchNotificationToken {

    // Box the Swift closure so the C callback can recover it through
    // `Unmanaged.fromOpaque(refcon)`. The box's lifetime is owned by
    // the returned token's `context: AnyObject` strong reference —
    // `passUnretained` here means IOKit treats the refcon as a
    // borrowed pointer, NOT a retained one, so no balancing release
    // is needed when the token drops. (Phase 8 review F20 closure:
    // an earlier `passRetained` left a permanent +1 retain that
    // could never be balanced from a Swift `~Copyable` deinit.)
    //
    // Lifetime contract: the C callback uses `takeUnretainedValue()`
    // and is only ever called while the iterator is live; the
    // iterator is released in `MatchNotificationToken.deinit` BEFORE
    // ARC drops the box, so no callback can fire on a dead box.
    let box = NotificationPortCallbackBox(perEntry: perEntry)
    let refcon = Unmanaged.passUnretained(box).toOpaque()

    var iter: io_iterator_t = 0
    let result = IOServiceAddMatchingNotification(
        port.raw,
        kind,
        match,
        notificationCallbackBridge,
        refcon,
        &iter
    )
    guard result == KERN_SUCCESS, iter != 0 else {
        // Nothing to release here — `passUnretained` didn't bump
        // the retain count. The local `box` simply goes out of
        // scope after the throw.
        throw IOKitError.notificationRegistrationFailed(result)
    }

    // Initial drain. IOKit requires consuming the iterator once at
    // registration so subsequent notifications fire on changes only.
    // For first-match: this delivers every currently-matching service
    // through `perEntry`. For terminated: typically nothing to drain
    // at registration time.
    forEachEntry(in: iter) { entry in
        box.perEntry(entry)
    }

    // The token's `context: AnyObject` becomes the sole owner of the
    // box. When the token drops, ARC frees it.
    return MatchNotificationToken(iterator: iter, context: box)
}

// MARK: - C callback bridge

/// Heap-allocated holder so the C callback can recover the Swift
/// closure through `Unmanaged.fromOpaque`. `final class` because the
/// callback needs reference identity for `Unmanaged.passRetained`.
private final class NotificationPortCallbackBox: @unchecked Sendable {
    let perEntry: @Sendable (borrowing IOObject) -> Void
    init(perEntry: @escaping @Sendable (borrowing IOObject) -> Void) {
        self.perEntry = perEntry
    }
}

/// Top-level `let` bound to a closure with `@convention(c)`
/// inferred from `IOServiceMatchingCallback`. Capturing anything
/// here would block the implicit C-convention conversion, so the
/// closure body uses `Unmanaged.fromOpaque` to recover the box from
/// the refcon.
private let notificationCallbackBridge: IOServiceMatchingCallback = { context, iterator in
    guard let context else { return }
    let box = Unmanaged<NotificationPortCallbackBox>.fromOpaque(context).takeUnretainedValue()
    forEachEntry(in: iterator) { entry in
        box.perEntry(entry)
    }
}
