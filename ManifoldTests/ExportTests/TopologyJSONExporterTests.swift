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
// ─────────────────────────────────────────────────────────────────────
// TopologyJSONExporterTests.swift
//
// Pin SPEC §18 Phase 11 #3: top-level `schemaVersion: 1`. Plus pin
// the three scope projections (full / host / device) so a future
// trim refactor doesn't drop the wrong subtree.

import XCTest
@testable import Manifold
import ManifoldKit

final class TopologyJSONExporterTests: XCTestCase {

    // MARK: - Schema version

    /// Top-level JSON object always has `schemaVersion: 1`. Pinned
    /// because the SPEC §18 Phase 11 #3 wording is explicit.
    func test_schemaVersion_isAlways1() throws {
        let snapshot = TopologyJSONExporter.makeSnapshot(hosts: [makeHost()], scope: .fullTopology)
        XCTAssertEqual(snapshot?.schemaVersion, 1)

        guard let data = TopologyJSONExporter.encode(hosts: [makeHost()], scope: .fullTopology) else {
            XCTFail("encode returned nil")
            return
        }
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(parsed?["schemaVersion"] as? Int, 1)
    }

    // MARK: - Scope: full

    /// Full scope returns every host unchanged.
    func test_scope_full_returnsEveryHostUnchanged() {
        let hosts = [makeHost(id: "h1"), makeHost(id: "h2")]
        let snapshot = TopologyJSONExporter.makeSnapshot(hosts: hosts, scope: .fullTopology)
        XCTAssertEqual(snapshot?.hosts.count, 2)
        XCTAssertEqual(snapshot?.scope, "full")
    }

    // MARK: - Scope: host

    /// Single-host scope returns only the matching host.
    func test_scope_singleHost_returnsOnlyThatHost() {
        let hosts = [makeHost(id: "h1"), makeHost(id: "h2")]
        let snapshot = TopologyJSONExporter.makeSnapshot(hosts: hosts, scope: .host(HostID("h2")))
        XCTAssertEqual(snapshot?.hosts.count, 1)
        XCTAssertEqual(snapshot?.hosts.first?.id.rawValue, "h2")
        XCTAssertEqual(snapshot?.scope, "host:h2")
    }

    /// Single-host scope with an unknown HostID → nil snapshot
    /// (caller renders an empty-selection alert).
    func test_scope_singleHost_unknownID_returnsNil() {
        let snapshot = TopologyJSONExporter.makeSnapshot(hosts: [makeHost()], scope: .host(HostID("nonexistent")))
        XCTAssertNil(snapshot)
    }

    // MARK: - Scope: device

    /// Device-scope keeps the path from host root to the matching
    /// port + drops sibling subtrees.
    func test_scope_device_trimsToContainingHostAndSubtree() {
        let targetID = DeviceID("VID:PID:TARGET")
        let target = makeDevice(id: targetID, name: "Target")
        let sibling = makeDevice(id: DeviceID("VID:PID:SIBLING"), name: "Sibling")
        let host = ManifoldKit.Host(
            id: HostID("h1"),
            name: "Host",
            model: "M",
            ports: [
                makePort(id: "/host/port-1", device: target),
                makePort(id: "/host/port-2", device: sibling)
            ]
        )
        let snapshot = TopologyJSONExporter.makeSnapshot(hosts: [host], scope: .device(targetID))
        XCTAssertEqual(snapshot?.hosts.count, 1)
        XCTAssertEqual(snapshot?.hosts.first?.ports.count, 1, "Sibling subtree should be trimmed")
        XCTAssertEqual(snapshot?.hosts.first?.ports.first?.connectedDevice?.id, targetID)
    }

    /// Device-scope with an unknown DeviceID returns nil — no host
    /// has a matching subtree.
    func test_scope_device_unknownID_returnsNil() {
        let snapshot = TopologyJSONExporter.makeSnapshot(hosts: [makeHost()], scope: .device(DeviceID("nonexistent")))
        XCTAssertNil(snapshot)
    }

    // MARK: - Pretty-printed JSON

    /// Encoded JSON is pretty-printed (contains newlines + indentation),
    /// not minified. SPEC doesn't mandate this but exports are
    /// human-read; pretty stays consistent with Phase 12's intent.
    func test_encode_jsonIsPrettyPrinted() {
        let data = TopologyJSONExporter.encode(hosts: [makeHost()], scope: .fullTopology)
        let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\n"))
        XCTAssertTrue(text.contains("  \"schemaVersion"))  // indented
    }

    // MARK: - Helpers

    private func makeHost(id: String = "test-host") -> ManifoldKit.Host {
        ManifoldKit.Host(
            id: HostID(id),
            name: "Test Host",
            model: "Mac15,9",
            ports: [makePort(id: "/host/port-1")]
        )
    }

    private func makePort(id: String, device: Device? = nil) -> ManifoldKit.Port {
        ManifoldKit.Port(
            id: PortID(id),
            position: 1,
            kind: .usbC,
            parentID: nil,
            connectedDevice: device,
            negotiated: nil,
            powerDraw: nil,
            children: []
        )
    }

    private func makeDevice(id: DeviceID, name: String) -> Device {
        Device(
            id: id,
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
