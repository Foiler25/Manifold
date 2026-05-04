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
// USBCPortWalker.swift
//
// Walks `AppleTCControllerType10` registry entries — the IOKit class
// for each physical USB-C chassis port on Apple Silicon. Unlike
// `USBWalker` which sees only data-enumerated USB devices, this
// walker sees the *port* itself: empty, occupied with a data device,
// or occupied with a power-only sink (CC contract, no USB descriptors).
//
// Why this exists: a CC-only USB-C connection (a charging laser tape
// measure, a dumb battery pack, a charger in pass-through mode) never
// enters the IOUSB plane because no USB device descriptor exchange
// happens. The Mac's USB-C controller chip negotiates the power
// contract via the CC pins; the OS exposes the resulting transport
// state through `IOPortTransportState*` nodes under each
// `AppleTCControllerType10`. `TransportsActive` lists which
// transports won the contract — `("CC")` alone means power-only.
//
// IOKit keys read:
//   - `PortNumber` (Int) — 1-indexed chassis port slot.
//   - `ConnectionActive` (Bool) — cable detected at the receptacle.
//   - `TransportsActive` ([String]) — protocols that won the
//     contract. `["CC"]` → power-only; anything containing `USB2`
//     or `USB3` → data device.
//   - `PortTypeDescription` (String) — "USB-C" today; future Apple
//     Silicon chassis revisions may add other connector kinds.

import Foundation
import IOKit
import os
import ManifoldKit

// MARK: - USBCPortSnapshot

/// Phase-13 internal projection of one chassis USB-C port. Flat —
/// `PortGraphBuilder` lifts these into `Host.physicalPorts`.
///
/// `Sendable` because the walker hops onto the IOKitQueue actor and
/// returns the snapshot to MainActor.
struct USBCPortSnapshot: Sendable, Equatable {

    /// 1-indexed chassis slot. Matches the laptop's physical layout
    /// (port 1 = leftmost on a MacBook Pro).
    let position: Int

    /// True when a cable is detected at the receptacle. Independent
    /// of whether USB data enumeration succeeded.
    let connectionActive: Bool

    /// Protocols that won the contract. Walker reads the IOKit
    /// `TransportsActive` array verbatim. Empty + `connectionActive
    /// = false` is the empty-port case; `["CC"]` is power-only;
    /// anything with `USB2` / `USB3` / `CIO` / `DisplayPort` is a
    /// data device.
    let transportsActive: [String]

    /// "USB-C" / "MagSafe 3" / future. Surfaced verbatim from
    /// IOKit so the model layer can decide how to classify.
    let portTypeDescription: String?
}

// MARK: - USBCPortRegistrySource

/// Anything that can produce a flat list of `USBCPortSnapshot`s.
/// One live IOKit implementation. Tests use direct construction of
/// `USBCPortSnapshot` rather than fixture replay since the schema
/// is small and stable.
protocol USBCPortRegistrySource: Sendable {
    func enumerate() throws -> [USBCPortSnapshot]
}

// MARK: - LiveIOKitUSBCPortSource

struct LiveIOKitUSBCPortSource: USBCPortRegistrySource {

    /// `AppleTCControllerType10` is the class on M1/M2/M3-class
    /// Macs. If Apple bumps the suffix on a future chip family,
    /// the matching dictionary will return zero results and the
    /// walker soft-fails to an empty list — same defensive shape
    /// as the TB walker on a non-TB Mac.
    let matchingClassName: String

    init(matchingClassName: String = "AppleTCControllerType10") {
        self.matchingClassName = matchingClassName
    }

    func enumerate() throws -> [USBCPortSnapshot] {
        guard let matching = IOServiceMatching(matchingClassName) else {
            throw IOKitError.matchingDictionaryFailed
        }

        var results: [USBCPortSnapshot] = []
        withMatchingServices(matching) { iter in
            forEachEntry(in: iter) { entry in
                if let snapshot = Self.makeSnapshot(from: entry) {
                    results.append(snapshot)
                }
            }
        }
        // Sort by position so UI gets a stable left-to-right order
        // regardless of registry iteration order.
        return results.sorted { $0.position < $1.position }
    }

    static func makeSnapshot(from entry: borrowing IOObject) -> USBCPortSnapshot? {
        // Position is required — without it we can't render the port.
        guard let position = intProperty("PortNumber", of: entry) else {
            return nil
        }
        let connectionActive = boolProperty("ConnectionActive", of: entry) ?? false
        let transports = stringArrayProperty("TransportsActive", of: entry) ?? []
        let typeDesc = stringProperty("PortTypeDescription", of: entry)
        return USBCPortSnapshot(
            position: position,
            connectionActive: connectionActive,
            transportsActive: transports,
            portTypeDescription: typeDesc
        )
    }
}

// MARK: - USBCPortWalker

/// Adapter that owns a `USBCPortRegistrySource` and exposes a
/// `walk()` matching the shape of `USBWalker.walk()` /
/// `ThunderboltWalker.walk()`. Thin so production and tests share
/// one entry point.
struct USBCPortWalker: Sendable {

    private let source: any USBCPortRegistrySource

    init(source: any USBCPortRegistrySource = LiveIOKitUSBCPortSource()) {
        self.source = source
    }

    func walk() throws -> [USBCPortSnapshot] {
        try source.enumerate()
    }
}
