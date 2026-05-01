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
// IOKitWrapper.swift
//
// The single allowed home for raw IOKit handle management. Every
// `IOObjectRelease`, `IOIteratorNext`, `IORegistryEntryCreateCFProperty`,
// `IOServiceGetMatchingServices`, and `IORegistryEntryGetChildIterator`
// call in the entire app lives behind one of the helpers in this file
// (or implicitly, behind `IOObject.deinit`). Reviewer enforces this;
// it is the linchpin of DECISIONS.md D8 ("IOKit retain management via
// `~Copyable` wrapper + scoped iteration helpers").
//
// Why ~Copyable matters here: `io_object_t` is a 32-bit kernel handle.
// Each one carries a +1 retain that must be balanced by exactly one
// `IOObjectRelease`. The classic bug is duplicating the handle (a Swift
// `let copy = original`) and then releasing both — a kernel-side double
// free that surfaces hours later as a memory corruption. By making
// `IOObject` non-copyable the compiler refuses to let an alias exist;
// every handle has exactly one owner, and `deinit` runs exactly once.
//
// Note on the "5 wrapper functions" callout in SPEC.md §18 Phase 1:
// the IOObject struct is a *type*, the 5 functions are forEachEntry,
// property, registryPath, withChildren, and withMatchingServices.

import Foundation
import IOKit

// MARK: - IOObject

/// Owning wrapper around an `io_object_t`. Releases the kernel handle on
/// deinit, exactly once.
///
/// The `~Copyable` constraint is load-bearing: it prevents accidental
/// aliasing of the same handle, which would cause a double release. Pass
/// IOObjects across function boundaries with `borrowing` (or `consuming`
/// when transferring ownership) — never `let copy = original`.
struct IOObject: ~Copyable {

    /// The raw kernel handle. Treat as opaque outside this file.
    /// `0` is a sentinel for "no object" (matches IOKit convention).
    let raw: io_object_t

    /// Wrap a freshly-acquired `io_object_t`. Caller must have just
    /// received it from an IOKit API that returned a +1 retain
    /// (e.g., `IOIteratorNext`, `IOServiceGetMatchingService`). Passing
    /// `0` is allowed and creates a no-op wrapper whose `deinit` does
    /// nothing — this lets call sites express "no entry" without
    /// optionals.
    init(_ raw: io_object_t) {
        self.raw = raw
    }

    deinit {
        // Guarding on `raw != 0` matches IOKit's documented contract:
        // releasing a 0 handle is undefined behavior, even though most
        // implementations no-op it. Cheap, explicit, correct.
        if raw != 0 {
            IOObjectRelease(raw)
        }
    }

    /// `true` when this wrapper holds a real kernel handle.
    var isValid: Bool { raw != 0 }
}

// MARK: - Iteration helpers

/// Walk every entry produced by an `io_iterator_t`, transferring each
/// entry into a borrowed `IOObject` and releasing it after `body` returns.
///
/// Why this exists: `IOIteratorNext` returns each entry with a +1 retain
/// that the caller must release. Forgetting that release is the most
/// common IOKit leak in the wild. This helper makes the discipline
/// automatic — the iteration reads almost like a Swift `for` loop, and
/// any escape (return, throw) still releases via `IOObject`'s deinit.
///
/// Iterator ownership: the iterator handle itself is *not* owned by this
/// helper. Callers obtain iterators from `withMatchingServices` /
/// `withChildren` (which release the iterator on scope exit) or directly
/// from `IOServiceAddMatchingNotification` (Phase 3, where the iterator
/// is held for the lifetime of the notification subscription).
func forEachEntry(
    in iterator: io_iterator_t,
    _ body: (borrowing IOObject) throws -> Void
) rethrows {
    while case let entry = IOIteratorNext(iterator), entry != 0 {
        let owned = IOObject(entry)
        try body(owned)
    }
}

// MARK: - Property reads

/// Read a typed property from an IORegistry entry. Returns `nil` if the
/// property is missing or the bridged CFType is not assignable to `T`.
///
/// Why `takeRetainedValue()`: `IORegistryEntryCreateCFProperty` returns a
/// `Unmanaged<CFTypeRef>` carrying a +1 retain that the caller owns. Using
/// `takeRetainedValue()` transfers that retain into a Swift-managed
/// reference, so the moment we leave this function ARC handles the
/// release. `takeUnretainedValue()` would leak.
///
/// The `as T` bridge handles the cases we care about (`NSNumber`,
/// `NSString`, `NSData`, `NSDictionary`, `NSArray`); for IOKit's exotic
/// types Swift can't bridge cleanly, callers use the bridging-header
/// helpers (added in later phases as needed).
func property<T>(
    _ key: String,
    of entry: borrowing IOObject,
    as type: T.Type,
    options: IOOptionBits = 0
) -> T? {
    guard let cfRef = IORegistryEntryCreateCFProperty(
        entry.raw,
        key as CFString,
        kCFAllocatorDefault,
        options
    )?.takeRetainedValue() else {
        return nil
    }
    return cfRef as? T
}

// MARK: - Registry path

/// The stable IOKit registry path of an entry on a given plane. Returns
/// `nil` only on hard kernel failure (the path is well-defined for any
/// valid registry entry).
///
/// Why this matters for Manifold: `PortID` derives directly from
/// `kIOServicePlane` paths (DECISIONS.md D9). The path stays constant
/// across replug events on the same physical port — that's the property
/// that makes SwiftUI rows update in place rather than animate
/// remove-then-add when a device disconnects and reconnects.
///
/// `MAXPATHLEN` (1024) is comfortably above any path IOKit can produce;
/// the kernel itself enforces a far smaller cap on registry path length.
func registryPath(
    of entry: borrowing IOObject,
    plane: String = kIOServicePlane
) -> String? {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let result = path.withUnsafeMutableBufferPointer { buf -> kern_return_t in
        guard let base = buf.baseAddress else { return KERN_FAILURE }
        return IORegistryEntryGetPath(entry.raw, plane, base)
    }
    guard result == KERN_SUCCESS else { return nil }
    // `String(validatingCString:)` replaces the deprecated
    // `String(cString:)` overload. Reads up to the first NUL byte and
    // returns nil only if the bytes aren't valid UTF-8 — IOKit registry
    // paths are always ASCII, so in practice this is a clean read.
    return path.withUnsafeBufferPointer { buf -> String? in
        guard let base = buf.baseAddress else { return nil }
        return String(validatingCString: base)
    }
}

// MARK: - Scoped iterators

/// Acquire a child iterator on a given plane, hand it to `body`, and
/// release it on scope exit. No-op if the entry has no children on that
/// plane.
///
/// Why scoped: `IORegistryEntryGetChildIterator` returns an iterator
/// handle the caller must release with `IOObjectRelease`. Mirroring the
/// Swift "scoped resource" pattern (`with…`) keeps that release
/// guaranteed even when `body` throws.
///
/// We deliberately do NOT wrap the iterator in `IOObject`. The iterator
/// is consumed entry-by-entry by `forEachEntry` and conceptually distinct
/// from the entries it yields; mixing the two into one type would invite
/// the kind of double-release bug `IOObject` was built to prevent.
func withChildren(
    of entry: borrowing IOObject,
    plane: String = kIOServicePlane,
    _ body: (io_iterator_t) throws -> Void
) rethrows {
    var iter: io_iterator_t = 0
    let result = IORegistryEntryGetChildIterator(entry.raw, plane, &iter)
    guard result == KERN_SUCCESS, iter != 0 else { return }
    defer { IOObjectRelease(iter) }
    try body(iter)
}

/// Match services against a matching dictionary, hand the iterator to
/// `body`, and release it on scope exit.
///
/// Subtle ARC contract: `IOServiceGetMatchingServices` *consumes* one
/// reference on the matching dictionary. The matching dictionaries we
/// pass in come from `IOServiceMatching(_:)`, which already returns +1
/// retained — so the consume balances out and there is no leak. This is
/// only safe because we feed it `IOServiceMatching` results directly.
/// If you ever need to pass a hand-built `CFMutableDictionary`, retain
/// it first.
///
/// `kIOMainPortDefault` is the modern (macOS 12+) replacement for the
/// older `kIOMasterPortDefault`. Both still work; we use the newer name
/// to avoid the deprecation warning under Swift 6 strict.
func withMatchingServices(
    _ matchingDict: CFDictionary,
    _ body: (io_iterator_t) throws -> Void
) rethrows {
    var iter: io_iterator_t = 0
    let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iter)
    guard result == KERN_SUCCESS, iter != 0 else { return }
    defer { IOObjectRelease(iter) }
    try body(iter)
}
