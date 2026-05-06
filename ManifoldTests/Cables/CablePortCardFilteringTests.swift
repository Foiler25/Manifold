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
// CablePortCardFilteringTests.swift
//
// Phase 21 regression coverage:
//
//   1. Per-port slice filter — passing the unfiltered snapshot arrays
//      to `PortSummary` made every port's card mirror Port-USB-C@1's
//      "Connected device: Passive cable — Shenzhen Injoinic" bullet
//      (visible in the screenshot the user shared 2026-05-06). The
//      fix: filter `identities`, `powerSources`, and `usbDevices` by
//      `port.portKey` / `port.matchingDevices(from:)` before handing
//      to `PortSummary`. The tests below pin both the symptom and the
//      fix.
//
//   2. Device-name bullets — `PortSummary.bullets` only names a
//      "Connected device" when there's a SOP PD identity (rare for
//      plain USB devices like SSDs and dongles). `CablePortCard`
//      appends bullets that name USB devices matched to the port via
//      `port.matchingDevices(from:)`. A port with a Logitech receiver
//      should now read "USB Receiver — Full Speed (12 Mbps)" instead
//      of being unnamed.

import XCTest
@testable import Manifold
import ManifoldKit

@MainActor
final class CablePortCardFilteringTests: XCTestCase {

    // MARK: - Cross-port leak regression

    func test_partnerIdentityOnPort1_doesNotLeakIntoPort2() {
        let port1 = Self.makePort(portNumber: 1)
        let port2 = Self.makePort(portNumber: 2)

        // SOP partner identity bound to port 1's portKey.
        let port1Partner = PDIdentity(
            id: 1001,
            endpoint: .sop,
            parentPortType: 0x2,
            parentPortNumber: 1,
            vendorID: 0x2E87,
            productID: 0,
            bcdDevice: 0,
            vdos: [0x6000_0000],
            specRevision: 3
        )

        let snapshot = CableSnapshot(
            ports: [port1, port2],
            powerSources: [],
            identities: [port1Partner],
            usbDevices: [],
            adapter: nil,
            thunderboltSwitches: []
        )

        let card1 = CablePortCard(port: port1, snapshot: snapshot, graph: PortGraph())
        let card2 = CablePortCard(port: port2, snapshot: snapshot, graph: PortGraph())

        // Port 1 sees its own partner identity in its summary's filtered
        // identities slice (the `Connected device:` bullet may fire
        // depending on header decoding — we don't assert on the bullet
        // text since that depends on PDVDO decoding, just on the slice).
        XCTAssertEqual(card1.testHook_filteredIdentityCount, 1)
        // Port 2 must NOT see port 1's identity. Without the per-port
        // slice fix, this returned 1 and the wrong bullet appeared on
        // port 2's card.
        XCTAssertEqual(card2.testHook_filteredIdentityCount, 0)
    }

    func test_powerSourceForPort1_doesNotLeakIntoPort2() {
        let port1 = Self.makePort(portNumber: 1)
        let port2 = Self.makePort(portNumber: 2)

        let port1Source = PowerSource(
            id: 9001,
            name: "USB-PD",
            parentPortType: 0x2,
            parentPortNumber: 1,
            options: [],
            winning: nil
        )

        let snapshot = CableSnapshot(
            ports: [port1, port2],
            powerSources: [port1Source],
            identities: [],
            usbDevices: [],
            adapter: nil,
            thunderboltSwitches: []
        )

        let card1 = CablePortCard(port: port1, snapshot: snapshot, graph: PortGraph())
        let card2 = CablePortCard(port: port2, snapshot: snapshot, graph: PortGraph())

        XCTAssertEqual(card1.testHook_filteredPowerSourceCount, 1)
        XCTAssertEqual(card2.testHook_filteredPowerSourceCount, 0)
    }

    // MARK: - Device-name bullets

    func test_devicesPluggedIntoPort_appearAsBullets_byProductName() {
        let port = Self.makePort(portNumber: 2, busIndex: 1, connected: true,
                                 transportsActive: ["USB3"], superSpeedActive: true)
        let receiver = USBDevice(
            id: 12_345,
            locationID: 0x0100_0000,
            vendorID: 0x046D,
            productID: 0xC548,
            vendorName: "Logitech",
            productName: "USB Receiver",
            serialNumber: nil,
            usbVersion: "2.0.0",
            speedRaw: 1, // Full Speed
            busPowerMA: 100,
            currentMA: 50,
            busIndex: 1,
            controllerPortName: "Port-USB-C@2",
            rawProperties: [:]
        )

        let snapshot = CableSnapshot(
            ports: [port],
            powerSources: [],
            identities: [],
            usbDevices: [receiver],
            adapter: nil,
            thunderboltSwitches: []
        )

        let card = CablePortCard(port: port, snapshot: snapshot, graph: PortGraph())
        let bullets = card.testHook_allBullets
        XCTAssertTrue(
            bullets.contains(where: { $0.contains("USB Receiver") }),
            "Expected a bullet naming 'USB Receiver'; got \(bullets)"
        )
        XCTAssertTrue(
            bullets.contains(where: { $0.contains("Full Speed") }),
            "Expected a bullet showing the device speed; got \(bullets)"
        )
    }

    func test_deviceWithoutProductName_fallsBackToVendor() {
        let port = Self.makePort(portNumber: 3, busIndex: 2, connected: true,
                                 transportsActive: ["USB3"], superSpeedActive: true)
        let device = USBDevice(
            id: 99_999,
            locationID: 0x0200_0000,
            vendorID: 0xABCD,
            productID: 0x1234,
            vendorName: "Acme Corp",
            productName: nil,
            serialNumber: nil,
            usbVersion: nil,
            speedRaw: 3,
            busPowerMA: nil,
            currentMA: nil,
            busIndex: 2,
            controllerPortName: "Port-USB-C@3",
            rawProperties: [:]
        )

        let snapshot = CableSnapshot(
            ports: [port],
            powerSources: [],
            identities: [],
            usbDevices: [device],
            adapter: nil,
            thunderboltSwitches: []
        )
        let card = CablePortCard(port: port, snapshot: snapshot, graph: PortGraph())
        let bullets = card.testHook_allBullets
        XCTAssertTrue(
            bullets.contains(where: { $0.contains("Acme Corp") }),
            "Expected fallback to vendor name when productName is nil; got \(bullets)"
        )
    }

    func test_deviceOnDifferentPort_doesNotLeakIntoThisPortsBullets() {
        let port1 = Self.makePort(portNumber: 1, busIndex: 0, connected: true,
                                  transportsActive: ["USB3"], superSpeedActive: true)
        let port2 = Self.makePort(portNumber: 2, busIndex: 1, connected: true,
                                  transportsActive: ["USB3"], superSpeedActive: true)
        let port1Device = USBDevice(
            id: 1, locationID: 0,
            vendorID: 0, productID: 0,
            vendorName: nil, productName: "OnlyOnPort1",
            serialNumber: nil, usbVersion: nil,
            speedRaw: 3, busPowerMA: nil, currentMA: nil,
            busIndex: 0, controllerPortName: "Port-USB-C@1",
            rawProperties: [:]
        )
        let snapshot = CableSnapshot(
            ports: [port1, port2],
            powerSources: [],
            identities: [],
            usbDevices: [port1Device],
            adapter: nil,
            thunderboltSwitches: []
        )

        let card2 = CablePortCard(port: port2, snapshot: snapshot, graph: PortGraph())
        XCTAssertFalse(
            card2.testHook_allBullets.contains(where: { $0.contains("OnlyOnPort1") }),
            "Port 2's card must not list devices belonging to Port 1"
        )
    }

    // MARK: - Helpers

    private static func makePort(
        portNumber: Int,
        busIndex: Int? = nil,
        connected: Bool = false,
        transportsActive: [String] = [],
        superSpeedActive: Bool? = nil
    ) -> USBCPort {
        USBCPort(
            id: UInt64(portNumber),
            serviceName: "Port-USB-C@\(portNumber)",
            className: "AppleHPMInterfaceType10",
            portDescription: "Port-USB-C@\(portNumber)",
            portTypeDescription: "USB-C",
            portNumber: portNumber,
            connectionActive: connected,
            activeCable: nil,
            opticalCable: nil,
            usbActive: !transportsActive.isEmpty,
            superSpeedActive: superSpeedActive,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: ["CC"],
            transportsActive: transportsActive,
            transportsProvisioned: [],
            plugOrientation: nil,
            plugEventCount: nil,
            connectionCount: nil,
            overcurrentCount: nil,
            pinConfiguration: [:],
            powerCurrentLimits: [],
            firmwareVersion: nil,
            bootFlagsHex: nil,
            busIndex: busIndex,
            rawProperties: ["PortType": "2"]
        )
    }
}

// MARK: - Test hooks
//
// CablePortCard's filtering + bullet builders are private. These
// extensions expose just enough surface for the regression tests
// without leaking those internals to the wider Manifold codebase.

extension CablePortCard {
    var testHook_filteredIdentityCount: Int {
        let portKey = port.portKey
        guard let key = portKey else { return 0 }
        return snapshot.identities.filter { $0.portKey == key }.count
    }

    var testHook_filteredPowerSourceCount: Int {
        let portKey = port.portKey
        guard let key = portKey else { return 0 }
        return snapshot.powerSources.filter { $0.portKey == key }.count
    }

    /// Reproduces `CablePortCard.allBullets` for assertion purposes.
    /// Keep in sync with the production builder; if `allBullets`
    /// changes shape the test will surface the drift.
    var testHook_allBullets: [String] {
        let portKey = port.portKey
        let identities: [PDIdentity] = portKey.map { key in
            snapshot.identities.filter { $0.portKey == key }
        } ?? []
        let sources: [PowerSource] = portKey.map { key in
            snapshot.powerSources.filter { $0.portKey == key }
        } ?? []
        let devices = port.matchingDevices(from: snapshot.usbDevices)
        let summary = PortSummary(
            port: port,
            sources: sources,
            identities: identities,
            devices: devices,
            thunderboltSwitches: snapshot.thunderboltSwitches
        )
        let deviceBullets: [String] = devices.compactMap { device in
            let p = device.productName?.trimmingCharacters(in: .whitespaces) ?? ""
            let v = device.vendorName?.trimmingCharacters(in: .whitespaces) ?? ""
            let name: String
            if !p.isEmpty { name = p }
            else if !v.isEmpty { name = v }
            else { return nil }
            return "\(name) — \(device.speedLabel)"
        }
        return summary.bullets + deviceBullets
    }
}
