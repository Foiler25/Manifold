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

@Suite("USB port matching")
struct USBPortMatchingTests {
    @Test("matches devices by usbIOPort physical port name")
    func matchesDevicesByUsbIOPortPhysicalPortName() {
        let port = makePort(serviceName: "Port-USB-C@1", busIndex: 2)
        let matching = makeDevice(id: 1, controllerPortName: "Port-USB-C@1", busIndex: 9)
        let other = makeDevice(id: 2, controllerPortName: "Port-USB-C@2", busIndex: 2)

        #expect(port.matchingDevices(from: [other, matching]) == [matching])
    }

    @Test("matches device base port name variation")
    func matchesDeviceBasePortNameVariation() {
        let port = makePort(serviceName: "Port-USB-C@1", busIndex: 2)
        let matching = makeDevice(id: 1, controllerPortName: "Port-USB-C", busIndex: 2)

        #expect(port.matchingDevices(from: [matching]) == [matching])
    }

    @Test("matches port base name variation")
    func matchesPortBaseNameVariation() {
        let port = makePort(serviceName: "Port-USB-C", busIndex: 2)
        let matching = makeDevice(id: 1, controllerPortName: "Port-USB-C@1", busIndex: 2)

        #expect(port.matchingDevices(from: [matching]) == [matching])
    }

    @Test("decorated port name variations do not cross match")
    func decoratedPortNameVariationsDoNotCrossMatch() {
        let port = makePort(serviceName: "Port-USB-C@1", busIndex: 1)
        let other = makeDevice(id: 1, controllerPortName: "Port-USB-C@2", busIndex: 2)

        #expect(port.matchingDevices(from: [other]) == [])
    }

    @Test("direct usbIOPort presence prevents bus fallback")
    func directUsbIOPortPresencePreventsBusFallback() {
        let port = makePort(serviceName: "Port-USB-C@1", busIndex: 1)
        let deviceOnOtherPort = makeDevice(id: 1, controllerPortName: "Port-USB-C@2", busIndex: 1)

        #expect(port.matchingDevices(from: [deviceOnOtherPort]) == [])
    }

    @Test("falls back to busIndex only for nameless devices")
    func fallsBackToBusIndexOnlyForNamelessDevices() {
        let port = makePort(serviceName: "Port-USB-C@1", busIndex: 3)
        let namedElsewhere = makeDevice(id: 1, controllerPortName: "Port-USB-C@2", busIndex: 3)
        let namelessMatch = makeDevice(id: 2, busIndex: 3)

        #expect(port.matchingDevices(from: [namedElsewhere, namelessMatch]) == [namelessMatch])
    }

    @Test("no match key returns no devices instead of all devices")
    func noMatchKeyReturnsNoDevicesInsteadOfAllDevices() {
        let port = makePort(serviceName: "Port-USB-C@1")
        let devices = [
            makeDevice(id: 1, busIndex: 1),
            makeDevice(id: 2, busIndex: 2)
        ]

        #expect(port.matchingDevices(from: devices) == [])
    }

    @Test("bus fallback requires USB transport")
    func busFallbackRequiresUSBTransport() {
        let port = makePort(
            serviceName: "Port-MagSafe 3@1",
            busIndex: 1,
            usbActive: false,
            transportsActive: []
        )
        let device = makeDevice(id: 1, busIndex: 1)

        #expect(port.matchingDevices(from: [device]) == [])
    }

    @Test("bus fallback treats CIO as USB capable")
    func busFallbackTreatsCIOAsUSBCapable() {
        let port = makePort(
            serviceName: "Port-USB-C@1",
            busIndex: 1,
            usbActive: false,
            transportsActive: ["CIO"]
        )
        let device = makeDevice(id: 1, busIndex: 1)

        #expect(port.matchingDevices(from: [device]) == [device])
    }

    @Test("MagSafe portKey uses MagSafe port type without raw PortType")
    func magSafePortKeyUsesMagSafePortTypeWithoutRawPortType() {
        let port = makePort(
            serviceName: "Port-MagSafe 3@1",
            portTypeDescription: "MagSafe 3",
            rawProperties: [:]
        )

        #expect(port.portKey == "17/1")
    }

    private func makePort(
        serviceName: String,
        portDescription: String? = nil,
        portTypeDescription: String = "USB-C",
        busIndex: Int? = nil,
        usbActive: Bool? = true,
        transportsActive: [String] = ["USB2"],
        rawProperties: [String: String] = ["PortType": "2"]
    ) -> AppleHPMInterface {
        AppleHPMInterface(
            id: UInt64(abs(serviceName.hashValue)),
            serviceName: serviceName,
            className: "AppleHPMInterfaceType10",
            portDescription: portDescription,
            portTypeDescription: portTypeDescription,
            portNumber: 1,
            connectionActive: true,
            activeCable: nil,
            opticalCable: nil,
            usbActive: usbActive,
            superSpeedActive: nil,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: ["USB2", "USB3"],
            transportsActive: transportsActive,
            transportsProvisioned: ["CC"],
            plugOrientation: nil,
            plugEventCount: nil,
            connectionCount: nil,
            overcurrentCount: nil,
            pinConfiguration: [:],
            powerCurrentLimits: [],
            firmwareVersion: nil,
            bootFlagsHex: nil,
            busIndex: busIndex,
            rawProperties: rawProperties
        )
    }

    private func makeDevice(
        id: UInt64,
        controllerPortName: String? = nil,
        busIndex: Int? = nil
    ) -> USBDevice {
        USBDevice(
            id: id,
            locationID: 0,
            vendorID: 0,
            productID: 0,
            vendorName: nil,
            productName: "Device \(id)",
            serialNumber: nil,
            usbVersion: nil,
            speedRaw: nil,
            busPowerMA: nil,
            currentMA: nil,
            busIndex: busIndex,
            controllerPortName: controllerPortName,
            rawProperties: [:]
        )
    }
}
