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

@Suite("Text Formatter")
struct TextFormatterTests {

    // MARK: - Fixtures

    private func makePort(connected: Bool = true) -> AppleHPMInterface {
        AppleHPMInterface(
            id: 1,
            serviceName: "Port-USB-C@1",
            className: "AppleHPMInterfaceType10",
            portDescription: "Port-USB-C@1",
            portTypeDescription: "USB-C",
            portNumber: 1,
            connectionActive: connected,
            activeCable: nil,
            opticalCable: nil,
            usbActive: nil,
            superSpeedActive: true,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: ["USB2", "USB3"],
            transportsActive: connected ? ["USB3"] : [],
            transportsProvisioned: [],
            plugOrientation: nil,
            plugEventCount: nil,
            connectionCount: nil,
            overcurrentCount: nil,
            pinConfiguration: [:],
            powerCurrentLimits: [],
            firmwareVersion: nil,
            bootFlagsHex: nil,
            rawProperties: ["PortType": "2"]
        )
    }

    private func tunnelledDevice(name: String) -> USBDevice {
        USBDevice(
            id: 42, locationID: 0x2011_0000,
            vendorID: 0x05AC, productID: 0x0202,
            vendorName: "Apple", productName: name,
            serialNumber: nil, usbVersion: nil, speedRaw: 1,
            busPowerMA: nil, currentMA: nil,
            isThunderboltTunnelled: true,
            rawProperties: [:]
        )
    }

    // MARK: - Smoke

    @Test("Tunnelled devices render in an 'Other USB devices' section (issue #274)")
    func tunnelledDevicesRenderFlatSection() {
        // No Thunderbolt switches, so the device can't be attributed to a port
        // and falls into the flat section.
        let output = TextFormatter.render(
            ports: [makePort()], sources: [], identities: [], showRaw: false,
            usbDevices: [tunnelledDevice(name: "USB Optical Mouse")]
        )
        #expect(output.contains("Other USB devices"))
        #expect(output.contains("USB Optical Mouse"))
    }

    @Test("Render produces non-empty output")
    func renderProducesNonEmptyOutput() {
        let output = TextFormatter.render(
            ports: [makePort()], sources: [], identities: [], showRaw: false
        )
        #expect(!output.isEmpty)
    }

    @Test("Render empty ports produces non-empty output")
    func renderEmptyPortsProducesNonEmptyOutput() {
        let output = TextFormatter.render(
            ports: [], sources: [], identities: [], showRaw: false
        )
        #expect(!output.isEmpty)
        #expect(output.contains("No USB-C"))
    }

    // MARK: - Headline passthrough

    @Test("Headline from PortSummary appears verbatim")
    func headlineFromPortSummaryAppearsVerbatim() {
        let port = makePort(connected: false)
        let summary = PortSummary(port: port)
        let output = TextFormatter.render(
            ports: [port], sources: [], identities: [], showRaw: false
        )
        #expect(
            output.contains(summary.headline),
            "expected headline \"\(summary.headline)\" in render output"
        )
    }

    // MARK: - ANSI escapes absent when not a TTY

    @Test("No ANSI escapes in non-TTY output")
    func noANSIEscapesInNonTTYOutput() {
        let output = TextFormatter.render(
            ports: [makePort()], sources: [], identities: [], showRaw: false
        )
        #expect(
            output.contains("\u{1B}[") == false,
            "ANSI escape sequences should not appear when stdout is not a TTY"
        )
    }

    // MARK: - Thunderbolt fabric tree (issue #280)

    private func tbFabricPort() -> AppleHPMInterface {
        AppleHPMInterface(
            id: 1,
            serviceName: "Port-USB-C@1",
            className: "AppleHPMInterfaceType10",
            portDescription: "Port-USB-C@1",
            portTypeDescription: "USB-C",
            portNumber: 1,
            connectionActive: true,
            activeCable: nil,
            opticalCable: nil,
            usbActive: nil,
            superSpeedActive: nil,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: ["CC", "USB2", "USB3", "CIO", "DisplayPort"],
            transportsActive: ["CIO"],
            transportsProvisioned: ["CC"],
            plugOrientation: nil,
            plugEventCount: nil,
            connectionCount: nil,
            overcurrentCount: nil,
            pinConfiguration: [:],
            powerCurrentLimits: [],
            firmwareVersion: nil,
            bootFlagsHex: nil,
            rawProperties: ["PortType": "2"]
        )
    }

    private func fabricLanePort(_ portNumber: Int, socketID: String?) -> IOThunderboltPort {
        IOThunderboltPort(
            portNumber: portNumber,
            socketID: socketID,
            adapterType: .lane,
            currentSpeed: .usb4Tb4,
            currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil,
            rawTargetSpeed: nil,
            linkBandwidthRaw: nil
        )
    }

    private func fabricSwitch(uid: Int64, depth: Int, parent: Int64?, vendor: String, model: String, lane: Int, socketID: String?) -> IOThunderboltSwitch {
        IOThunderboltSwitch(
            id: uid,
            className: "IOThunderboltSwitchType5",
            vendorID: 1452,
            vendorName: vendor,
            modelName: model,
            routerID: 0,
            depth: depth,
            routeString: 0,
            upstreamPortNumber: 1,
            maxPortNumber: 8,
            supportedSpeed: SupportedSpeedMask(rawValue: 12),
            ports: [fabricLanePort(lane, socketID: socketID)],
            parentSwitchUID: parent
        )
    }

    /// The CLI text output must render the whole Thunderbolt fabric tree,
    /// including the second branch (OWC) that the old linear chain dropped.
    @Test("CLI renders the full Thunderbolt fabric tree with every branch")
    func cliRendersFullThunderboltFabricTree() {
        let switches = [
            fabricSwitch(uid: 100, depth: 0, parent: nil, vendor: "Apple Inc.", model: "iOS", lane: 1, socketID: "1"),
            fabricSwitch(uid: 200, depth: 1, parent: 100, vendor: "CalDigit, Inc.", model: "Thunderbolt 4 Pro Dock", lane: 2, socketID: nil),
            fabricSwitch(uid: 300, depth: 2, parent: 200, vendor: "LaCie", model: "1big Dock v2", lane: 2, socketID: nil),
            fabricSwitch(uid: 400, depth: 3, parent: 300, vendor: "Apple Inc.", model: "Studio Display", lane: 2, socketID: nil),
            fabricSwitch(uid: 500, depth: 2, parent: 200, vendor: "OWC", model: "Express 1M2", lane: 2, socketID: nil),
        ]
        let output = TextFormatter.render(
            ports: [tbFabricPort()], sources: [], identities: [],
            showRaw: false, thunderboltSwitches: switches
        )

        #expect(output.contains("Thunderbolt fabric:"), "fabric header missing; got:\n\(output)")
        // Every device must be named, including the previously-dropped OWC.
        for name in ["CalDigit, Inc. Thunderbolt 4 Pro Dock", "LaCie 1big Dock v2", "Apple Inc. Studio Display", "OWC Express 1M2"] {
            #expect(output.contains(name), "missing \(name) in fabric tree; got:\n\(output)")
        }
        // The two branches indent to different depths under the dock: the
        // Studio Display (depth 3) sits deeper than the OWC (depth 2).
        #expect(output.contains("      ↳ Apple Inc. Studio Display"), "Studio Display indent wrong; got:\n\(output)")
        #expect(output.contains("    ↳ OWC Express 1M2"), "OWC indent wrong; got:\n\(output)")
    }

    // MARK: - Cable trust signals

    /// Build an SOP' identity for trust-signal tests. `cableVDO` is VDO[3].
    /// Default uses USB4 Gen3 / 5A / ~1m latency, which produces no flags.
    private func cableIdentity(
        portNumber: Int = 1,
        vendorID: Int = 0x05AC,
        cableVDO: UInt32 = (0b10 << 5) | 0b011 | (1 << 13)
    ) -> USBPDSOP {
        USBPDSOP(
            id: 1,
            endpoint: .sopPrime,
            parentPortType: 2,
            parentPortNumber: portNumber,
            vendorID: vendorID,
            productID: 0x1234,
            bcdDevice: 0,
            vdos: [(3 << 27) | UInt32(vendorID), 0, 0, cableVDO],
            specRevision: 3
        )
    }

    @Test("No trust signals heading when cable is clean")
    func noTrustSignalsHeadingWhenCableIsClean() {
        let port = makePort()
        let cable = cableIdentity(portNumber: port.portNumber ?? 1)
        let output = TextFormatter.render(
            ports: [port], sources: [], identities: [cable], showRaw: false
        )
        #expect(
            output.contains("Cable trust signals") == false,
            "Clean cable should not surface a trust-signals section"
        )
    }

    @Test("Blank-VID note renders calmly when the VDO is well-formed")
    func blankVIDNoteRendersCalmly() {
        let port = makePort()
        // Default VDO is clean, so a blank VID is corroborated: it should
        // render as a calm "Cable note", not a warning-level "trust signals"
        // block, but still carry its title and detail.
        let cable = cableIdentity(portNumber: port.portNumber ?? 1, vendorID: 0)
        let output = TextFormatter.render(
            ports: [port], sources: [], identities: [cable], showRaw: false
        )
        #expect(output.contains("Cable note"))
        #expect(output.contains("Cable trust signals") == false)
        #expect(output.contains(TrustFlag.zeroVendorID(corroborated: true).title))
        #expect(output.contains(TrustFlag.zeroVendorID(corroborated: true).detail))
    }

    @Test("Multiple trust flags all render")
    func multipleTrustFlagsAllRender() {
        let port = makePort()
        // Unregistered VID + reserved speed = two flags.
        let vdo = UInt32(0b111) | UInt32(2 << 5) | UInt32(1 << 13)
        let cable = cableIdentity(
            portNumber: port.portNumber ?? 1,
            vendorID: 0xDEAD,
            cableVDO: vdo
        )
        let output = TextFormatter.render(
            ports: [port], sources: [], identities: [cable], showRaw: false
        )
        #expect(output.contains(TrustFlag.vidNotInUSBIFList(0xDEAD).title))
        #expect(output.contains(TrustFlag.reservedSpeedEncoding(7).title))
    }

    // MARK: - Active Cable VDO 2 raw view

    @Test("Active cable VDO2 section appears in raw mode")
    func activeCableVDO2SectionAppearsInRawMode() {
        let port = makePort()
        // VDO2 with optical + retimer + isolated + USB4 supported (bit 8 = 0).
        var vdo4: UInt32 = 0
        vdo4 |= UInt32(1) << 10  // optical
        vdo4 |= UInt32(1) << 9   // retimer
        vdo4 |= UInt32(1) << 2   // isolated
        // bits 8 / 5 / 4 left at 0 = USB4 / USB 3.2 / USB 2.0 supported.
        let vdo3: UInt32 = UInt32(0b011) | UInt32(2 << 5) | UInt32(1 << 13) | UInt32(0b10 << 11)
        let active = USBPDSOP(
            id: 1, endpoint: .sopPrime,
            parentPortType: 2,
            parentPortNumber: port.portNumber ?? 1,
            vendorID: 0x05AC, productID: 0, bcdDevice: 0,
            vdos: [(4 << 27) | UInt32(0x05AC), 0, 0, vdo3, vdo4],
            specRevision: 3
        )
        let output = TextFormatter.render(
            ports: [port], sources: [], identities: [active], showRaw: true
        )
        #expect(output.contains("Active cable (VDO 2)"))
        #expect(output.contains("Physical connection") && output.contains("Optical"))
        #expect(output.contains("Active element") && output.contains("Re-timer"))
        #expect(output.contains("USB4 supported") && output.contains("Yes"))
    }

    @Test("Active cable VDO2 section absent without raw flag")
    func activeCableVDO2SectionAbsentWithoutRawFlag() {
        let port = makePort()
        let vdo3: UInt32 = UInt32(0b011) | UInt32(2 << 5) | UInt32(1 << 13) | UInt32(0b10 << 11)
        let active = USBPDSOP(
            id: 1, endpoint: .sopPrime,
            parentPortType: 2,
            parentPortNumber: port.portNumber ?? 1,
            vendorID: 0x05AC, productID: 0, bcdDevice: 0,
            vdos: [(4 << 27) | UInt32(0x05AC), 0, 0, vdo3, 0],
            specRevision: 3
        )
        let output = TextFormatter.render(
            ports: [port], sources: [], identities: [active], showRaw: false
        )
        #expect(
            output.contains("Active cable (VDO 2)") == false,
            "VDO 2 deep view should only render with --raw"
        )
    }

    @Test("Trust signals suppressed for non-cable endpoint")
    func trustSignalsSuppressedForNonCableEndpoint() {
        // SOP (port partner) shouldn't be evaluated as a cable, so even
        // a zero VID on a port-partner identity shouldn't trip the section.
        let port = makePort()
        let partner = USBPDSOP(
            id: 1,
            endpoint: .sop,
            parentPortType: 2,
            parentPortNumber: port.portNumber ?? 1,
            vendorID: 0,
            productID: 0,
            bcdDevice: 0,
            vdos: [0, 0, 0, 0],
            specRevision: 3
        )
        let output = TextFormatter.render(
            ports: [port], sources: [], identities: [partner], showRaw: false
        )
        #expect(output.contains("Cable trust signals") == false)
    }

    // MARK: - Private key redaction (DAR-148)

    /// --raw text output must not print ConnectionUUID but must print
    /// legitimate keys like PortType.
    @Test("--raw text output omits ConnectionUUID and retains PortType")
    func rawTextOmitsConnectionUUID() {
        let port = AppleHPMInterface(
            id: 1, serviceName: "Port-USB-C@1",
            className: "AppleHPMInterfaceType10",
            portDescription: "Port-USB-C@1",
            portTypeDescription: "USB-C",
            portNumber: 1,
            connectionActive: true,
            activeCable: nil, opticalCable: nil, usbActive: nil,
            superSpeedActive: nil, usbModeType: nil, usbConnectString: nil,
            transportsSupported: ["CC", "USB2", "USB3"],
            transportsActive: ["USB3"], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil,
            rawProperties: [
                "ConnectionUUID": "DDDD6666-EEEE-7777-FFFF-888899990000",
                "PortType": "2",
                "VendorID": "0x05AC",
            ]
        )

        let output = TextFormatter.render(
            ports: [port], sources: [], identities: [], showRaw: true
        )

        #expect(!output.contains("ConnectionUUID"), "ConnectionUUID must not appear in text output")
        #expect(!output.contains("DDDD6666"), "ConnectionUUID value must not appear in text output")
        #expect(output.contains("PortType"), "PortType must appear in text output")
        #expect(output.contains("VendorID"), "VendorID must appear in text output")
    }

    /// DAR-29 privacy regression: the HPM controller UUID must never appear in
    /// text output, even when a future readAll path captures a raw "UUID" key.
    @Test("--raw text output omits UUID key and value (DAR-29 privacy guard)")
    func rawTextOmitsHPMControllerUUID() {
        let port = AppleHPMInterface(
            id: 1, serviceName: "Port-USB-C@1",
            className: "AppleHPMInterfaceType10",
            portDescription: "Port-USB-C@1",
            portTypeDescription: "USB-C",
            portNumber: 1,
            connectionActive: true,
            activeCable: nil, opticalCable: nil, usbActive: nil,
            superSpeedActive: nil, usbModeType: nil, usbConnectString: nil,
            transportsSupported: ["CC", "USB2", "USB3"],
            transportsActive: ["USB3"], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil,
            // Simulate a future readAll that accidentally captured UUID.
            rawProperties: [
                "UUID": "7C30AF2D-FEED-BEEF-CAFE-112233445566",
                "PortType": "2",
            ]
        )

        let output = TextFormatter.render(
            ports: [port], sources: [], identities: [], showRaw: true
        )

        #expect(!output.contains("UUID"), "UUID key must not appear in text output")
        #expect(!output.contains("7C30AF2D"), "UUID value must not appear in text output")
        #expect(output.contains("PortType"), "PortType must appear in text output")
    }

    // MARK: - Built-in display port (issue #352)

    private func hdmiDisplayDP() -> IOPortTransportStateDisplayPort {
        IOPortTransportStateDisplayPort(
            link: DisplayPortLink(
                active: true, laneCount: 4, maxLaneCount: 4, linkRate: 4,
                linkRateDescription: "8.1 Gbps (HBR3)", tunneled: false, hpdState: 1
            ),
            monitor: nil,
            parentPortType: 6,
            parentPortTypeDescription: "HDMI",
            parentPortNumber: 1
        )
    }

    @Test("Native HDMI port renders its own section after the USB-C group")
    func builtInHDMIPortRendersSection() {
        let hdmiPort = BuiltInDisplayPort(
            portType: "HDMI",
            portNumber: 1,
            displays: [hdmiDisplayDP()]
        )
        let output = TextFormatter.render(
            ports: [makePort()],
            sources: [], identities: [], showRaw: false,
            builtInDisplayPorts: [hdmiPort]
        )
        #expect(output.contains("Port-HDMI@1"))
        #expect(output.contains("Built-in HDMI port 1"))
        // The slim card has no PD bullets / charging / transport sections;
        // the only diagnostic block is the display verdict.
        #expect(!output.contains("Charging:"))
    }

    @Test("Native HDMI section omitted when no built-in display ports")
    func builtInHDMINotEmittedWhenEmpty() {
        let output = TextFormatter.render(
            ports: [makePort()],
            sources: [], identities: [], showRaw: false,
            builtInDisplayPorts: []
        )
        #expect(!output.contains("Port-HDMI@"))
    }

    // MARK: - Built-in USB ports gate (issue #348)

    private func frontPortDevice(name: String) -> USBDevice {
        USBDevice(
            id: 84, locationID: 0x0020_0000,
            vendorID: 0x04E8, productID: 0x61FD,
            vendorName: "Samsung", productName: name,
            serialNumber: nil, usbVersion: nil, speedRaw: 4,
            busPowerMA: nil, currentMA: nil,
            isBehindInternalHub: true,
            rawProperties: [:]
        )
    }

    @Test("Built-in USB ports section renders on a desktop Mac")
    func builtInUSBSectionRendersOnDesktop() {
        let output = TextFormatter.render(
            ports: [makePort()], sources: [], identities: [], showRaw: false,
            isDesktopMac: true,
            usbDevices: [frontPortDevice(name: "PSSD T9")]
        )
        #expect(output.contains("Built-in USB ports"))
        #expect(output.contains("PSSD T9"))
    }

    @Test("Built-in USB ports section is suppressed on a laptop (desktop-only gate)")
    func builtInUSBSectionSuppressedOnLaptop() {
        // Same front-port-flagged device, but isDesktopMac is false: the gate
        // keeps the section off laptops regardless of the structural flag.
        let output = TextFormatter.render(
            ports: [makePort()], sources: [], identities: [], showRaw: false,
            isDesktopMac: false,
            usbDevices: [frontPortDevice(name: "PSSD T9")]
        )
        #expect(!output.contains("Built-in USB ports"))
        #expect(!output.contains("PSSD T9"))
    }
}
