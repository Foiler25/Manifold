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
// PortGraphMutationTests.swift
//
// Per SPEC.md §18 Phase 3 rev-4 bullet #9: pin every case of the
// §4.6.1 mutation pattern. For each PortEvent case, two scenarios:
//
//   1. Found-port: the surgical mutation lands as specified.
//   2. Not-found-port: the not-found behavior matches §4.6.1's table
//      (.attached → set needsFullRefresh; .telemetry/.detached → drop
//      with debug log; .diagnostic always appends).
//
// PortGraphTests in Phase 2 covered the high-level apply contract;
// this file pins the §4.6.1 algorithmic detail so a future "small
// refactor" of mutatePort can't silently break replug stability.

import XCTest
@testable import Manifold
import ManifoldKit

@MainActor
final class PortGraphMutationTests: XCTestCase {

    // MARK: - .telemetry

    /// Found-port .telemetry updates powerDraw + negotiated.bitrate
    /// from the sample AND appends to the per-port history buffer
    /// (Phase 5 closure of the Phase-3 partial implementation).
    func test_telemetry_foundPort_updatesPowerAndBitrate() {
        let graph = PortGraph()
        let portID = PortID("/host/port-1")
        graph.replace(hosts: [makeHost(portIDs: [portID], withInitialDevice: true)])

        let initialUpdated = graph.lastUpdated
        Thread.sleep(forTimeInterval: 0.01)

        graph.apply(.telemetry(
            portID,
            TelemetrySample(
                timestamp: Date(timeIntervalSince1970: 1),
                watts: Watts(2.5),
                bitrate: Bitrate(bitsPerSecond: 5_000_000_000)
            )
        ))

        let port = graph.hosts[0].ports[0]
        XCTAssertEqual(port.powerDraw, Watts(2.5))
        XCTAssertEqual(port.negotiated?.bitrate.bitsPerSecond, 5_000_000_000)
        XCTAssertEqual(port.negotiated?.protocolName, "USB 2.0", "Existing protocolName preserved.")
        XCTAssertGreaterThan(graph.lastUpdated, initialUpdated)
    }

    /// Not-found .telemetry drops silently. `lastUpdated` is NOT bumped
    /// (per §4.6.1 — telemetry for an unknown port is treated as a
    /// stale tick, not a "graph changed" signal).
    /// Importantly, no .fullRefresh request is set.
    func test_telemetry_notFoundPort_dropsWithoutBumpingLastUpdated() {
        let graph = PortGraph()
        graph.replace(hosts: [makeHost(portIDs: [PortID("/known")], withInitialDevice: true)])
        let initialUpdated = graph.lastUpdated

        graph.apply(.telemetry(
            PortID("/unknown"),
            TelemetrySample(timestamp: Date(), watts: Watts(1), bitrate: nil)
        ))

        XCTAssertEqual(graph.lastUpdated, initialUpdated, "Not-found telemetry must not bump lastUpdated.")
        XCTAssertFalse(graph.needsFullRefresh, "Not-found telemetry must NOT request full refresh.")
    }

    /// Phase 5: telemetry history is appended on every found-port
    /// .telemetry. The per-port `TelemetryBuffer` accumulates samples
    /// up to capacity 60.
    func test_telemetry_foundPort_appendsToHistory() {
        let graph = PortGraph()
        let portID = PortID("/host/port-1")
        graph.replace(hosts: [makeHost(portIDs: [portID], withInitialDevice: true)])

        for i in 0..<5 {
            graph.apply(.telemetry(
                portID,
                TelemetrySample(
                    timestamp: Date(timeIntervalSince1970: Double(i)),
                    watts: Watts(Double(i) * 0.1),
                    bitrate: nil
                )
            ))
        }

        let history = graph.history(forPortID: portID)
        XCTAssertNotNil(history)
        XCTAssertEqual(history?.samples.count, 5)
        XCTAssertEqual(history?.latest?.watts?.value ?? 0, 0.4, accuracy: 0.001)
    }

    /// Telemetry history caps at 60 samples per SPEC §8 (the buffer's
    /// default capacity). Pinning so a future buffer-cap regression
    /// surfaces in CI.
    func test_telemetry_history_capsAtBufferCapacity() {
        let graph = PortGraph()
        let portID = PortID("/host/port-cap")
        graph.replace(hosts: [makeHost(portIDs: [portID], withInitialDevice: true)])

        for i in 0..<100 {
            graph.apply(.telemetry(
                portID,
                TelemetrySample(timestamp: Date(timeIntervalSince1970: Double(i)), watts: Watts(0), bitrate: nil)
            ))
        }

        XCTAssertEqual(graph.history(forPortID: portID)?.samples.count, 60)
    }

    /// `.detached` clears history per §4.6.1. Pinning so the
    /// "history goes away when the device unplugs" contract is
    /// regression-protected.
    func test_detached_clearsHistory() {
        let graph = PortGraph()
        let portID = PortID("/host/port-1")
        graph.replace(hosts: [makeHost(portIDs: [portID], withInitialDevice: true)])

        graph.apply(.telemetry(
            portID,
            TelemetrySample(timestamp: Date(), watts: Watts(1.0), bitrate: nil)
        ))
        XCTAssertNotNil(graph.history(forPortID: portID))

        graph.apply(.detached(deviceID: DeviceID("ignored"), from: portID))
        XCTAssertNil(graph.history(forPortID: portID), "Detach clears the per-port history buffer.")
    }

    /// `replace(hosts:)` prunes telemetry history for ports that no
    /// longer exist in the new graph. Otherwise history would grow
    /// unbounded across replug churn.
    func test_replace_prunesHistoryForVanishedPorts() {
        let graph = PortGraph()
        let portA = PortID("/a")
        let portB = PortID("/b")
        graph.replace(hosts: [makeHost(portIDs: [portA, portB], withInitialDevice: true)])

        graph.apply(.telemetry(portA, TelemetrySample(timestamp: Date(), watts: Watts(1.0), bitrate: nil)))
        graph.apply(.telemetry(portB, TelemetrySample(timestamp: Date(), watts: Watts(2.0), bitrate: nil)))
        XCTAssertNotNil(graph.history(forPortID: portA))
        XCTAssertNotNil(graph.history(forPortID: portB))

        // New graph: portA is gone. portB stays.
        graph.replace(hosts: [makeHost(portIDs: [portB], withInitialDevice: true)])

        XCTAssertNil(graph.history(forPortID: portA), "Vanished port's history pruned.")
        XCTAssertNotNil(graph.history(forPortID: portB), "Surviving port's history preserved.")
    }

    // MARK: - .attached

    /// Found-port .attached replaces connectedDevice; clears negotiated
    /// + powerDraw (per §4.6.1 — next telemetry tick will fill them).
    /// children stays — a hub announces its own children separately.
    ///
    /// Phase 20 update: `.attached` now ALWAYS sets `needsFullRefresh`,
    /// even on the surgical "found" path. The chassis snapshot in
    /// `host.physicalPorts` lives outside `mutatePort`'s reach and
    /// only `rebuildGraph` refreshes it — without the rebuild a
    /// chassis port whose state just flipped `.empty → .dataDevice`
    /// would keep rendering as "Port N — Empty" alongside the new
    /// active row.
    func test_attached_foundPort_replacesDeviceClearsLinkAndPower() {
        let graph = PortGraph()
        let portID = PortID("/host/port-1")
        graph.replace(hosts: [makeHost(portIDs: [portID], withInitialDevice: true)])

        let newDevice = makeDevice(name: "New device")
        graph.apply(.attached(newDevice, at: portID))

        let port = graph.hosts[0].ports[0]
        XCTAssertEqual(port.connectedDevice, newDevice)
        XCTAssertNil(port.negotiated, "Negotiated cleared per §4.6.1.")
        XCTAssertNil(port.powerDraw, "Power cleared per §4.6.1.")
        XCTAssertTrue(graph.needsFullRefresh, "Phase 20: every .attached triggers a chassis-state refresh.")
    }

    /// Not-found .attached sets `needsFullRefresh` per §4.6.1 ("emit
    /// .fullRefresh instead of inventing a port"). bumps lastUpdated
    /// because the graph state DID change (a refresh is now pending).
    func test_attached_notFoundPort_setsNeedsFullRefresh() {
        let graph = PortGraph()
        graph.replace(hosts: [makeHost(portIDs: [PortID("/known")], withInitialDevice: true)])

        graph.apply(.attached(makeDevice(name: "Stranger"), at: PortID("/unknown")))

        XCTAssertTrue(graph.needsFullRefresh, "Not-found .attached must request full refresh.")
    }

    /// `acknowledgeRefreshRequest()` clears the flag so the consumer
    /// doesn't re-trigger walks for a single event.
    func test_acknowledgeRefreshRequest_clearsFlag() {
        let graph = PortGraph()
        graph.replace(hosts: [makeHost(portIDs: [PortID("/known")], withInitialDevice: true)])
        graph.apply(.attached(makeDevice(name: "Stranger"), at: PortID("/unknown")))
        XCTAssertTrue(graph.needsFullRefresh)

        graph.acknowledgeRefreshRequest()
        XCTAssertFalse(graph.needsFullRefresh)
    }

    // MARK: - .detached

    /// Found-port `.detached` removes the port from `host.ports`
    /// entirely (and any downstream children with it — "a hub being
    /// removed kills its tree"). Phase 20 evolution from the
    /// original "preserve as empty" path: the empty-row UX now
    /// comes from `host.physicalPorts` via
    /// `displayableRootPorts(for:)`, so the active-port array only
    /// tracks ports with currently connected devices. `removePort`
    /// is the surgical step; `needsFullRefresh = true` triggers the
    /// follow-up rebuild that refreshes chassis state.
    func test_detached_foundPort_removesPortAndChildren() {
        let graph = PortGraph()
        let portID = PortID("/host/port-1")
        let hostWithChild = makeHostWithChildPort(parentID: portID)
        graph.replace(hosts: [hostWithChild])

        XCTAssertEqual(graph.hosts[0].ports[0].children.count, 1, "Sanity: parent has a child to begin with.")

        graph.apply(.detached(deviceID: DeviceID("ignored"), from: portID))

        XCTAssertTrue(
            graph.hosts[0].ports.allSatisfy { $0.id != portID },
            "Detached port is removed from host.ports entirely (Phase 20)."
        )
        XCTAssertTrue(graph.needsFullRefresh, "Phase 20: detach triggers a chassis-state refresh.")
    }

    /// Not-found .detached drops silently. lastUpdated NOT bumped.
    /// No .fullRefresh request — the device is already gone, no point
    /// in re-walking.
    func test_detached_notFoundPort_dropsWithoutBumpingLastUpdated() {
        let graph = PortGraph()
        graph.replace(hosts: [makeHost(portIDs: [PortID("/known")], withInitialDevice: true)])
        let initialUpdated = graph.lastUpdated

        graph.apply(.detached(deviceID: DeviceID("ignored"), from: PortID("/unknown")))

        XCTAssertEqual(graph.lastUpdated, initialUpdated)
        XCTAssertFalse(graph.needsFullRefresh)
    }

    // MARK: - .diagnostic dedupe

    /// Two .diagnostic events with the same (target, ruleIdentifier)
    /// pair → only the latest is kept (latest wins per §4.6.1).
    func test_diagnostic_sameTargetAndRule_replacesExisting() {
        let graph = PortGraph()
        let target = PortID("/host/port-1")

        let first = Diagnostic(
            id: UUID(),
            target: target,
            severity: .warning,
            ruleIdentifier: "running-at-usb-2",
            title: "Running @ USB 2.0",
            detail: "First",
            triggeredAt: Date(timeIntervalSince1970: 0)
        )
        let second = Diagnostic(
            id: UUID(),
            target: target,
            severity: .critical,
            ruleIdentifier: "running-at-usb-2",
            title: "Running @ USB 2.0",
            detail: "Second (latest)",
            triggeredAt: Date(timeIntervalSince1970: 1)
        )

        graph.apply(.diagnostic(first))
        graph.apply(.diagnostic(second))

        XCTAssertEqual(graph.diagnostics.count, 1, "Dedupe by (target, ruleIdentifier).")
        XCTAssertEqual(graph.diagnostics[0].detail, "Second (latest)")
        XCTAssertEqual(graph.diagnostics[0].severity, .critical)
    }

    /// Different (target, ruleIdentifier) keys → both kept.
    func test_diagnostic_differentKeys_bothAppended() {
        let graph = PortGraph()
        graph.apply(.diagnostic(makeDiagnostic(target: "/a", rule: "rule-1")))
        graph.apply(.diagnostic(makeDiagnostic(target: "/a", rule: "rule-2")))
        graph.apply(.diagnostic(makeDiagnostic(target: "/b", rule: "rule-1")))
        XCTAssertEqual(graph.diagnostics.count, 3)
    }

    // MARK: - Recursive mutatePort traversal

    /// `mutatePort` walks into `children`. A child-port .attached
    /// updates the child without disturbing the parent's port slot.
    /// Confirms the COW path rebuilds the parent containing the
    /// mutated child.
    ///
    /// Phase 20 update: every `.attached` raises `needsFullRefresh`
    /// (chassis state refresh). The surgical mutation still happens
    /// — that's what this test verifies — and the refresh just runs
    /// afterward to keep `host.physicalPorts` consistent.
    func test_mutatePort_recursesIntoChildren() {
        let graph = PortGraph()
        let parentID = PortID("/host/parent")
        let childID = PortID("/host/parent/child")
        graph.replace(hosts: [makeHostWithChildPort(parentID: parentID, childID: childID)])

        let newDevice = makeDevice(name: "New child device")
        graph.apply(.attached(newDevice, at: childID))

        let parent = graph.hosts[0].ports[0]
        XCTAssertEqual(parent.id, parentID, "Parent untouched.")
        XCTAssertEqual(parent.children[0].id, childID)
        XCTAssertEqual(parent.children[0].connectedDevice, newDevice, "Child device replaced.")
        XCTAssertTrue(graph.needsFullRefresh, "Phase 20: every .attached triggers a chassis-state refresh.")
    }

    // MARK: - Helpers

    private func makeHost(portIDs: [PortID], withInitialDevice: Bool) -> ManifoldKit.Host {
        let ports = portIDs.enumerated().map { idx, id -> ManifoldKit.Port in
            ManifoldKit.Port(
                id: id,
                position: idx + 1,
                kind: .usbC,
                parentID: nil,
                connectedDevice: withInitialDevice ? makeDevice(name: "initial-\(idx)") : nil,
                negotiated: LinkSpeed(protocolName: "USB 2.0", bitrate: Bitrate(bitsPerSecond: 480_000_000)),
                powerDraw: Watts(0.5),
                children: []
            )
        }
        return ManifoldKit.Host(id: HostID("test-host"), name: "test", model: "test", ports: ports)
    }

    private func makeHostWithChildPort(
        parentID: PortID,
        childID: PortID = PortID("/host/parent/child")
    ) -> ManifoldKit.Host {
        let child = ManifoldKit.Port(
            id: childID,
            position: 1,
            kind: .usbA,
            parentID: parentID,
            connectedDevice: makeDevice(name: "child-initial"),
            negotiated: nil,
            powerDraw: nil,
            children: []
        )
        let parent = ManifoldKit.Port(
            id: parentID,
            position: 1,
            kind: .usbC,
            parentID: nil,
            connectedDevice: makeDevice(name: "parent-initial"),
            negotiated: LinkSpeed(protocolName: "USB 3.0", bitrate: Bitrate(bitsPerSecond: 5_000_000_000)),
            powerDraw: Watts(1.0),
            children: [child]
        )
        return ManifoldKit.Host(id: HostID("test-host"), name: "test", model: "test", ports: [parent])
    }

    private func makeDevice(name: String) -> Device {
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

    private func makeDiagnostic(target: String, rule: String) -> Diagnostic {
        Diagnostic(
            id: UUID(),
            target: PortID(target),
            severity: .info,
            ruleIdentifier: rule,
            title: rule,
            detail: rule,
            triggeredAt: Date(timeIntervalSince1970: 0)
        )
    }
}
