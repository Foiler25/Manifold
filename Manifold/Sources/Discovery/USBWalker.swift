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
// USBWalker.swift
//
// Phase-1 USB discovery. Walks every `AppleUSBHostController`, descends
// the IOService plane recursively, and emits one `USBDeviceSnapshot`
// per `IOUSBHostDevice` it encounters. Read-only — no graph mutation,
// no event subscription, no caching.
//
// Why a snapshot type instead of `ManifoldKit.Device` directly: Phase 2
// is responsible for turning these raw walks into `Host`/`Port`/`Device`
// trees, ID derivation, and the `PortGraph`. Decoupling Phase 1's "what
// IOKit said" from Phase 2's "what the model says" keeps each phase
// landable on its own and makes the unit boundary obvious.
//
// Why an injected source protocol: Phase 1's acceptance criterion
// requires `USBWalkerTests.swift` to "parse the fixture and assert the
// right device count + names." A test cannot legally call IOKit live —
// the result would change every time someone plugs or unplugs anything,
// or fails entirely in CI. The `USBRegistrySource` protocol lets the
// production walker hit IOKit and the tests hit a captured JSON fixture
// through the same downstream code path. The protocol stays internal to
// the Manifold target so it does not leak into ManifoldKit.

import Foundation
import IOKit
import os

// MARK: - USBDeviceSnapshot

/// Phase-1 internal representation of one connected USB device. A flat
/// projection of the raw IOKit properties Manifold cares about, before
/// any normalization into the ManifoldKit data model.
///
/// `Equatable`/`Sendable` so tests can compare arrays of snapshots and
/// the type can cross actor boundaries when Phase 3 wires events.
struct USBDeviceSnapshot: Sendable, Equatable {

    /// Stable IOKit registry path on the IOService plane. Phase 2 turns
    /// this into a `PortID` and uses it as the device's parent-pointer.
    let registryPath: String

    /// USB Vendor ID (`idVendor`). 16 bits per the USB spec.
    let vendorID: UInt16

    /// USB Product ID (`idProduct`). 16 bits per the USB spec.
    let productID: UInt16

    /// Resolved product name. May be `nil` for devices that ship no
    /// USB string descriptors (some cheap hubs, certain HID dongles).
    let productName: String?

    /// Resolved vendor name. Same caveats as `productName`.
    let vendorName: String?

    /// Device serial number, if the device exposes `iSerialNumber`.
    /// Used by Phase 2's `DeviceID.make(...)` to build a stable
    /// VID:PID:serial composite identifier (DECISIONS.md D9).
    let serial: String?

    /// USB version in BCD (e.g. 0x0210 for USB 2.1, 0x0320 for USB 3.2).
    /// Phase 2 normalizes to `USBVersion`.
    let bcdUSB: UInt16?

    /// Negotiated link speed code (IOKit's `Speed` enum). Map via
    /// `USBDiscoveryConstants.speedName(for:)` for human-readable form.
    let speed: UInt32?

    /// Power the device requested at enumeration time, in milliamps.
    /// Compared against per-port budgets by Phase 8's `PowerDeficitRule`.
    let requestedPowerMA: Int?

    /// Port number on the parent hub or controller. 1-indexed at
    /// publication; we keep the raw IOKit value here (no offset).
    let portNum: Int?

    /// IOKit `locationID` — encodes the physical port path as nested
    /// nibbles. Used by Phase 2 for parent/child reconstruction.
    let locationID: UInt32?
}

// MARK: - USBRegistrySource

/// Anything that can produce a flat list of USB device snapshots.
/// Two implementations ship: live IOKit traversal (`LiveIOKitUSBSource`)
/// and JSON-fixture replay (`FixtureUSBSource`).
protocol USBRegistrySource: Sendable {
    func enumerate() throws -> [USBDeviceSnapshot]
}

// MARK: - LiveIOKitUSBSource

/// Production source: walks live IOKit. Runs on whichever thread calls
/// `enumerate()`. Phase 3 will move walks off the main thread; Phase 1
/// just runs synchronously on the caller (typically MainActor).
struct LiveIOKitUSBSource: USBRegistrySource {

    /// IOKit class to seed the matching dictionary with. Defaulted to
    /// `AppleUSBHostController` per SPEC.md §18 Phase 1 acceptance #2;
    /// override in tests if a future fixture wants a different root.
    let matchingClassName: String

    init(matchingClassName: String = USBDiscoveryConstants.hostControllerClassName) {
        self.matchingClassName = matchingClassName
    }

    func enumerate() throws -> [USBDeviceSnapshot] {
        guard let matching = IOServiceMatching(matchingClassName) else {
            // The matching dictionary builder returns nil only on a
            // malformed class name. Surface as a hard error so we hear
            // about it loudly during development.
            throw IOKitError.matchingDictionaryFailed
        }

        // Single accumulator threaded through the whole walk. Inout
        // captures into nonescaping closures (`forEachEntry`,
        // `withChildren`) are allowed by the borrow checker; this is
        // why those helpers were defined as `rethrows` non-escaping in
        // the first place.
        var results: [USBDeviceSnapshot] = []

        // The inner closures don't throw, so `withMatchingServices`
        // (rethrows) doesn't propagate `try` here either.
        withMatchingServices(matching) { controllerIter in
            forEachEntry(in: controllerIter) { controller in
                Self.walkDescendants(of: controller, into: &results)
            }
        }

        return results
    }

    /// Recursively descend the IOService plane from `entry`, appending a
    /// snapshot whenever we hit an `IOUSBHostDevice`-conforming entry.
    ///
    /// Recursion via an explicit static method (rather than an instance
    /// closure) keeps the call graph easy to read and sidesteps any
    /// concern about `self` capture inside nested non-escaping closures.
    private static func walkDescendants(
        of entry: borrowing IOObject,
        into results: inout [USBDeviceSnapshot]
    ) {
        // `IOObjectConformsTo` returns non-zero (boolean true) when the
        // entry is of the named class or a descendant. We match against
        // the device class string; controllers themselves don't match
        // (they conform to AppleUSBHostController, not IOUSBHostDevice),
        // so the controller node is correctly *not* emitted.
        if IOObjectConformsTo(entry.raw, USBDiscoveryConstants.hostDeviceClassName) != 0 {
            if let snapshot = makeSnapshot(from: entry) {
                results.append(snapshot)
            }
            // Fall through: a hub IS a device AND has children worth
            // visiting. So we always recurse, never return early.
        }

        withChildren(of: entry) { childIter in
            forEachEntry(in: childIter) { child in
                walkDescendants(of: child, into: &results)
            }
        }
    }

    /// Read every property Manifold cares about off a single registry
    /// entry. Returns `nil` only when the entry lacks both VID and PID,
    /// which means it is not a real USB device (e.g., a stale orphan
    /// node mid-disconnect). Anything with a VID is included even if
    /// other strings are missing.
    ///
    /// Internal (not private) so Phase 3's `EventService` can call it
    /// directly from a hot-plug callback — the same property-read
    /// pipeline produces both initial-walk snapshots and hot-plug
    /// snapshots.
    static func makeSnapshot(from entry: borrowing IOObject) -> USBDeviceSnapshot? {
        let keys = USBDiscoveryConstants.PropertyKey.self

        guard
            let vid = uint16Property(keys.idVendor, of: entry),
            let pid = uint16Property(keys.idProduct, of: entry)
        else {
            return nil
        }

        let path = registryPath(of: entry) ?? "<unknown>"
        let bcd = uint16Property(keys.bcdUSB, of: entry)

        return USBDeviceSnapshot(
            registryPath:     path,
            vendorID:         vid,
            productID:        pid,
            productName:      stringProperty(keys.usbProductName,  of: entry),
            vendorName:       stringProperty(keys.usbVendorName,   of: entry),
            serial:           stringProperty(keys.iSerialNumber,   of: entry),
            bcdUSB:           bcd,
            speed:            resolveSpeed(from: entry, bcdUSB: bcd),
            requestedPowerMA: resolvePower(from: entry),
            portNum:          intProperty(   keys.portNum,         of: entry),
            locationID:       uint32Property(keys.locationID,      of: entry)
        )
    }

    /// Walk the speed-property fallback chain and, as a last resort,
    /// infer the link speed from `bcdUSB`. Per SPEC.md §18 Phase 2
    /// rev-3 fallback bullet (resolves Builder Phase 1 Q4).
    ///
    /// Sequence:
    ///   1. Try every key in `FallbackKey.speedAlternates`.
    ///   2. If every key returned nil, infer from `bcdUSB`:
    ///      - bcdUSB ≥ 0x0300 → return Speed code 3 ("Super Speed")
    ///      - bcdUSB == 0x0210 or 0x0200 → return Speed code 2 ("High Speed")
    ///      - bcdUSB == 0x0110 or 0x0100 → return Speed code 1 ("Full Speed")
    ///   3. Otherwise nil — surfaces as "Unknown" in the popover.
    ///
    /// The bcd inference is conservative: if the device says "I support
    /// USB 3.x" we report Super Speed even though it might be on a
    /// USB 2.0 link upstream. That's a known weakness — Phase 8's
    /// "Running @ USB 2.0" diagnostic catches the mismatch correctly
    /// once the negotiated speed is also visible. For Phase 2 the goal
    /// is to never show "Unknown" when *any* signal is available.
    private static func resolveSpeed(
        from entry: borrowing IOObject,
        bcdUSB: UInt16?
    ) -> UInt32? {
        for key in USBDiscoveryConstants.FallbackKey.speedAlternates {
            if let value = uint32Property(key, of: entry) {
                return value
            }
        }
        return deriveSpeedFromBcd(bcdUSB)
    }

    /// Walk the requested-power fallback chain. Per SPEC.md §18 Phase 2
    /// rev-3 fallback bullet.
    ///
    /// Unlike speed, there is no good last-resort heuristic for power —
    /// nothing in the descriptor encodes "how much current the device
    /// will pull" implicitly. nil from every alternate means we
    /// genuinely don't know; the popover row renders this as "—".
    private static func resolvePower(from entry: borrowing IOObject) -> Int? {
        for key in USBDiscoveryConstants.FallbackKey.powerAlternates {
            if let value = intProperty(key, of: entry) {
                return value
            }
        }
        return nil
    }

    /// Map `bcdUSB` to an IOKit Speed enum code. Returns nil for
    /// values we don't recognise (vendor-extended BCDs) so callers can
    /// fall through to "Unknown" rather than reporting a wrong speed.
    ///
    /// Internal (was private) for direct unit-test coverage per
    /// Reviewer F13 — the BCD → Speed-code mapping is a pure
    /// arithmetic table with several clusters (USB 1.x → 1, USB 2.x →
    /// 2, USB 3.x → 3, USB4 → 4) and benefits from per-cluster pin
    /// tests rather than only the indirect coverage from the live
    /// USBWalker walk.
    static func deriveSpeedFromBcd(_ bcdUSB: UInt16?) -> UInt32? {
        guard let bcd = bcdUSB else { return nil }
        switch bcd {
        case 0x0100, 0x0110: return 1   // USB 1.x → Full Speed
        case 0x0200, 0x0210: return 2   // USB 2.x → High Speed
        case 0x0300...0x03FF: return 3  // USB 3.x → Super Speed (3.1/3.2 details lost; conservative)
        case 0x0400...0x04FF: return 4  // USB4 → Super Speed+
        default: return nil
        }
    }
}

// MARK: - FixtureUSBSource

/// Test source: reads a captured JSON fixture and yields the same
/// snapshots a live walk would. The fixture format mirrors raw IOKit
/// property names so a future `ioreg`-to-fixture script can produce one
/// without any normalization step.
///
/// Fixture schema (top-level dict):
///   - `schemaVersion`: Int. Current = 1; bump on breaking changes.
///   - `captureSource`: String. Free-form provenance note.
///   - `devices`: [Device]. Each entry uses raw IOKit keys
///     (`idVendor`, `idProduct`, `USB Product Name`, etc.).
struct FixtureUSBSource: USBRegistrySource {

    /// URL of the JSON fixture to load.
    let fixtureURL: URL

    init(fixtureURL: URL) {
        self.fixtureURL = fixtureURL
    }

    func enumerate() throws -> [USBDeviceSnapshot] {
        let data = try Data(contentsOf: fixtureURL)
        let envelope = try JSONDecoder().decode(FixtureEnvelope.self, from: data)
        return envelope.devices.map { $0.toSnapshot() }
    }

    // MARK: Fixture decoding shapes

    /// Top-level fixture envelope. Versioned so fixture format changes
    /// can be detected explicitly rather than silently producing wrong
    /// results.
    private struct FixtureEnvelope: Decodable {
        let schemaVersion: Int
        let captureSource: String?
        let devices: [FixtureDevice]
    }

    /// One device record. Field names match the raw IOKit property
    /// strings Manifold reads in production. `CodingKeys` does the
    /// translation between IOKit's spaces-and-mixed-case names and
    /// Swift identifiers.
    private struct FixtureDevice: Decodable {
        let registryPath: String
        let idVendor: UInt16
        let idProduct: UInt16
        let usbProductName: String?
        let usbVendorName: String?
        let serial: String?
        let bcdUSB: UInt16?
        let speed: UInt32?
        let requestedPowerMA: Int?
        let portNum: Int?
        let locationID: UInt32?

        enum CodingKeys: String, CodingKey {
            case registryPath
            case idVendor
            case idProduct
            case usbProductName  = "USB Product Name"
            case usbVendorName   = "USB Vendor Name"
            case serial          = "iSerialNumber"
            case bcdUSB
            case speed           = "Speed"
            case requestedPowerMA = "Requested Power"
            case portNum         = "PortNum"
            case locationID
        }

        func toSnapshot() -> USBDeviceSnapshot {
            USBDeviceSnapshot(
                registryPath:     registryPath,
                vendorID:         idVendor,
                productID:        idProduct,
                productName:      usbProductName,
                vendorName:       usbVendorName,
                serial:           serial,
                bcdUSB:           bcdUSB,
                speed:            speed,
                requestedPowerMA: requestedPowerMA,
                portNum:          portNum,
                locationID:       locationID
            )
        }
    }
}

// MARK: - USBWalker

/// Phase-1 entry point for USB discovery. Wraps a `USBRegistrySource` and
/// adds Manifold-specific concerns on top: ordered output, optional
/// console logging.
///
/// Final class so subclasses can't introduce mutable state that would
/// break Sendable. No `@MainActor` because the walk does not touch UI;
/// callers (Phase 3+) hop to MainActor before mutating the `PortGraph`.
final class USBWalker: Sendable {

    /// Source of raw device records. Default to live IOKit; tests inject
    /// `FixtureUSBSource`.
    private let source: any USBRegistrySource

    init(source: any USBRegistrySource = LiveIOKitUSBSource()) {
        self.source = source
    }

    /// Perform one walk and return the resulting snapshots, sorted by
    /// `registryPath` so the output is deterministic across runs and
    /// across the live/fixture sources.
    func walk() throws -> [USBDeviceSnapshot] {
        let raw = try source.enumerate()
        return raw.sorted { $0.registryPath < $1.registryPath }
    }

    /// Walk and log each device's VID/PID/name/speed/power. Returns
    /// the same list `walk()` would. Used by `DiscoveryService.walk()`
    /// so each discovery cycle leaves a one-line-per-device summary
    /// in the `events.notice` unified-log category.
    ///
    /// Phase 3 retired the Phase-1 DEBUG-only stderr dual-emit per
    /// SPEC §16.1 — `.notice` is persisted by the unified log without
    /// any DEBUG crutch, so the stderr branch is gone. Per-walk
    /// summary headline goes through `discovery.info` (low-frequency,
    /// fine to lose to default filtering); per-device lines go through
    /// `events.notice` so they survive in `log show` after the fact.
    ///
    /// Privacy markers are `.public` because everything we log here
    /// (VID, PID, product name, link speed, milliamps) is hardware
    /// metadata, not user PII.
    func walkAndLog() throws -> [USBDeviceSnapshot] {
        let devices = try walk()
        Log.discovery.info("USB walk found \(devices.count, privacy: .public) device(s)")
        for device in devices {
            let line = String(
                format: "  VID=0x%04X PID=0x%04X name=%@ speed=%@ power=%@",
                device.vendorID,
                device.productID,
                device.productName ?? "<unnamed>",
                USBDiscoveryConstants.speedName(for: device.speed),
                device.requestedPowerMA.map { "\($0) mA" } ?? "—"
            )
            Log.events.notice("\(line, privacy: .public)")
        }
        return devices
    }
}
