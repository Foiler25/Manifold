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
// SnapshotPublisherTests.swift
//
// Pin SnapshotPublisher's projection contract: total power, device
// count, top-N selection, sample-history join. The disk write +
// WidgetCenter reload path is covered by SnapshotV1RoundTripTests
// (ManifoldKit) and the Brandon hand-off; this file focuses on
// the pure projection.

import XCTest
@testable import Manifold
import ManifoldKit

@MainActor
final class SnapshotPublisherTests: XCTestCase {

    // MARK: - Total power + device count

    /// Sum across every port; count includes every connected device.
    func test_makeSnapshot_sumsPowerAndCountsDevices() {
        let graph = PortGraph()
        graph.replace(hosts: [
            host(ports: [
                port(id: "/p1", device: device(name: "A"), powerDraw: Watts(1.5)),
                port(id: "/p2", device: device(name: "B"), powerDraw: Watts(0.5))
            ])
        ])

        let snapshot = SnapshotPublisher.makeSnapshot(from: graph, lastEventAt: nil)
        XCTAssertEqual(snapshot.totalPowerDraw.value, 2.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.connectedDeviceCount, 2)
        XCTAssertEqual(snapshot.activeDiagnosticCount, 0)
    }

    /// Nested children contribute to the totals.
    func test_makeSnapshot_recursesIntoHubChildren() {
        let graph = PortGraph()
        let child = port(id: "/hub/child", device: device(name: "Child"), powerDraw: Watts(0.5))
        let hub = port(id: "/hub", device: device(name: "Hub"), powerDraw: Watts(0.1), children: [child])
        graph.replace(hosts: [host(ports: [hub])])

        let snapshot = SnapshotPublisher.makeSnapshot(from: graph, lastEventAt: nil)
        XCTAssertEqual(snapshot.connectedDeviceCount, 2, "Hub + child both count")
        XCTAssertEqual(snapshot.totalPowerDraw.value, 0.6, accuracy: 0.001, "Hub + child watts both sum")
    }

    // MARK: - Top-N selection

    /// `topDevicesByPower` is capped at 4 and sorted descending.
    func test_makeSnapshot_topDevicesAreCappedAtFourAndSorted() {
        let graph = PortGraph()
        let ports = (0..<6).map { i in
            port(
                id: "/p\(i)",
                device: device(name: "Device\(i)"),
                powerDraw: Watts(Double(i + 1))
            )
        }
        graph.replace(hosts: [host(ports: ports)])

        let snapshot = SnapshotPublisher.makeSnapshot(from: graph, lastEventAt: nil)
        XCTAssertEqual(snapshot.topDevicesByPower.count, 4, "Cap at SPEC §12.1 max of 4")
        let watts = snapshot.topDevicesByPower.map(\.powerDraw.value)
        XCTAssertEqual(watts, [6, 5, 4, 3], "Descending order; top 4 of 6 ports")
    }

    /// Empty graph → snapshot with zero/empty fields. Cold launch
    /// must not crash the projection.
    func test_makeSnapshot_emptyGraph_producesZeroFields() {
        let graph = PortGraph()
        let snapshot = SnapshotPublisher.makeSnapshot(from: graph, lastEventAt: nil)
        XCTAssertEqual(snapshot.totalPowerDraw.value, 0)
        XCTAssertEqual(snapshot.connectedDeviceCount, 0)
        XCTAssertTrue(snapshot.topDevicesByPower.isEmpty)
        XCTAssertEqual(snapshot.activeDiagnosticCount, 0)
        XCTAssertNil(snapshot.lastEventAt)
    }

    // MARK: - lastEventAt + diagnostics passthrough

    /// `lastEventAt` is threaded through unchanged.
    func test_makeSnapshot_lastEventAtPropagates() {
        let graph = PortGraph()
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = SnapshotPublisher.makeSnapshot(from: graph, lastEventAt: ts)
        XCTAssertEqual(snapshot.lastEventAt, ts)
    }

    /// `activeDiagnosticCount` reflects PortGraph.diagnostics.count.
    func test_makeSnapshot_activeDiagnosticsCountReflectsGraph() {
        let graph = PortGraph()
        let portID = PortID("/p")
        graph.replace(hosts: [host(ports: [port(id: "/p")])], diagnostics: [
            Diagnostic(target: portID, severity: .warning, ruleIdentifier: "x", title: "x", detail: "x"),
            Diagnostic(target: portID, severity: .critical, ruleIdentifier: "y", title: "y", detail: "y")
        ])
        let snapshot = SnapshotPublisher.makeSnapshot(from: graph, lastEventAt: nil)
        XCTAssertEqual(snapshot.activeDiagnosticCount, 2)
    }

    // MARK: - Helpers

    private func host(ports: [ManifoldKit.Port]) -> ManifoldKit.Host {
        ManifoldKit.Host(id: HostID("h"), name: "Test", model: "Test", ports: ports)
    }

    private func port(
        id: String,
        device: Device? = nil,
        powerDraw: Watts? = nil,
        children: [ManifoldKit.Port] = []
    ) -> ManifoldKit.Port {
        ManifoldKit.Port(
            id: PortID(id),
            position: 1,
            kind: .usbC,
            parentID: nil,
            connectedDevice: device,
            negotiated: nil,
            powerDraw: powerDraw,
            children: children
        )
    }

    private func device(name: String) -> Device {
        Device(
            id: DeviceID.make(vendorID: 0x1234, productID: 0x5678, serial: name, registryPath: "/test/\(name)"),
            name: name,
            kind: .other,
            vendorID: 0x1234,
            productID: 0x5678,
            serial: name,
            usbVersion: .usb3_0,
            displayInfo: nil,
            firstSeen: Date(timeIntervalSince1970: 0),
            lastSeen: Date(timeIntervalSince1970: 0)
        )
    }
}
