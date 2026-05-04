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
// IOKitQueue.swift
//
// Per SPEC.md §1: "IOKit traversal and notification callbacks run on
// a dedicated IOKitQueue (a serial DispatchQueue) registered against
// a CFRunLoop thread."
//
// Phases 1–6 ran USB walks synchronously on whichever actor invoked
// `DiscoveryService.walk()` (typically MainActor). At ~0.2 ms per walk
// for the M1 Max boot SSD this was invisible — but Phase 7 introduces
// `ThunderboltWalker` and `DisplayResolver`, both of which traverse
// substantially more registry, and Phase 5's `TelemetrySampler` now
// does this every second. The hop closes Reviewer F9 ("Phase 7 is
// the natural spot since TB walker may push per-walk time enough to
// make the hop worthwhile").
//
// Implementation: an actor whose serial executor satisfies SPEC §1's
// "serial DispatchQueue" requirement — actor messages are processed
// one at a time per actor instance. The CFRunLoop thread for IOKit
// notifications already lives in `IOKitNotificationCenter`; this
// queue is for *traversal*, not notifications.
//
// Why an actor instead of a `DispatchQueue` directly: the actor's
// suspension semantics integrate cleanly with `async/await` — callers
// `await IOKitQueue.shared.usbWalk(...)` and the runtime handles
// thread-hopping. A bare DispatchQueue would force every call site
// into `withCheckedContinuation` boilerplate.

import Foundation
import ManifoldKit

actor IOKitQueue {

    /// Singleton — there's exactly one IOKit registry per process and
    /// SPEC §1's "dedicated" wording implies one queue too. Phase 7+
    /// callers (DiscoveryService, TelemetrySampler, ThunderboltWalker,
    /// DisplayResolver) all hop here.
    static let shared = IOKitQueue()

    private init() {}

    // MARK: - USB

    /// Run a `USBWalker.walkAndLog()` on the IOKit serial executor.
    /// The walker's `walk()` is the IOKit-traversal call; the
    /// `walkAndLog` variant adds the `os.Logger` per-device summary
    /// per SPEC §16.1 (Logger is thread-safe, fine to call here).
    ///
    /// Returns the walked snapshots; the caller hops back to its own
    /// actor before mutating UI / model state.
    func usbWalk(walker: USBWalker) throws -> [USBDeviceSnapshot] {
        try walker.walkAndLog()
    }

    // MARK: - Thunderbolt

    /// Run a `ThunderboltWalker.walk()` on the IOKit serial executor.
    /// Phase 7 introduces this; future phases (e.g., a hub-only
    /// re-walk on certain events) may add narrower variants.
    func tbWalk(walker: ThunderboltWalker) throws -> [TBDeviceSnapshot] {
        try walker.walk()
    }

    // MARK: - USB-C chassis ports

    /// Run a `USBCPortWalker.walk()` on the IOKit serial executor.
    /// Reads `AppleTCControllerType10` for chassis port occupancy
    /// state — empty / data device / power-only sink — so the UI
    /// can show power-only USB-C connections that never appear in
    /// the IOUSB plane.
    func usbcPortWalk(walker: USBCPortWalker) throws -> [USBCPortSnapshot] {
        try walker.walk()
    }

    // MARK: - Displays

    /// Run a `DisplayResolver.resolve()` on the IOKit serial
    /// executor. Resolver internally walks `IODisplayConnect` (or
    /// the modern equivalent) and reads EDID — both IOKit-touching
    /// per SPEC §1.
    func resolveDisplays(resolver: DisplayResolver) throws -> [DisplaySnapshot] {
        try resolver.resolve()
    }

    // MARK: - Host metadata

    /// Read the local Mac's `IOPlatformUUID` + `model` properties.
    /// Pulled out of `DiscoveryService` so it goes through the same
    /// serial queue as the walkers — DiscoveryService can `await`
    /// it without juggling a separate IOKit hop.
    ///
    /// Returns a sane fallback (`HostID("UNKNOWN-<hostname>")`) if
    /// IOKit can't resolve `IOPlatformExpertDevice` — same defensive
    /// behavior as the Phase-2 implementation, just relocated to
    /// the queue.
    func resolveHostMetadata() -> HostMetadata {
        DiscoveryService.resolveLiveHostMetadataOnQueue()
    }
}
