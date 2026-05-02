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
// ThunderboltWalker.swift
//
// Phase 7 TB discovery. Walks `IOThunderboltSwitchType2` registry
// entries (the IOKit class representing TB switches — both the host
// controller's root switch and any downstream switches inside
// daisy-chained devices). Per BRIEF.md cheatsheet:
//
//     | Thunderbolt | IOThunderboltSwitchType2, IOThunderboltPort
//     | IOThunderboltLinkType, IOThunderboltLinkSpeed,
//     | IOThunderboltLinkWidth, Route String
//
// Same architecture as USBWalker: an injected `TBRegistrySource`
// protocol with a `LiveIOKitTBSource` (production IOKit walk) and a
// `FixtureTBSource` (JSON-replay for tests). Brandon does NOT have a
// Studio Display test rig (per `QUESTIONS.md` #9), so live verification
// is `STUDIO-DISPLAY-CHAIN` per SPEC §18.0 — Reviewer-deferred.
// Fixture-driven tests carry the load in CI.

import Foundation
import IOKit
import os
import ManifoldKit

// MARK: - TBDeviceSnapshot

/// Phase-7 internal projection of one Thunderbolt switch / device as
/// IOKit reports it. Flat — `PortGraphBuilder.merge(...)` reconstructs
/// the daisy-chain hierarchy from `routeString` + `registryPath`.
///
/// `Sendable` so the value can hop from the IOKit queue back to
/// MainActor inside `IOKitQueue.tbWalk(...)`.
struct TBDeviceSnapshot: Sendable, Equatable {

    /// Stable IOKit registry path on the IOService plane. Phase 7
    /// uses path-prefix matching to nest children under parents.
    let registryPath: String

    /// TB Route String — the per-hop encoding (`xx-yy-zz`) that
    /// uniquely identifies the device's position in the daisy chain.
    /// `"0-0"` is the host TB controller; `"1-0"` is port 1 directly
    /// off the host; `"1-2"` is port 2 of the device on host port 1.
    let routeString: String?

    /// `IOThunderboltLinkType` — TB protocol generation. `1` = TB1,
    /// `2` = TB2, `3` = TB3, `4` = TB4, `5` = USB4. nil for the
    /// root host controller (no upstream link).
    let linkType: UInt32?

    /// `IOThunderboltLinkSpeed` — negotiated link bitrate. The
    /// IOKit value is in Gb/s × 10 (so `200` = 20 Gbps); we expose
    /// raw and let `PortGraphBuilder` translate to `Bitrate`.
    let linkSpeed: UInt32?

    /// `IOThunderboltLinkWidth` — number of lanes (typically 1, 2,
    /// or 4). Used by Phase 8's "TB4 device on TB3 link" diagnostic.
    let linkWidth: UInt32?

    /// Vendor name string the device advertises ("Apple Inc.",
    /// "Other World Computing", etc.). Optional — not every TB
    /// switch publishes one.
    let vendorName: String?

    /// Device name string ("Studio Display", "Thunderbolt Hub").
    /// Same caveat as `vendorName`.
    let deviceName: String?

    /// PCIe vendor ID for the embedded PCIe bridge. Nil for the
    /// root TB switch (no PCIe downstream from itself).
    let vendorID: UInt16?

    /// PCIe device ID for the embedded PCIe bridge.
    let deviceID: UInt16?
}

// MARK: - TBRegistrySource

/// Anything that can produce a flat list of `TBDeviceSnapshot`s.
/// Two implementations: live IOKit (`LiveIOKitTBSource`) and JSON
/// fixture (`FixtureTBSource`).
protocol TBRegistrySource: Sendable {
    func enumerate() throws -> [TBDeviceSnapshot]
}

// MARK: - LiveIOKitTBSource

/// Production source: walks live IOKit. Matches `IOThunderboltSwitchType2`
/// and reads each switch's TB-specific properties. Note this does NOT
/// visit `IOPCIDevice` directly — the SPEC §18 Phase 7 acceptance
/// mentions "via `IOPCIDevice` filtered to TB domain" as one option,
/// but the `IOThunderboltSwitchType2` class IS the TB-domain filter
/// already, and reading link properties is much more direct from
/// switch entries than from generic PCIe devices.
struct LiveIOKitTBSource: TBRegistrySource {

    let matchingClassName: String

    init(matchingClassName: String = TBDiscoveryConstants.switchClassName) {
        self.matchingClassName = matchingClassName
    }

    func enumerate() throws -> [TBDeviceSnapshot] {
        guard let matching = IOServiceMatching(matchingClassName) else {
            throw IOKitError.matchingDictionaryFailed
        }

        var results: [TBDeviceSnapshot] = []
        withMatchingServices(matching) { iter in
            forEachEntry(in: iter) { entry in
                if let snapshot = Self.makeSnapshot(from: entry) {
                    results.append(snapshot)
                }
            }
        }
        return results
    }

    /// Build a `TBDeviceSnapshot` from one `IOThunderboltSwitchType2`
    /// registry entry. Internal-static so future hot-plug paths
    /// (Phase 7+ TB attach/detach via `IOServiceAddMatchingNotification`)
    /// can reuse the property-read pipeline.
    static func makeSnapshot(from entry: borrowing IOObject) -> TBDeviceSnapshot? {
        let keys = TBDiscoveryConstants.PropertyKey.self
        let path = registryPath(of: entry) ?? "<unknown>"
        return TBDeviceSnapshot(
            registryPath: path,
            routeString:  stringProperty(keys.routeString,    of: entry),
            linkType:     uint32Property(keys.linkType,       of: entry),
            linkSpeed:    uint32Property(keys.linkSpeed,      of: entry),
            linkWidth:    uint32Property(keys.linkWidth,      of: entry),
            vendorName:   stringProperty(keys.vendorName,     of: entry),
            deviceName:   stringProperty(keys.deviceName,     of: entry),
            vendorID:     uint16Property(keys.vendorID,       of: entry),
            deviceID:     uint16Property(keys.deviceID,       of: entry)
        )
    }
}

// MARK: - FixtureTBSource

/// Test source: replays a JSON fixture. Field names mirror the IOKit
/// property strings so a future `ioreg`-to-fixture script needs no
/// translation step.
struct FixtureTBSource: TBRegistrySource {

    let fixtureURL: URL

    init(fixtureURL: URL) {
        self.fixtureURL = fixtureURL
    }

    func enumerate() throws -> [TBDeviceSnapshot] {
        let data = try Data(contentsOf: fixtureURL)
        let envelope = try JSONDecoder().decode(FixtureEnvelope.self, from: data)
        return envelope.devices.map { $0.toSnapshot() }
    }

    private struct FixtureEnvelope: Decodable {
        let schemaVersion: Int
        let captureSource: String?
        let devices: [FixtureDevice]
    }

    private struct FixtureDevice: Decodable {
        let registryPath: String
        let routeString: String?
        let linkType: UInt32?
        let linkSpeed: UInt32?
        let linkWidth: UInt32?
        let vendorName: String?
        let deviceName: String?
        let vendorID: UInt16?
        let deviceID: UInt16?

        enum CodingKeys: String, CodingKey {
            case registryPath
            case routeString = "Route String"
            case linkType    = "IOThunderboltLinkType"
            case linkSpeed   = "IOThunderboltLinkSpeed"
            case linkWidth   = "IOThunderboltLinkWidth"
            case vendorName  = "IOThunderboltVendorName"
            case deviceName  = "IOThunderboltDeviceName"
            case vendorID    = "vendorID"
            case deviceID    = "deviceID"
        }

        func toSnapshot() -> TBDeviceSnapshot {
            TBDeviceSnapshot(
                registryPath: registryPath,
                routeString:  routeString,
                linkType:     linkType,
                linkSpeed:    linkSpeed,
                linkWidth:    linkWidth,
                vendorName:   vendorName,
                deviceName:   deviceName,
                vendorID:     vendorID,
                deviceID:     deviceID
            )
        }
    }
}

// MARK: - ThunderboltWalker

/// Phase-7 entry point for TB discovery. Wraps a `TBRegistrySource`
/// and provides a logged variant that mirrors `USBWalker.walkAndLog`'s
/// per-device os.Logger output (Phase 7 emits to `Log.events.notice`
/// per SPEC §16.1 to stay consistent with USB).
final class ThunderboltWalker: Sendable {

    private let source: any TBRegistrySource

    init(source: any TBRegistrySource = LiveIOKitTBSource()) {
        self.source = source
    }

    /// Perform one walk. Sorted-by-registryPath output for
    /// determinism across runs (matches USBWalker.walk()'s contract).
    func walk() throws -> [TBDeviceSnapshot] {
        let raw = try source.enumerate()
        return raw.sorted { $0.registryPath < $1.registryPath }
    }

    /// Walk + emit per-device summary to `Log.events.notice`. Used
    /// when the discovery layer wants both the data and the unified
    /// log trail.
    func walkAndLog() throws -> [TBDeviceSnapshot] {
        let devices = try walk()
        Log.discovery.info("TB walk found \(devices.count, privacy: .public) device(s)")
        for device in devices {
            let line = String(
                format: "  TB route=%@ name=%@ linkType=%@ linkSpeed=%@",
                device.routeString ?? "?",
                device.deviceName ?? "<unnamed>",
                device.linkType.map { "TB\($0)" } ?? "?",
                device.linkSpeed.map { "\(Double($0) / 10.0) Gbps" } ?? "?"
            )
            Log.events.notice("\(line, privacy: .public)")
        }
        return devices
    }
}

// MARK: - TBDiscoveryConstants

/// IOKit class names + property keys for the TB layer. Same pattern
/// as `USBDiscoveryConstants` per builder.md "no magic numbers" rule.
enum TBDiscoveryConstants {

    /// Modern IOKit class for TB switches (host controllers AND
    /// downstream switches inside chained devices). Type2 is the
    /// macOS 11+ version; older systems used `IOThunderboltSwitch`.
    static let switchClassName = "IOThunderboltSwitchType2"

    /// IOKit class for TB ports. Phase 7 doesn't enumerate ports
    /// directly (we walk switches); declared here so future phases
    /// have one home for the constant.
    static let portClassName = "IOThunderboltPort"

    /// Property keys we read from each switch entry. String-keyed
    /// IOKit properties match the BRIEF.md cheatsheet column.
    enum PropertyKey {
        static let routeString = "Route String"
        static let linkType    = "IOThunderboltLinkType"
        static let linkSpeed   = "IOThunderboltLinkSpeed"
        static let linkWidth   = "IOThunderboltLinkWidth"
        static let vendorName  = "IOThunderboltVendorName"
        static let deviceName  = "IOThunderboltDeviceName"
        static let vendorID    = "vendorID"
        static let deviceID    = "deviceID"
    }

    /// Map an `IOThunderboltLinkType` raw value to a human-readable
    /// protocol name. Used by `PortGraphBuilder` when synthesizing
    /// `LinkSpeed.protocolName` for TB ports.
    static func protocolName(forLinkType raw: UInt32?) -> String {
        switch raw {
        case 1: return "Thunderbolt 1"
        case 2: return "Thunderbolt 2"
        case 3: return "Thunderbolt 3"
        case 4: return "Thunderbolt 4"
        case 5: return "USB4"
        case .none: return "Thunderbolt"
        case .some(let v): return "Thunderbolt (raw=\(v))"
        }
    }
}
