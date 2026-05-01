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
// PortGraphTests.swift
//
// Per SPEC.md §18 Phase 2 final bullet: "PortGraph.apply(.fullRefresh)
// swap test passes with no SwiftUI animation thrash (visual check)."
// The visual check is the Reviewer's job; these tests cover the model
// side: that fullRefresh advances `lastUpdated`, that replace() swaps
// the host list atomically, and that totalDeviceCount reflects what's
// actually in the graph.

import XCTest
@testable import Manifold
import ManifoldKit

@MainActor
final class PortGraphTests: XCTestCase {

    /// Newly-constructed PortGraph is empty and timestamped at init.
    func test_initialState_isEmpty() {
        let graph = PortGraph()
        XCTAssertTrue(graph.hosts.isEmpty)
        XCTAssertTrue(graph.diagnostics.isEmpty)
        XCTAssertEqual(graph.totalDeviceCount, 0)
    }

    /// `replace(hosts:diagnostics:)` swaps both arrays atomically and
    /// bumps `lastUpdated`. The bump matters even for identical input
    /// because the popover's "last refresh" affordance reads it.
    func test_replace_swapsContentAndAdvancesLastUpdated() throws {
        let graph = PortGraph()
        let initial = graph.lastUpdated

        // tiny sleep so the new timestamp is actually different
        Thread.sleep(forTimeInterval: 0.01)

        graph.replace(hosts: [makeHostWithOneDevice()], diagnostics: [])
        XCTAssertEqual(graph.hosts.count, 1)
        XCTAssertEqual(graph.totalDeviceCount, 1)
        XCTAssertGreaterThan(graph.lastUpdated, initial)
    }

    /// `apply(.fullRefresh)` bumps `lastUpdated`. This is the SPEC §18
    /// Phase 2 acceptance test (the visual side is the Reviewer's
    /// responsibility — what we assert here is that the model
    /// signals "refreshed").
    func test_apply_fullRefresh_advancesLastUpdated() {
        let graph = PortGraph()
        let initial = graph.lastUpdated

        Thread.sleep(forTimeInterval: 0.01)

        graph.apply(.fullRefresh)
        XCTAssertGreaterThan(graph.lastUpdated, initial)
    }

    /// `apply(.diagnostic(_:))` appends to the diagnostics list and
    /// bumps `lastUpdated`. Phase 8 hooks the engine to this path;
    /// pinning behaviour now so Phase 8 doesn't have to relitigate.
    func test_apply_diagnostic_appendsAndAdvancesLastUpdated() {
        let graph = PortGraph()
        let initial = graph.lastUpdated
        Thread.sleep(forTimeInterval: 0.01)

        let diag = Diagnostic(
            target: PortID("port-1"),
            severity: .warning,
            ruleIdentifier: "test-rule",
            title: "Test diagnostic",
            detail: "Test detail",
            triggeredAt: Date(timeIntervalSince1970: 0)
        )
        graph.apply(.diagnostic(diag))

        XCTAssertEqual(graph.diagnostics.count, 1)
        XCTAssertEqual(graph.diagnostics.first?.id, diag.id)
        XCTAssertGreaterThan(graph.lastUpdated, initial)
    }

    /// `.attached`, `.detached`, `.telemetry` are no-ops in Phase 2 by
    /// design (Phase 3 will implement them). Pinning the no-op so
    /// Phase 3 explicitly removes this test when the path is wired up.
    func test_apply_phase2NoOpEvents_doNotMutateGraph() {
        let graph = PortGraph()
        graph.replace(hosts: [makeHostWithOneDevice()])
        let snapshotBefore = (
            hosts: graph.hosts,
            diagnostics: graph.diagnostics
        )

        let bogusDevice = Device(
            id: DeviceID("0000:0000:bogus"),
            name: "Bogus",
            kind: .other,
            vendorID: 0,
            productID: 0,
            serial: nil,
            usbVersion: nil,
            displayInfo: nil,
            firstSeen: Date(),
            lastSeen: Date()
        )
        graph.apply(.attached(bogusDevice, at: PortID("/some/port")))
        graph.apply(.detached(deviceID: DeviceID("x"), from: PortID("/some/port")))
        graph.apply(.telemetry(PortID("/some/port"),
                               TelemetrySample(timestamp: Date(), watts: nil, bitrate: nil)))

        XCTAssertEqual(graph.hosts, snapshotBefore.hosts)
        XCTAssertEqual(graph.diagnostics, snapshotBefore.diagnostics)
    }

    /// `totalDeviceCount` reflects connected devices across hosts and
    /// (eventually) descendant ports. Pin the recursive helper now so
    /// Phase 7's hub trees automatically register correctly.
    func test_totalDeviceCount_reflectsAllConnectedDevices() {
        let graph = PortGraph()

        let parentPort = ManifoldKit.Port(
            id: PortID("/parent"),
            position: 1,
            kind: .usbC,
            parentID: nil,
            connectedDevice: makeStubDevice("parent-device"),
            negotiated: nil,
            powerDraw: nil,
            children: [
                ManifoldKit.Port(
                    id: PortID("/parent/child"),
                    position: 1,
                    kind: .usbA,
                    parentID: PortID("/parent"),
                    connectedDevice: makeStubDevice("child-device"),
                    negotiated: nil,
                    powerDraw: nil,
                    children: []
                )
            ]
        )
        let host = ManifoldKit.Host(
            id: HostID("test"),
            name: "test",
            model: "test",
            ports: [parentPort]
        )
        graph.replace(hosts: [host])

        XCTAssertEqual(graph.totalDeviceCount, 2, "parent + child each carry a Device")
    }

    // MARK: - Test helpers

    private func makeHostWithOneDevice() -> ManifoldKit.Host {
        let port = ManifoldKit.Port(
            id: PortID("/test"),
            position: 1,
            kind: .usbC,
            parentID: nil,
            connectedDevice: makeStubDevice("only-device"),
            negotiated: nil,
            powerDraw: nil,
            children: []
        )
        return ManifoldKit.Host(
            id: HostID("test-host"),
            name: "test",
            model: "test",
            ports: [port]
        )
    }

    private func makeStubDevice(_ name: String) -> Device {
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
