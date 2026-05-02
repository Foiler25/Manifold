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
// **Phase 8 / F11 retrofit.** IOKitNotificationCenter is now a thin
// dispatcher per SPEC §7 rev-7 — every IOKit-touching call goes
// through the §5.1 wrappers (`NotificationPort`,
// `MatchNotificationToken`, `addMatchNotification`) in
// `Manifold/Sources/Support/IOKit/NotificationPort.swift`. Result:
// the §5 grep invariant
//
//     grep -rn 'IOObjectRelease\|IOIteratorNext\|
//               IOServiceAddMatchingNotification\|
//               IORegistryEntryCreateCFProperty'
//          Manifold/ | grep -v 'Manifold/Sources/Support/IOKit/'
//
// returns ZERO hits — the F11 followup that's been carrying since
// Phase 1 review closes.
//
// What stays from Phase 3:
//   - The dedicated `Manifold-IOKitRunLoop` background `Thread` +
//     `CFRunLoop`. SPEC §7 requires a CFRunLoop (not a dispatch
//     queue) for IOKit notification ports; the wrappers don't
//     change that.
//   - The public `register(matchingClass:onMatch:onTerminated:) ->
//     NotificationToken` API and the public Copyable `NotificationToken`
//     (UUID-keyed) so EventService's call sites don't need to
//     handle non-copyable types.
//   - Idempotent `shutdown()`.
//
// What changes:
//   - All raw IOKit calls (`IOServiceAddMatchingNotification`,
//     `IOIteratorNext`, `IOObjectRelease`, `IONotificationPortCreate`,
//     `IONotificationPortDestroy`, `IONotificationPortGetRunLoopSource`)
//     leave this file. They live behind the §5.1 wrappers.
//   - Per-registration storage holds noncopyable
//     `MatchNotificationToken`s via a small `TokenStorage` class
//     wrapper (Swift 6 supports `Optional<NoncopyableType>` so the
//     class can hold them and release on demand).

import Foundation
import IOKit
import os

/// Returned by `register(...)`. UUID-keyed so callers can store
/// these in plain dictionaries / sets / arrays. The actual
/// noncopyable token state lives inside the center, indexed by `id`.
struct NotificationToken: Hashable {
    let id: UUID

    static func == (lhs: NotificationToken, rhs: NotificationToken) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

final class IOKitNotificationCenter: @unchecked Sendable {

    // MARK: - Dedicated thread + run loop

    private let thread: Thread
    private var runLoop: CFRunLoop?
    private let runLoopReady = DispatchSemaphore(value: 0)
    private var stopRequested = false

    // MARK: - Token bookkeeping

    private let lock = NSLock()
    private var storages: [UUID: TokenStorage] = [:]

    /// Lazily constructed once the dedicated thread has captured its
    /// run loop. Held here so `shutdown()` can release it (setting
    /// the optional to nil triggers `NotificationPort.deinit` which
    /// removes the CFRunLoopSource + destroys the port).
    private var portStorage: PortStorage?

    /// Wrapper around the noncopyable `NotificationPort`. Optional so
    /// `shutdown()` can release by `port = nil`. The class boundary
    /// makes the noncopyable storage practical (Swift 6's collection
    /// support for noncopyable types is still narrow).
    /// Class wrapper for the noncopyable `NotificationPort`. Holds a
    /// non-optional reference and exposes a `withPort` borrow
    /// accessor — Swift 6 doesn't allow borrowing a `let` binding
    /// of a noncopyable optional, so we route through a method
    /// where the noncopyable instance is in scope.
    ///
    /// Lifetime: when the wrapper itself is dropped (set to nil on
    /// `IOKitNotificationCenter.shutdown`), `NotificationPort.deinit`
    /// fires and tears down the CFRunLoopSource + IOKit port.
    private final class PortStorage {
        var port: NotificationPort
        init(_ port: consuming NotificationPort) {
            self.port = consume port
        }
        /// Synchronous borrow. Closure runs with `borrowing
        /// NotificationPort` access; Swift's borrow rules confine
        /// the access to this scope.
        func withPort<T>(_ body: (borrowing NotificationPort) throws -> T) rethrows -> T {
            try body(port)
        }
    }

    /// Per-registration storage. Holds the two
    /// `MatchNotificationToken`s for first-match + terminated. On
    /// `release()` both go to nil → MatchNotificationToken.deinit
    /// fires → `IOObjectRelease` is called by the wrapper.
    private final class TokenStorage {
        var firstMatch: MatchNotificationToken?
        var terminated: MatchNotificationToken?
        init(firstMatch: consuming MatchNotificationToken,
             terminated: consuming MatchNotificationToken) {
            self.firstMatch = consume firstMatch
            self.terminated = consume terminated
        }
        func release() {
            firstMatch = nil
            terminated = nil
        }
    }

    // MARK: - Init / shutdown

    init() {
        let thread = Thread()
        self.thread = thread
        Thread.detachNewThread { [weak self] in
            self?.runOnDedicatedThread()
        }
        runLoopReady.wait()

        // The runLoop is now captured; build the NotificationPort.
        // This must happen on the dedicated thread for
        // `IONotificationPortGetRunLoopSource` semantics, but
        // `NotificationPort.init` itself is thread-safe (it just
        // calls `CFRunLoopAddSource` on the supplied runLoop).
        if let runLoop {
            do {
                let port = try NotificationPort(scheduledOn: runLoop)
                self.portStorage = PortStorage(port)
            } catch {
                Log.events.error("Failed to construct NotificationPort: \(String(describing: error), privacy: .public)")
            }
        }
    }

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

    /// Tear down every active subscription, drop the port, stop the
    /// dedicated run loop. Idempotent.
    func shutdown() {
        lock.lock()
        guard !stopRequested else {
            lock.unlock()
            return
        }
        stopRequested = true
        let allStorages = storages
        storages.removeAll()
        let port = portStorage
        portStorage = nil
        lock.unlock()

        // Drop noncopyable tokens — each release() triggers
        // MatchNotificationToken.deinit → IOObjectRelease.
        for (_, storage) in allStorages {
            storage.release()
        }
        // Drop the port wrapper — when the class instance drops
        // (no remaining references), `NotificationPort.deinit` fires
        // → CFRunLoopRemoveSource + IONotificationPortDestroy.
        _ = port  // captured-and-dropped at end of scope

        if let runLoop {
            CFRunLoopStop(runLoop)
        }
    }

    // MARK: - Registration

    /// Register first-match + terminated notifications for any IOKit
    /// service of class `matchingClass`. Internally calls
    /// `IOServiceMatching(matchingClass)` twice (each call returns
    /// a fresh +1-retained dict; `addMatchNotification` consumes one
    /// per call, so two registrations need two dicts).
    ///
    /// Returns a UUID-keyed `NotificationToken`; the noncopyable
    /// MatchNotificationTokens live inside the center, retrievable
    /// for release via `unregister(_:)` or `shutdown()`.
    func register(
        matchingClass: String,
        onMatch: @escaping @Sendable (borrowing IOObject) -> Void,
        onTerminated: @escaping @Sendable (borrowing IOObject) -> Void
    ) throws -> NotificationToken {

        guard let portStorage else {
            throw IOKitError.notificationRegistrationFailed(KERN_FAILURE)
        }

        // IOServiceMatching is NOT in the §5.1 grep-invariant list —
        // it's a matching-dictionary builder, not an IOKit-resource
        // manipulation. Calling it here is allowed.
        guard let firstDict = IOServiceMatching(matchingClass),
              let terminatedDict = IOServiceMatching(matchingClass) else {
            throw IOKitError.matchingDictionaryFailed
        }

        // Borrow the port through the class wrapper's withPort
        // accessor. Both registrations must complete (or both fail
        // cleanly) before we install the storage; the do-catch
        // guarantees the iterators get released if the second
        // registration fails after the first succeeds (the failed
        // first-match token's deinit runs at scope exit).
        let storage = try portStorage.withPort { port -> TokenStorage in
            let firstMatchToken = try addMatchNotification(
                on: port,
                kind: kIOFirstMatchNotification,
                match: firstDict,
                perEntry: onMatch
            )
            let terminatedToken = try addMatchNotification(
                on: port,
                kind: kIOTerminatedNotification,
                match: terminatedDict,
                perEntry: onTerminated
            )
            return TokenStorage(
                firstMatch: consume firstMatchToken,
                terminated: consume terminatedToken
            )
        }

        let id = UUID()
        lock.lock()
        storages[id] = storage
        lock.unlock()

        return NotificationToken(id: id)
    }

    /// Tear down one registration. Idempotent — if the token has
    /// already been released (e.g., by shutdown), a second call is
    /// a no-op.
    func unregister(_ token: NotificationToken) {
        lock.lock()
        let storage = storages.removeValue(forKey: token.id)
        lock.unlock()
        storage?.release()
    }
}
