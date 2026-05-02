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
// ThunderboltWalkerTests.swift
//
// Per SPEC.md §18 Phase 7 acceptance: "ThunderboltWalkerTests.swift
// parses fixture and asserts correct nesting." The walker itself is
// flat (Phase 7 design — same as USBWalker); the nesting happens in
// `PortGraphBuilder.nestByRegistryPath` which has its own dedicated
// test cases below.
//
// Live-hardware verification (`STUDIO-DISPLAY-CHAIN` per SPEC §18.0)
// is Reviewer-deferred — Brandon has no Studio Display rig.

import XCTest
@testable import Manifold
import ManifoldKit

final class ThunderboltWalkerTests: XCTestCase {

    private static let fixtureName = "ioreg-studio-display-chain"

    // MARK: - Fixture lookup

    private func fixtureURL() throws -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: Self.fixtureName, withExtension: "json") else {
            throw FixtureLookupError.notFound(name: Self.fixtureName)
        }
        return url
    }

    private enum FixtureLookupError: Error {
        case notFound(name: String)
    }

    private func makeWalker() throws -> ThunderboltWalker {
        let url = try fixtureURL()
        return ThunderboltWalker(source: FixtureTBSource(fixtureURL: url))
    }

    // MARK: - Walks

    /// Headline: the Studio Display chain fixture parses into 3 TB
    /// devices (root controller + display + downstream SSD).
    func test_walk_canonicalChain_producesThreeDevices() throws {
        let walker = try makeWalker()
        let devices = try walker.walk()
        XCTAssertEqual(devices.count, 3)
    }

    /// Output is sorted by registryPath. Pinning the ordering
    /// contract because PortGraphBuilder.nestByRegistryPath relies on
    /// deterministic ordering for parent-detection (tied paths sort
    /// stably).
    func test_walk_outputIsSortedByRegistryPath() throws {
        let walker = try makeWalker()
        let devices = try walker.walk()
        let paths = devices.map { $0.registryPath }
        XCTAssertEqual(paths, paths.sorted())
    }

    /// Per-device field mapping. The Studio Display entry is the
    /// canonical "vendor + name + link" case.
    func test_walk_studioDisplay_hasExpectedFields() throws {
        let walker = try makeWalker()
        let devices = try walker.walk()
        guard let display = devices.first(where: { $0.deviceName == "Studio Display" }) else {
            return XCTFail("Studio Display entry missing from fixture.")
        }
        XCTAssertEqual(display.vendorID, 1452)        // Apple
        XCTAssertEqual(display.deviceID, 4400)
        XCTAssertEqual(display.routeString, "1-0")
        XCTAssertEqual(display.linkType, 4)            // Thunderbolt 4
        XCTAssertEqual(display.linkSpeed, 400)         // 40 Gbps (×10 IOKit encoding)
        XCTAssertEqual(display.linkWidth, 2)
    }

    /// Root TB controller has nil link properties (no upstream
    /// link). Pinning so a future fixture edit that accidentally
    /// adds link values to the root surfaces.
    func test_walk_rootController_hasNilLinkProperties() throws {
        let walker = try makeWalker()
        let devices = try walker.walk()
        guard let root = devices.first(where: { $0.routeString == "0-0" }) else {
            return XCTFail("Root TB controller (route 0-0) missing.")
        }
        XCTAssertNil(root.linkType)
        XCTAssertNil(root.linkSpeed)
        XCTAssertNil(root.linkWidth)
    }

    /// Daisy-chained device behind the display has its own link
    /// properties + a deeper registry path.
    func test_walk_daisyChainedSSD_hasDeeperPathThanDisplay() throws {
        let walker = try makeWalker()
        let devices = try walker.walk()
        guard let display = devices.first(where: { $0.deviceName == "Studio Display" }),
              let ssd = devices.first(where: { $0.deviceName == "Envoy Pro FX" }) else {
            return XCTFail("Display or downstream SSD missing from fixture.")
        }
        XCTAssertTrue(
            ssd.registryPath.hasPrefix(display.registryPath + "/"),
            "SSD registry path should be a strict descendant of the display's path (daisy chain)."
        )
        XCTAssertEqual(ssd.linkType, 3)               // TB3 — older SSD on a TB4 chain
        XCTAssertEqual(ssd.routeString, "1-2")
    }

    // MARK: - protocolName lookup

    func test_protocolName_mapsKnownLinkTypes() {
        XCTAssertEqual(TBDiscoveryConstants.protocolName(forLinkType: 1), "Thunderbolt 1")
        XCTAssertEqual(TBDiscoveryConstants.protocolName(forLinkType: 3), "Thunderbolt 3")
        XCTAssertEqual(TBDiscoveryConstants.protocolName(forLinkType: 4), "Thunderbolt 4")
        XCTAssertEqual(TBDiscoveryConstants.protocolName(forLinkType: 5), "USB4")
        XCTAssertEqual(TBDiscoveryConstants.protocolName(forLinkType: nil), "Thunderbolt")
        XCTAssertTrue(TBDiscoveryConstants.protocolName(forLinkType: 99).contains("raw=99"))
    }
}

// MARK: - PortGraphBuilder.nestByRegistryPath nesting tests

/// Phase 7 introduces `nestByRegistryPath` to reconstruct hub / TB
/// chain hierarchy from a flat list of ports. These tests pin the
/// algorithm: parent detection by longest prefix match, leaf
/// preservation, multi-level nesting.
final class PortGraphNestingTests: XCTestCase {

    /// Three ports where path #2 prefixes #3, and path #1 is
    /// independent: nesting produces 2 roots (#1 and #2), and #3
    /// becomes a child of #2.
    func test_nestByRegistryPath_buildsExpectedHierarchy() {
        let p1 = makePort(path: "/A")
        let p2 = makePort(path: "/B")
        let p3 = makePort(path: "/B/sub")
        let nested = PortGraphBuilder.nestByRegistryPath([p1, p2, p3])

        XCTAssertEqual(nested.count, 2, "Two roots: /A and /B.")
        let pa = nested.first { $0.id == p1.id }
        let pb = nested.first { $0.id == p2.id }
        XCTAssertNotNil(pa)
        XCTAssertEqual(pa?.children.count, 0)
        XCTAssertEqual(pb?.children.count, 1)
        XCTAssertEqual(pb?.children.first?.id, p3.id)
    }

    /// Three-deep daisy chain: A → A/B → A/B/C nests to one root
    /// with one child with one grandchild.
    func test_nestByRegistryPath_threeDeepChain() {
        let a = makePort(path: "/host/dock")
        let b = makePort(path: "/host/dock/display")
        let c = makePort(path: "/host/dock/display/ssd")
        let nested = PortGraphBuilder.nestByRegistryPath([a, b, c])

        XCTAssertEqual(nested.count, 1, "One root: /host/dock.")
        let root = nested[0]
        XCTAssertEqual(root.id, a.id)
        XCTAssertEqual(root.children.count, 1)
        XCTAssertEqual(root.children[0].id, b.id)
        XCTAssertEqual(root.children[0].children.count, 1)
        XCTAssertEqual(root.children[0].children[0].id, c.id)
    }

    /// Sibling-chain: two ports both prefixed by a parent (a USB
    /// hub with two devices).
    func test_nestByRegistryPath_siblingsUnderParent() {
        let parent = makePort(path: "/hub")
        let s1 = makePort(path: "/hub/device-A")
        let s2 = makePort(path: "/hub/device-B")
        let nested = PortGraphBuilder.nestByRegistryPath([s1, parent, s2])

        XCTAssertEqual(nested.count, 1)
        let root = nested[0]
        XCTAssertEqual(root.id, parent.id)
        XCTAssertEqual(root.children.count, 2)
        let childIDs = Set(root.children.map(\.id))
        XCTAssertEqual(childIDs, [s1.id, s2.id])
    }

    /// Empty input → empty output (no crashes on edge cases).
    func test_nestByRegistryPath_emptyInput_returnsEmpty() {
        XCTAssertTrue(PortGraphBuilder.nestByRegistryPath([]).isEmpty)
    }

    /// Single port → returned as the only root.
    func test_nestByRegistryPath_singlePort_returnsAsRoot() {
        let only = makePort(path: "/lonely")
        let nested = PortGraphBuilder.nestByRegistryPath([only])
        XCTAssertEqual(nested.count, 1)
        XCTAssertEqual(nested[0].id, only.id)
    }

    /// Nest the canonical Phase-7 fixture's three TB devices and
    /// verify the host → display → SSD shape. End-to-end check that
    /// fixture + walker + nesting compose correctly.
    func test_nestByRegistryPath_studioDisplayChain_matchesPhysicalShape() throws {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: "ioreg-studio-display-chain", withExtension: "json") else {
            return XCTFail("Phase 7 TB fixture missing.")
        }
        let walker = ThunderboltWalker(source: FixtureTBSource(fixtureURL: url))
        let snapshots = try walker.walk()

        // Lift to ports.
        let ports = snapshots.enumerated().map { idx, snap in
            PortGraphBuilder.makePort(fromTB: snap, position: idx + 1, timestamp: Date(timeIntervalSince1970: 0))
        }
        let nested = PortGraphBuilder.nestByRegistryPath(ports)

        XCTAssertEqual(nested.count, 1, "One TB root (the host's TB controller).")
        let root = nested[0]
        XCTAssertEqual(root.children.count, 1, "Host TB controller has one daisy-chained device (the display).")
        let display = root.children[0]
        XCTAssertEqual(display.connectedDevice?.name, "Studio Display")
        XCTAssertEqual(display.children.count, 1, "Display has one downstream device (the SSD).")
        let ssd = display.children[0]
        XCTAssertEqual(ssd.connectedDevice?.name, "Envoy Pro FX")
        XCTAssertTrue(ssd.children.isEmpty, "SSD is a leaf.")
    }

    // MARK: - Helpers

    private func makePort(path: String) -> ManifoldKit.Port {
        ManifoldKit.Port(
            id: PortID(path),
            position: 1,
            kind: .thunderbolt,
            parentID: nil,
            connectedDevice: makeDevice(named: "device-at-\(path)"),
            negotiated: nil,
            powerDraw: nil,
            children: []
        )
    }

    private func makeDevice(named name: String) -> Device {
        Device(
            id: DeviceID("0000:0000:\(name)"),
            name: name,
            kind: .other,
            vendorID: 0,
            productID: 0,
            serial: name,
            usbVersion: nil,
            displayInfo: nil,
            firstSeen: Date(timeIntervalSince1970: 0),
            lastSeen: Date(timeIntervalSince1970: 0)
        )
    }
}
