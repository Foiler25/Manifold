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
// IOKitNotificationCenter.swift
//
// Owns the dedicated background `Thread` + `CFRunLoop` that IOKit
// notification ports require, plus the register/unregister API that
// `EventService` calls into. Per SPEC.md §7:
//
//   "The notification port is added to a dedicated `CFRunLoop`
//    running on a background `Thread` (NOT a dispatch queue — IOKit
//    notification ports don't bridge cleanly to dispatch). The
//    thread's run loop pumps until `shutdown()`."
//
// Why a class, not an actor: IOKit's C callbacks have to dispatch
// into Swift via `Unmanaged.passRetained`/`fromOpaque` and a
// top-level `@convention(c)` function. Actors don't let you take
// the kind of plain `self`-pointer the callback needs to thread the
// reference through. The class is `@unchecked Sendable` because the
// IOKit-touching state is single-threaded by construction (only the
// dedicated thread mutates it post-init), and the public API is
// guarded by an `NSLock`.

import Foundation
import IOKit
import os

/// Returned by `register(...)`. Caller passes back to `unregister(_:)`
/// to stop receiving notifications and release IOKit resources. Per
/// SPEC.md §7 the token's iterator handles are file-private — only the
/// center can release them, and it does so on `unregister`.
struct NotificationToken: Hashable {
    let id: UUID
    fileprivate let port: IONotificationPortRef
    fileprivate let firstMatchIter: io_iterator_t
    fileprivate let terminatedIter: io_iterator_t

    static func == (lhs: NotificationToken, rhs: NotificationToken) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

final class IOKitNotificationCenter: @unchecked Sendable {

    // MARK: - Dedicated thread + run loop

    /// Background thread that owns the CFRunLoop the IOKit notification
    /// ports are scheduled on. Started in `init`, joined on `shutdown`.
    private let thread: Thread

    /// Captured at the top of `runOnDedicatedThread()`. Used to add
    /// notification-port run-loop sources from `register(...)` and to
    /// stop the loop from `shutdown()`.
    private var runLoop: CFRunLoop?

    /// Signaled once the dedicated thread has captured `runLoop` and
    /// is ready to accept registrations. `init` blocks on this to keep
    /// the API synchronous from the caller's perspective.
    private let runLoopReady = DispatchSemaphore(value: 0)

    /// Set true on `shutdown()`. Checked by the dedicated thread's
    /// `runOnDedicatedThread()` loop so the thread exits cleanly.
    private var stopRequested = false

    // MARK: - Token bookkeeping

    /// Lock for the `tokens` dict and for `stopRequested`. The IOKit
    /// thread reads these; the public API mutates them.
    private let lock = NSLock()

    /// Live registrations. Keyed by token id so `unregister(_:)` is O(1).
    private var tokens: [UUID: TokenInternal] = [:]

    /// Per-token internal record. Keeps the boxed callbacks alive
    /// (via the `Unmanaged` retain count) so the C callback can
    /// continue to find them.
    private struct TokenInternal {
        let port: IONotificationPortRef
        let firstMatchIter: io_iterator_t
        let terminatedIter: io_iterator_t
        let firstMatchBoxOpaque: UnsafeMutableRawPointer
        let terminatedBoxOpaque: UnsafeMutableRawPointer
    }

    // MARK: - Init / shutdown

    init() {
        let thread = Thread()
        self.thread = thread
        // Set the closure on the existing thread instance after super-init
        // by spawning an explicit Thread and starting it. Using the
        // detach pattern below to keep the closure capture cleaner.
        // (Thread() initializer is documented as a default no-op start
        // closure that we replace by detachNewThread below.)
        Thread.detachNewThread { [weak self] in
            self?.runOnDedicatedThread()
        }
        runLoopReady.wait()
    }

    /// The dedicated thread's run loop. Captures `runLoop`, signals
    /// readiness, then pumps `CFRunLoopRunInMode` until `shutdown()`
    /// flips `stopRequested`. The 1.0-second slice gives the loop a
    /// natural cadence to check the stop flag without blocking
    /// indefinitely on a quiet IOKit port.
    private func runOnDedicatedThread() {
        Thread.current.name = "Manifold-IOKitRunLoop"
        runLoop = CFRunLoopGetCurrent()
        runLoopReady.signal()

        var done = false
        while !done {
            CFRunLoopRunInMode(.defaultMode, 1.0, false)
            lock.lock()
            done = stopRequested
            lock.unlock()
        }
    }

    /// Stop the dedicated run loop, release every registered iterator
    /// and notification port. Idempotent — calling twice is a no-op
    /// after the first.
    func shutdown() {
        lock.lock()
        guard !stopRequested else {
            lock.unlock()
            return
        }
        stopRequested = true
        let allTokens = tokens
        tokens.removeAll()
        lock.unlock()

        for (_, t) in allTokens {
            releaseTokenResources(t)
        }

        if let runLoop {
            CFRunLoopStop(runLoop)
        }
    }

    // MARK: - Registration

    /// Register first-match + terminated notifications for any IOKit
    /// service of class `matchingClass`. Returns a `NotificationToken`
    /// that the caller passes back to `unregister(_:)` to tear down.
    ///
    /// Why `matchingClass: String` instead of `match: CFDictionary`
    /// like SPEC.md §7's first sketch: `IOServiceAddMatchingNotification`
    /// *consumes* one reference on the matching dict. We need to register
    /// twice (one for first-match, one for terminated), so we need two
    /// dicts. Taking a class name and calling `IOServiceMatching` twice
    /// produces two cleanly-retained dicts without `CFRetain` ceremony.
    /// Phase 7 may extend this when TB needs more than class-name matching.
    ///
    /// `onMatch` and `onTerminated` are invoked on the dedicated IOKit
    /// thread. They receive a `borrowing IOObject` — the wrapper
    /// releases the kernel handle on closure return, so the closure
    /// must finish reading properties before returning.
    func register(
        matchingClass: String,
        onMatch: @escaping @Sendable (borrowing IOObject) -> Void,
        onTerminated: @escaping @Sendable (borrowing IOObject) -> Void
    ) throws -> NotificationToken {

        guard let runLoop = runLoop else {
            throw IOKitError.notificationRegistrationFailed(KERN_FAILURE)
        }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            throw IOKitError.notificationRegistrationFailed(KERN_FAILURE)
        }

        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(runLoop, source, .defaultMode)

        // Box the Swift closures so the C callback can find them
        // through `Unmanaged.fromOpaque`. `passRetained` increments
        // the retain count; `unregister` does the matching `release`.
        let firstMatchBox = CallbackBox(handler: onMatch)
        let terminatedBox = CallbackBox(handler: onTerminated)
        let firstMatchOpaque = Unmanaged.passRetained(firstMatchBox).toOpaque()
        let terminatedOpaque = Unmanaged.passRetained(terminatedBox).toOpaque()

        // First-match registration. IOServiceMatching returns +1
        // retained; IOServiceAddMatchingNotification consumes it.
        var firstMatchIter: io_iterator_t = 0
        let matchResult = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            IOServiceMatching(matchingClass),
            iokitNotificationCallback,
            firstMatchOpaque,
            &firstMatchIter
        )
        guard matchResult == KERN_SUCCESS else {
            Unmanaged<CallbackBox>.fromOpaque(firstMatchOpaque).release()
            Unmanaged<CallbackBox>.fromOpaque(terminatedOpaque).release()
            IONotificationPortDestroy(port)
            throw IOKitError.notificationRegistrationFailed(matchResult)
        }

        // Terminated registration.
        var terminatedIter: io_iterator_t = 0
        let termResult = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching(matchingClass),
            iokitNotificationCallback,
            terminatedOpaque,
            &terminatedIter
        )
        guard termResult == KERN_SUCCESS else {
            IOObjectRelease(firstMatchIter)
            Unmanaged<CallbackBox>.fromOpaque(firstMatchOpaque).release()
            Unmanaged<CallbackBox>.fromOpaque(terminatedOpaque).release()
            IONotificationPortDestroy(port)
            throw IOKitError.notificationRegistrationFailed(termResult)
        }

        // Drain both iterators. On first registration this delivers
        // every currently-matching service through `onMatch`; the
        // terminated iterator is empty initially. After the drain,
        // future events fire as new services arrive / go away.
        Self.drain(iterator: firstMatchIter, with: onMatch)
        Self.drain(iterator: terminatedIter, with: onTerminated)

        let token = NotificationToken(
            id: UUID(),
            port: port,
            firstMatchIter: firstMatchIter,
            terminatedIter: terminatedIter
        )
        let internalRecord = TokenInternal(
            port: port,
            firstMatchIter: firstMatchIter,
            terminatedIter: terminatedIter,
            firstMatchBoxOpaque: firstMatchOpaque,
            terminatedBoxOpaque: terminatedOpaque
        )

        lock.lock()
        tokens[token.id] = internalRecord
        lock.unlock()

        return token
    }

    /// Tear down a registration. Idempotent — calling twice is a no-op
    /// after the first.
    func unregister(_ token: NotificationToken) {
        lock.lock()
        guard let internalRecord = tokens.removeValue(forKey: token.id) else {
            lock.unlock()
            return
        }
        lock.unlock()
        releaseTokenResources(internalRecord)
    }

    // MARK: - Cleanup helpers

    /// Release every IOKit handle and balance the `Unmanaged` retains
    /// for one token. Shared by `unregister` and `shutdown`.
    private func releaseTokenResources(_ t: TokenInternal) {
        IOObjectRelease(t.firstMatchIter)
        IOObjectRelease(t.terminatedIter)
        IONotificationPortDestroy(t.port)
        Unmanaged<CallbackBox>.fromOpaque(t.firstMatchBoxOpaque).release()
        Unmanaged<CallbackBox>.fromOpaque(t.terminatedBoxOpaque).release()
    }

    /// Drain an iterator by invoking `handler` on each entry and
    /// letting `IOObject.deinit` release the kernel handle. Static so
    /// it can be called from `register` (post-callback-registration
    /// drain) and from the C callback (event delivery) without
    /// touching `self`.
    fileprivate static func drain(
        iterator: io_iterator_t,
        with handler: (borrowing IOObject) -> Void
    ) {
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            let owned = IOObject(entry)
            handler(owned)
        }
    }
}

// MARK: - C callback bridge

/// Heap box for the Swift closure so the C callback can find it via
/// `Unmanaged.fromOpaque(refCon)`. Lifetime is managed by the
/// notification center: `passRetained` on register, `release` on
/// unregister/shutdown.
private final class CallbackBox: @unchecked Sendable {
    let handler: @Sendable (borrowing IOObject) -> Void
    init(handler: @escaping @Sendable (borrowing IOObject) -> Void) {
        self.handler = handler
    }
}

/// `@convention(c)` callback that IOKit invokes on our dedicated
/// thread when a new match arrives or a service terminates. Recovers
/// the boxed closure via `Unmanaged.fromOpaque` and drains the
/// iterator into it.
///
/// Top-level `let` (not a method, not a closure capture) so the C
/// signature is satisfied. Capturing anything would prevent the
/// implicit `@convention(c)` conversion.
private let iokitNotificationCallback: IOServiceMatchingCallback = { refCon, iterator in
    guard let refCon else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(refCon).takeUnretainedValue()
    IOKitNotificationCenter.drain(iterator: iterator, with: box.handler)
}
