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
// Portions of this file derive from WhatCable
// (https://github.com/darrylmorley/whatcable) by Darryl Morley,
// originally distributed under the MIT licence. See
// `Manifold/Sources/Cables/ATTRIBUTION.md` for the full original
// copyright + permission notice.
//
// ─────────────────────────────────────────────────────────────────────
@testable import Manifold
import Foundation
import Testing

@Suite("Port Liveness")
struct PortLivenessTests {

    // MARK: - Fixtures

    private func usbCPort(
        connectionActive: Bool = false
    ) -> AppleHPMInterface {
        AppleHPMInterface(
            id: 1, serviceName: "Port-USB-C@1", className: "AppleHPMInterfaceType10",
            portDescription: nil, portTypeDescription: "USB-C", portNumber: 1,
            connectionActive: connectionActive,
            activeCable: nil, opticalCable: nil, usbActive: nil, superSpeedActive: nil,
            usbModeType: nil, usbConnectString: nil,
            transportsSupported: [], transportsActive: [], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil, rawProperties: [:]
        )
    }

    private func magSafePort(
        connectionActive: Bool = false
    ) -> AppleHPMInterface {
        AppleHPMInterface(
            id: 1, serviceName: "Port-MagSafe 3@1", className: "AppleHPMInterfaceType11",
            portDescription: nil, portTypeDescription: "MagSafe 3", portNumber: 1,
            connectionActive: connectionActive,
            activeCable: nil, opticalCable: nil, usbActive: nil, superSpeedActive: nil,
            usbModeType: nil, usbConnectString: nil,
            transportsSupported: [], transportsActive: [], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil, rawProperties: [:]
        )
    }

    private func staleUSBPDSource() -> PowerSource {
        PowerSource(
            id: 1, name: "USB-PD", parentPortType: 2, parentPortNumber: 1,
            options: [],
            winning: PowerOption(voltageMV: 20_000, maxCurrentMA: 1490, maxPowerMW: 29_800)
        )
    }

    private func partnerIdentity() -> USBPDSOP {
        USBPDSOP(
            id: 99, endpoint: .sop,
            parentPortType: 0, parentPortNumber: 0,
            vendorID: 0, productID: 0, bcdDevice: 0,
            vdos: [], specRevision: 0
        )
    }

    private func usbDevice() -> USBDevice {
        USBDevice(
            id: 42, locationID: 0, vendorID: 0, productID: 0,
            vendorName: nil, productName: nil, serialNumber: nil,
            usbVersion: nil, speedRaw: nil, busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
    }

    // MARK: - Cases

    @Test("Nothing present is not live")
    func nothingPresentIsNotLive() {
        #expect(!isPortLive(
            port: usbCPort(connectionActive: false),
            powerSources: [], identities: [], matchingDevices: []
        ))
    }

    @Test("USB device makes port live")
    func usbDeviceMakesPortLive() {
        #expect(isPortLive(
            port: usbCPort(connectionActive: false),
            powerSources: [], identities: [], matchingDevices: [usbDevice()]
        ))
    }

    @Test("USB PD SOP makes port live")
    func usbPDSOPMakesPortLive() {
        #expect(isPortLive(
            port: usbCPort(connectionActive: false),
            powerSources: [], identities: [partnerIdentity()], matchingDevices: []
        ))
    }

    @Test("Non-MagSafe connectionActive makes port live")
    func nonMagSafeConnectionActiveMakesPortLive() {
        #expect(isPortLive(
            port: usbCPort(connectionActive: true),
            powerSources: [], identities: [], matchingDevices: []
        ))
    }

    // MARK: - Issue #47 regressions

    @Test("Stale power source alone does not make port live")
    func stalePowerSourceAloneDoesNotMakePortLive() {
        // Issue #47: M2 MBA showed disconnected ports as connected because the
        // PowerSourceWatcher held a stale negotiated PDO. The port itself
        // correctly reports connectionActive=false, so the union must not
        // light up purely on the cached source.
        #expect(!isPortLive(
            port: usbCPort(connectionActive: false),
            powerSources: [staleUSBPDSource()],
            identities: [],
            matchingDevices: []
        ))
    }

    @Test("Stale power source on disconnected MagSafe is not live")
    func stalePowerSourceOnDisconnectedMagSafeIsNotLive() {
        // The MagSafe port from issue #47's JSON dump: connectionActive=false,
        // but the watcher still exposes a 30W winning PDO from the previous
        // session. Must not be treated as live.
        #expect(!isPortLive(
            port: magSafePort(connectionActive: false),
            powerSources: [staleUSBPDSource()],
            identities: [],
            matchingDevices: []
        ))
    }

    @Test("Power source with active connection is live")
    func powerSourceWithActiveConnectionIsLive() {
        // Charger genuinely plugged in: power source plus an active
        // connection. This is the case we still want to count as live, on
        // both USB-C and MagSafe.
        #expect(isPortLive(
            port: usbCPort(connectionActive: true),
            powerSources: [staleUSBPDSource()],
            identities: [],
            matchingDevices: []
        ))
        #expect(isPortLive(
            port: magSafePort(connectionActive: true),
            powerSources: [staleUSBPDSource()],
            identities: [],
            matchingDevices: []
        ))
    }

    @Test("MagSafe connectionActive alone is not live")
    func magSafeConnectionActiveAloneIsNotLive() {
        // The original MagSafe quirk: connectionActive=true lingers for
        // several seconds after unplug. Without any other live signal, we
        // shouldn't trust it.
        #expect(!isPortLive(
            port: magSafePort(connectionActive: true),
            powerSources: [], identities: [], matchingDevices: []
        ))
    }

    // MARK: - MagSafe charge-port-hidden (M1/M2: no per-port power source)

    @Test("Connected MagSafe with a charger attached is live, even with no power source")
    func connectedMagSafeWithChargerIsLive() {
        // The reported case (M1/M2 silicon): the MagSafe port reports connected
        // but exposes no per-port power source, so without the charger
        // corroboration it read as "nothing connected" and was hidden.
        #expect(isPortLive(
            port: magSafePort(connectionActive: true),
            powerSources: [], identities: [], matchingDevices: [],
            chargerAttached: true
        ))
    }

    @Test("Connected MagSafe with no charger attached is not live (lingering flag after unplug)")
    func connectedMagSafeWithoutChargerIsNotLive() {
        // connectionActive lingers true for seconds after unplug. With no
        // adapter attached, that must not keep the port live.
        #expect(!isPortLive(
            port: magSafePort(connectionActive: true),
            powerSources: [], identities: [], matchingDevices: [],
            chargerAttached: false
        ))
    }

    @Test("Disconnected MagSafe with a stale PDO stays not live even with a charger attached (issue #47 / #185)")
    func disconnectedMagSafeStalePDONotLiveWithCharger() {
        // The stale-cache case is connectionActive=false. A charger on another
        // port (chargerAttached=true) must not resurrect it, because the new
        // MagSafe branch is gated on connectionActive==true.
        #expect(!isPortLive(
            port: magSafePort(connectionActive: false),
            powerSources: [staleUSBPDSource()],
            identities: [], matchingDevices: [],
            chargerAttached: true
        ))
    }
}
