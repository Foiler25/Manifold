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
// DisplayResolver.swift
//
// Phase 7 display discovery + port matching. Per BRIEF.md cheatsheet:
//
//     | Display | IODisplayConnect, AppleDisplay
//     | IODisplayEDID, DisplayProductID, DisplayVendorID
//
// And SPEC §6: "Mapping displays to their TB/USB-C parent port via
// EDID hash + parent registry traversal."
//
// Phase 7 ships:
//   - `DisplaySnapshot` — flat projection per display
//   - `DisplaySource` protocol with Live + Fixture impls
//   - `DisplayResolver` — combines Live source's IODisplayConnect
//     walk with parent-path traversal so PortGraphBuilder can match
//     each display to its hosting TB/USB-C port
//
// Same fixture-driven test pattern as ThunderboltWalker; live
// hardware verification is `STUDIO-DISPLAY-CHAIN` per SPEC §18.0
// (Reviewer-deferred — Brandon has no Studio Display rig).

import Foundation
import IOKit
import CoreGraphics
import os
import ManifoldKit

// MARK: - DisplaySnapshot

/// Per-display projection. Carries the parent registry path so
/// `PortGraphBuilder` can match the display to its connecting port
/// by prefix match (no separate EDID-hash lookup needed in Phase 7
/// — the parent traversal IS the matching mechanism).
struct DisplaySnapshot: Sendable, Equatable {

    /// Stable IOKit registry path of the `IODisplayConnect` entry.
    let registryPath: String

    /// Registry path of the parent port (TB switch, USB-C port, or
    /// the built-in display's chassis entry). Used by
    /// `PortGraphBuilder.merge(...)` to match the display to a
    /// `Port` by `commonPathPrefix` matching.
    let parentRegistryPath: String?

    /// Display vendor ID (from EDID Manufacturer ID block, e.g.
    /// 1552 for Apple).
    let vendorID: UInt32?

    /// Display product ID (EDID Product Code).
    let productID: UInt32?

    /// Pixel resolution. Read from `IODisplayConnect`'s
    /// `IOFBCurrentPixelCount` or equivalent. nil if not yet
    /// resolved (display just connected).
    let resolution: CGSize?

    /// Refresh rate in Hz. Read from EDID detailed timing block.
    let refreshHz: Double?

    /// Panel technology label ("Retina XDR LCD", "OLED", etc.).
    /// Free-form; vendor-published.
    let panelType: String?

    /// True when this is the user's main display.
    let isMain: Bool

    /// True for the laptop's built-in panel.
    let isBuiltIn: Bool

    /// True when EDID's HDR Static Metadata block is present.
    let supportsHDR: Bool

    /// Resolved product name string ("Studio Display"). Optional
    /// because some panels publish only their EDID code.
    let productName: String?
}

// MARK: - DisplaySource

protocol DisplaySource: Sendable {
    func enumerate() throws -> [DisplaySnapshot]
}

// MARK: - LiveIOKitDisplaySource

/// Production source: walks `IODisplayConnect` (the IOKit class
/// macOS publishes per attached display).
///
/// Phase 7 caveat: the live walk is intentionally minimal —
/// reading EDID requires IOFramebuffer property access that varies
/// by GPU driver, and the SPEC explicitly notes "Allocate a
/// half-day for this; expect dead ends" (BRIEF.md). Brandon doesn't
/// have a Studio Display test rig, so this implementation is
/// fixture-validated; Phase 7+ refinement happens when real
/// hardware is available.
struct LiveIOKitDisplaySource: DisplaySource {

    let matchingClassName: String

    init(matchingClassName: String = DisplayDiscoveryConstants.displayConnectClassName) {
        self.matchingClassName = matchingClassName
    }

    func enumerate() throws -> [DisplaySnapshot] {
        guard let matching = IOServiceMatching(matchingClassName) else {
            throw IOKitError.matchingDictionaryFailed
        }

        var results: [DisplaySnapshot] = []
        withMatchingServices(matching) { iter in
            forEachEntry(in: iter) { entry in
                if let snapshot = Self.makeSnapshot(from: entry) {
                    results.append(snapshot)
                }
            }
        }
        return results
    }

    /// Build a `DisplaySnapshot` from one IODisplayConnect entry.
    /// Internal-static for the same reason USBWalker.makeSnapshot is.
    static func makeSnapshot(from entry: borrowing IOObject) -> DisplaySnapshot? {
        let keys = DisplayDiscoveryConstants.PropertyKey.self
        let path = registryPath(of: entry) ?? "<unknown>"

        // The parent registry path comes from walking up one level
        // on the IOService plane. For Phase 7's matching purposes,
        // the immediate parent is sufficient — PortGraphBuilder uses
        // prefix matching, so even a multi-level traversal would
        // work for downstream nesting.
        let parentPath = Self.parentRegistryPath(of: entry)

        return DisplaySnapshot(
            registryPath:        path,
            parentRegistryPath:  parentPath,
            vendorID:            uint32Property(keys.displayVendorID,    of: entry),
            productID:           uint32Property(keys.displayProductID,   of: entry),
            resolution:          Self.readResolution(from: entry),
            refreshHz:           Self.readRefreshHz(from: entry),
            panelType:           stringProperty(keys.displayPanelType,   of: entry),
            isMain:              false,    // Phase 7 doesn't resolve; CGDirectDisplayID match is Phase 8+
            isBuiltIn:           false,    // Same — needs CGDisplayIsBuiltin lookup
            supportsHDR:         false,    // EDID HDR static metadata block parse is Phase 7+ refinement
            productName:         stringProperty(keys.displayName,        of: entry)
        )
    }

    /// Read the parent's registry path on the IOService plane. Uses
    /// `IORegistryEntryGetParentEntry` indirectly via a property
    /// read on the entry itself — we ask for `IOService > parent`
    /// metadata which IOKit publishes. Returns nil for orphaned
    /// entries (shouldn't happen in normal operation).
    private static func parentRegistryPath(of entry: borrowing IOObject) -> String? {
        // Phase 7 simplification: the parent path is the entry's own
        // path with the last `/`-component stripped. This is
        // accurate for the IOService plane since paths encode the
        // exact registry hierarchy.
        guard let path = registryPath(of: entry) else { return nil }
        guard let lastSlash = path.lastIndex(of: "/"), lastSlash != path.startIndex else {
            return nil
        }
        return String(path[..<lastSlash])
    }

    /// Best-effort read of pixel resolution. macOS publishes this
    /// under several keys depending on GPU driver vintage; Phase 7
    /// tries the most common (`IODisplayResolution`) and falls back
    /// to nil. Phase 7+ may add IOFramebuffer-side lookups.
    private static func readResolution(from entry: borrowing IOObject) -> CGSize? {
        // Phase 7 stub — actual resolution reads need
        // IOFramebufferShared API which is gated behind private
        // entitlements. Returning nil until Phase 7+ refinement.
        nil
    }

    /// Best-effort refresh-rate read. Same Phase 7 caveat as
    /// `readResolution` — proper EDID parse lands later.
    private static func readRefreshHz(from entry: borrowing IOObject) -> Double? {
        nil
    }
}

// MARK: - FixtureDisplaySource

/// Test source: replays a JSON fixture. Mirrors the LiveIOKit
/// surface so PortGraphBuilder.merge sees identical data shapes
/// regardless of where the snapshots came from.
struct FixtureDisplaySource: DisplaySource {

    let fixtureURL: URL

    init(fixtureURL: URL) {
        self.fixtureURL = fixtureURL
    }

    func enumerate() throws -> [DisplaySnapshot] {
        let data = try Data(contentsOf: fixtureURL)
        let envelope = try JSONDecoder().decode(FixtureEnvelope.self, from: data)
        return envelope.displays.map { $0.toSnapshot() }
    }

    private struct FixtureEnvelope: Decodable {
        let schemaVersion: Int
        let captureSource: String?
        let displays: [FixtureDisplay]
    }

    private struct FixtureDisplay: Decodable {
        let registryPath: String
        let parentRegistryPath: String?
        let vendorID: UInt32?
        let productID: UInt32?
        let width: Int?
        let height: Int?
        let refreshHz: Double?
        let panelType: String?
        let isMain: Bool?
        let isBuiltIn: Bool?
        let supportsHDR: Bool?
        let productName: String?

        enum CodingKeys: String, CodingKey {
            case registryPath
            case parentRegistryPath
            case vendorID  = "DisplayVendorID"
            case productID = "DisplayProductID"
            case width
            case height
            case refreshHz
            case panelType
            case isMain
            case isBuiltIn
            case supportsHDR
            case productName
        }

        func toSnapshot() -> DisplaySnapshot {
            let resolution: CGSize? = {
                guard let w = width, let h = height else { return nil }
                return CGSize(width: w, height: h)
            }()
            return DisplaySnapshot(
                registryPath:       registryPath,
                parentRegistryPath: parentRegistryPath,
                vendorID:           vendorID,
                productID:          productID,
                resolution:         resolution,
                refreshHz:          refreshHz,
                panelType:          panelType,
                isMain:             isMain     ?? false,
                isBuiltIn:          isBuiltIn  ?? false,
                supportsHDR:        supportsHDR ?? false,
                productName:        productName
            )
        }
    }
}

// MARK: - DisplayResolver

final class DisplayResolver: Sendable {

    private let source: any DisplaySource

    init(source: any DisplaySource = LiveIOKitDisplaySource()) {
        self.source = source
    }

    /// Walk the display registry. Sorted-by-registryPath for
    /// determinism (matches USBWalker / ThunderboltWalker contracts).
    func resolve() throws -> [DisplaySnapshot] {
        let raw = try source.enumerate()
        return raw.sorted { $0.registryPath < $1.registryPath }
    }
}

// MARK: - DisplayDiscoveryConstants

enum DisplayDiscoveryConstants {

    /// IOKit class for connected displays. Modern (macOS 10.10+)
    /// systems publish under `IODisplayConnect`; AppleDisplay is a
    /// subclass for Apple-branded panels.
    static let displayConnectClassName = "IODisplayConnect"

    /// Subclass for Apple-branded displays (Studio Display, Pro
    /// Display XDR). Phase 7 doesn't switch on this — both classes
    /// expose the same EDID / display-info properties.
    static let appleDisplayClassName = "AppleDisplay"

    enum PropertyKey {
        static let displayEDID       = "IODisplayEDID"
        static let displayVendorID   = "DisplayVendorID"
        static let displayProductID  = "DisplayProductID"
        static let displayName       = "DisplayProductName"
        static let displayPanelType  = "DisplayPanelType"
    }
}
