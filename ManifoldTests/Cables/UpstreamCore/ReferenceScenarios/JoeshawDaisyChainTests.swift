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

/// Reference-scenario test anchored on the joeshaw daisy-chain dump at
/// [research/dumps/cio/135-joeshaw-cio-daisy-chain.md](../../../research/dumps/cio/135-joeshaw-cio-daisy-chain.md).
///
/// **Topology** (from the source dump):
/// M2 Pro MacBook Pro → ASUS PA32QCV 6K monitor (USB4, JHL8440, depth 1)
/// → CalDigit TS3 Plus (TB3, JHL6540, depth 2). The CIO block attaches
/// to the depth-1 ASUS hop (`Device Vendor Name = "ASUS-Display"`,
/// `Device Model Name = "PA32QCV"` at source lines 38 and 50), not the
/// terminal TS3 Plus. CIO reports the first hop, not the chain tail.
///
/// **Cable**: original Sumitomo TB3 cable, VID `0x20C2`. WhatCable's own
/// JSON output (embedded in the source dump at line 189) confirms:
/// `"Cable speed: USB 3.2 Gen 2 (10 Gbps)"`. That is USB-PD VDO speed
/// code 2.
///
/// **Bug class**: same issue #111 pattern as
/// [BluevulpineTS3DockTests.swift](BluevulpineTS3DockTests.swift)
/// (passive e-marker, CIO confirms TB), but on a different real Mac
/// (M2 Pro, not the unspecified TB4-class machine) and with the added
/// daisy-chain complication. The CIO `Generation = 3` here (source
/// line 65) versus `Generation = 2` on bluevulpine: empirical evidence
/// the CIO `Generation` field is host-chip-dependent. The verdict is
/// not sensitive to that field, so this test is robust to that
/// observation.
///
/// **Synthesised vs from-dump**:
/// - **From the dump**: cable identity (Sumitomo, 10 Gbps e-marker per
///   WhatCable JSON line 189), CIO codes (lines 27, 52, 65), downstream
///   device (ASUS PA32QCV).
/// - **Synthesised**: port shape (standard M2 Pro USB-C), host max
///   (40 Gbps, since M2 Pro is TB4-class with `AsymmetricModeSupported = No`
///   per source line 30), active link rate (40 Gbps, consistent with
///   the WhatCable JSON's "Linked at up to 20 Gb/s × 2" bullet at
///   source line 185 = 40 Gbps full-duplex TB).
@Suite("Reference scenario: joeshaw M2 Pro + ASUS PA32QCV + CalDigit TS3 Plus")
struct JoeshawDaisyChainTests {

    private static func hostPort() -> AppleHPMInterface {
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
            usbActive: true,
            superSpeedActive: true,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: ["CC", "USB2", "USB3", "CIO", "DisplayPort"],
            transportsActive: ["CC", "USB3", "CIO"],
            transportsProvisioned: ["CC"],
            plugOrientation: nil,
            plugEventCount: nil,
            connectionCount: nil,
            overcurrentCount: nil,
            pinConfiguration: [:],
            powerCurrentLimits: [],
            firmwareVersion: nil,
            bootFlagsHex: nil,
            rawProperties: [:]
        )
    }

    /// CIO block from the ASUS PA32QCV depth-1 hop.
    /// Field origins (all from the source dump):
    /// - `CableSpeed = 3` (40 Gbps TB4-class) at line 52
    /// - `CableGeneration = 2` at line 27
    /// - `Generation = 3` at line 65 (M2 Pro host-tagged; not asserted)
    /// - `LinkTrainingMode = 2` at line 17
    /// - `AsymmetricModeSupported = No` at line 30
    /// - `LegacyAdapter = No` at line 64
    private static func asusCIO() -> CIOCableCapability {
        CIOCableCapability(
            id: 200,
            portKey: "2/1",
            cableGeneration: 2,
            negotiatedLinkSpeed: 3,
            generation: 3,
            asymmetricModeSupported: false,
            legacyAdapter: false,
            linkTrainingMode: 2
        )
    }

    private static func cableEmarker(speedCode: UInt32) -> USBPDSOP {
        let validLatency: UInt32 = 1 << 13
        let cableVDO = speedCode | (1 << 5) | validLatency
        let idHeader: UInt32 = 0x1800_0000
        return USBPDSOP(
            id: 2, endpoint: .sopPrime,
            parentPortType: 2, parentPortNumber: 1,
            vendorID: 0x20C2, productID: 0, bcdDevice: 0,
            vdos: [idHeader, 0, 0, cableVDO],
            specRevision: 0
        )
    }

    @Test("Sumitomo passive cable on M2 Pro daisy chain: controller wins")
    func sumitomoPassiveCable_ControllerWins() {
        // Sumitomo TB3 cable e-marker self-reports as 10 Gbps passive
        // (USB-PD VDO speed code 2). CIO controller at the depth-1 ASUS
        // hop reports CableSpeed = 3 (40 Gbps TB-capable). Cross-tier
        // disagreement; CIO wins. The link is genuinely at 40 Gbps
        // because the M2 Pro and the ASUS PA32QCV both negotiate TB4
        // (the WhatCable JSON in the dump confirms "Linked at up to
        // 20 Gb/s × 2").
        let diag = DataLinkDiagnostic(
            port: Self.hostPort(),
            identities: [Self.cableEmarker(speedCode: 2)],
            devices: [],
            usb3Transports: [],
            cio: Self.asusCIO(),
            tbActiveGbps: 40,
            hostMaxGbps: 40
        )

        guard case .fine(let active) = diag?.bottleneck else {
            Issue.record("expected .fine, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(active == 40)
        #expect(diag!.cableSignalConflict == true,
            "10 Gbps e-marker vs 40 Gbps CIO is a cross-tier conflict. Flag must be set.")
        #expect(diag!.facts.cableEmarkerGbps == 10)
        #expect(diag!.facts.cableControllerGbps == 40)
        #expect(diag!.facts.cableGbps == 40,
            "Controller (40) must win over the under-reporting e-marker (10).")
        #expect(diag!.detail.contains("disagree"),
            "Detail must surface the disagreement: \(diag!.detail)")
    }
}
