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

@Suite("Data Link Diagnostic")
struct DataLinkDiagnosticTests {

    // MARK: - Fixtures

    /// Active USB-C port. Same shape as the ChargingDiagnostic fixture
    /// (the proven-compiling AppleHPMInterface init param list).
    /// `transportsActive` defaults to `["CC", "USB3", "CIO"]` so the
    /// fixture exercises the TB-aware paths by default; tests that
    /// hand-roll USB3-only or USB2-only scenarios override it.
    /// `transportsSupported` mirrors a real M-class USB-C port (matters
    /// for the `carriesData` gate added in the issue #195 fix); MagSafe
    /// shape tests override it to `[]`.
    private func makePort(
        active: Bool = true,
        transportsActive: [String] = ["CC", "USB3", "CIO"],
        transportsSupported: [String] = ["CC", "USB2", "USB3", "CIO", "DisplayPort"],
        serviceName: String = "Port-USB-C@1",
        portTypeDescription: String? = "USB-C",
        superSpeedActive: Bool? = nil
    ) -> AppleHPMInterface {
        AppleHPMInterface(
            id: 1,
            serviceName: serviceName,
            className: "AppleHPMInterfaceType10",
            portDescription: nil,
            portTypeDescription: portTypeDescription,
            portNumber: 1,
            connectionActive: active,
            activeCable: nil,
            opticalCable: nil,
            usbActive: nil,
            superSpeedActive: superSpeedActive,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: transportsSupported,
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
            rawProperties: [:]
        )
    }

    /// Cable e-marker (SOP') advertising a given CableSpeed code in the
    /// low 3 bits of VDO[3]. Codes: 0 = USB 2.0 (0.48), 1 = USB 3.2 Gen 1
    /// (5), 2 = Gen 2 (10), 3 = USB4 Gen 3 (40), 4 = Gen 4 (80). Mirrors
    /// the ChargingDiagnostic test's cableIdentity construction.
    private func cableEmarker(speedCode: UInt32) -> USBPDSOP {
        let validLatency: UInt32 = 1 << 13          // ~1m, avoids decode warning
        let cableVDO = speedCode | (1 << 5) | validLatency   // 3A current bits
        let idHeader: UInt32 = 0x1800_0000          // passive cable, UFP type 3
        return USBPDSOP(
            id: 2, endpoint: .sopPrime,
            parentPortType: 2, parentPortNumber: 1,
            vendorID: 0, productID: 0, bcdDevice: 0,
            vdos: [idHeader, 0, 0, cableVDO],
            specRevision: 0
        )
    }

    /// USB device with a given "Device Speed" enum value.
    /// 3 = 5 Gbps, 4 = 10 Gbps, 5 = 20 Gbps.
    private func device(speedRaw: UInt8) -> USBDevice {
        USBDevice(
            id: 10, locationID: 0x0100_0000,
            vendorID: 0x1234, productID: 0x5678,
            vendorName: nil, productName: "Test SSD", serialNumber: nil,
            usbVersion: nil, speedRaw: speedRaw,
            busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
    }

    private func cio(negotiatedLinkSpeed: Int) -> CIOCableCapability {
        CIOCableCapability(
            id: 3, portKey: "2/1",
            cableGeneration: nil, negotiatedLinkSpeed: negotiatedLinkSpeed, generation: nil,
            asymmetricModeSupported: nil, legacyAdapter: nil, linkTrainingMode: nil
        )
    }

    private func usb3(signaling: Int, transportRestricted: Bool? = nil) -> USB3Transport {
        USB3Transport(
            id: 4, portKey: "2/1",
            signaling: signaling, signalingDescription: nil, dataRole: nil,
            transportRestricted: transportRestricted
        )
    }

    // MARK: - Applicability

    @Test("Returns nil on an inactive port")
    func returnsNilOnInactivePort() {
        let diag = DataLinkDiagnostic(
            port: makePort(active: false),
            identities: [cableEmarker(speedCode: 3)],
            devices: [device(speedRaw: 5)],
            usb3Transports: [usb3(signaling: 2)],
            cio: nil
        )
        #expect(diag == nil)
    }

    @Test("Returns nil when no active link speed is known")
    func returnsNilWithoutActiveSpeed() {
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],
            devices: [device(speedRaw: 5)],
            usb3Transports: [],            // no USB3 signaling
            cio: nil,
            tbActiveGbps: nil              // no TB link
        )
        #expect(diag == nil)
    }

    @Test("Returns nil for a power-only MagSafe port (issue #195)")
    func returnsNilForMagSafePort() {
        // M2 MacBook Air shape from issue #195: MagSafe and the first
        // USB-C port share the same HPM controller die and therefore the
        // controller-local `@1` socket suffix. Empty `transportsSupported`
        // is the exclusive capability signal for "power-only port"; the
        // diagnostic now refuses to verdict on it. Without the gate the
        // host-max inference would attribute USB-C@1's 40 Gbps lane mask
        // to MagSafe and produce a confident "Running at full data speed
        // (40 Gbps)" verdict.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xC, activeSpeed: .usb4Tb4)
        let diag = DataLinkDiagnostic(
            port: makePort(
                transportsActive: ["CC"],
                transportsSupported: [],
                serviceName: "Port-MagSafe 3@1",
                portTypeDescription: "MagSafe 3"
            ),
            identities: [],
            devices: [],
            usb3Transports: [],
            cio: nil,
            thunderboltSwitches: [host]
        )
        #expect(diag == nil)
    }

    @Test("Within-controller socket-ID collision: USB-C verdicts, MagSafe abstains")
    func withinControllerCollision() {
        // The exact shape that the #159 verification pass missed: a
        // MagSafe and a USB-C port on the same controller, sharing the
        // `@1` socket suffix. The USB-C port must still get a real
        // verdict; the MagSafe port must abstain. The host TB switch is
        // shared (one root, one lane port at socket "1").
        let host = hostSwitch(socketID: "1", supportedRaw: 0xC, activeSpeed: .usb4Tb4)

        let usbC = makePort(
            transportsActive: ["CC", "USB3", "CIO"],
            serviceName: "Port-USB-C@1"
        )
        let magSafe = makePort(
            transportsActive: ["CC"],
            transportsSupported: [],
            serviceName: "Port-MagSafe 3@1",
            portTypeDescription: "MagSafe 3"
        )

        let usbDiag = DataLinkDiagnostic(
            port: usbC,
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps
            devices: [],
            usb3Transports: [],
            cio: nil,
            thunderboltSwitches: [host]
        )
        let magSafeDiag = DataLinkDiagnostic(
            port: magSafe,
            identities: [],
            devices: [],
            usb3Transports: [],
            cio: nil,
            thunderboltSwitches: [host]
        )
        #expect(usbDiag != nil,
            "USB-C port must still get a verdict despite sharing its socket suffix with MagSafe")
        #expect(magSafeDiag == nil,
            "MagSafe must abstain even when a usable TB switch exists for its colliding socket suffix")
    }

    @Test("USB 2.0 cable on a USB-C port returns nil without a real active rate")
    func usb2CableNoActiveRate() {
        // bigskookum's shape (issue #195 follow-up): a USB-C port holds
        // a USB 2.0 cable. `transportsActive` does not contain CIO or
        // USB3, so the TB lookup (which on Apple Silicon reads the
        // always-up internal root lane) is now gated off, and no USB3
        // signaling is available. With no honest active rate, the
        // diagnostic abstains rather than reading 40 Gbps off the
        // internal lane. The cable badge from PortSummary still
        // surfaces the USB 2.0 reading separately.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xC, activeSpeed: .usb4Tb4)
        let diag = DataLinkDiagnostic(
            port: makePort(
                transportsActive: ["CC", "USB2"],         // USB 2.0 cable only
                transportsSupported: ["CC", "USB2", "USB3", "CIO", "DisplayPort"]
            ),
            identities: [cableEmarker(speedCode: 0)],    // USB 2.0 e-marker
            devices: [],
            usb3Transports: [],
            cio: nil,
            thunderboltSwitches: [host]
        )
        #expect(diag == nil,
            "A USB 2.0-only link should not pick up a Thunderbolt active rate from the always-up internal lane")
    }

    @Test("Cable contradicts active rate when no CIO tiebreak (Change B)")
    func cableContradictsActive() {
        // Synthetic case: e-marker says USB 2.0, the link reads 40 Gbps,
        // no CIO. With the old floor, cable would be promoted to 40 and
        // the verdict would say "Running at full data speed". The new
        // behaviour surfaces both numbers and asks the user to swap the
        // cable to resolve the contradiction.
        let diag = DataLinkDiagnostic(
            port: makePort(transportsActive: ["CC", "USB3", "CIO"]),
            identities: [cableEmarker(speedCode: 0)],    // USB 2.0 (0.48)
            devices: [],
            usb3Transports: [],
            cio: nil,
            tbActiveGbps: 40,
            hostMaxGbps: 40
        )
        guard case .cableContradictsActive(let cableGbps, let activeGbps) = diag?.bottleneck else {
            Issue.record("expected .cableContradictsActive, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(cableGbps == 0.48)
        #expect(activeGbps == 40)
        #expect(diag!.isWarning)
        #expect(diag!.facts.cableGbps == 0.48,
            "Facts must reflect the cable's actual claim, not the silently-promoted active rate")
    }

    // MARK: - Bottleneck attribution

    @Test("Cable is the bottleneck")
    func cableIsBottleneck() {
        // Mac port 20, device 20, but a USB 3.2 Gen 1 (5 Gbps) cable.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 1)],   // 5 Gbps
            devices: [device(speedRaw: 5)],              // 20 Gbps
            usb3Transports: [usb3(signaling: 1)],        // active 5 Gbps
            cio: nil,
            hostMaxGbps: 20
        )
        guard case .cableLimit(let cable, let capable) = diag?.bottleneck else {
            Issue.record("expected .cableLimit, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(cable == 5)
        #expect(capable == 20)
        #expect(diag!.isWarning)
    }

    @Test("Host port is the bottleneck")
    func hostIsBottleneck() {
        // Fast 40 Gbps cable, 20 Gbps device, but the Mac port only does 5.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps
            devices: [device(speedRaw: 5)],              // 20 Gbps
            usb3Transports: [usb3(signaling: 1)],        // active 5 Gbps
            cio: nil,
            hostMaxGbps: 5
        )
        guard case .hostLimit(let host, let capable) = diag?.bottleneck else {
            Issue.record("expected .hostLimit, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(host == 5)
        #expect(capable == 20)
        #expect(diag!.isWarning)
    }

    @Test("Device is the cap, not a fault")
    func deviceIsCapNotFault() {
        // 40 Gbps cable, 40 Gbps port, but a 10 Gbps device.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps
            devices: [device(speedRaw: 4)],              // 10 Gbps
            usb3Transports: [usb3(signaling: 2)],        // active 10 Gbps
            cio: nil,
            hostMaxGbps: 40
        )
        guard case .deviceLimit(let d) = diag?.bottleneck else {
            Issue.record("expected .deviceLimit, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(d == 10)
        #expect(diag!.isWarning == false)   // a slow device is normal, not a warning
    }

    @Test("Degraded link: everyone supports more but it came up slow")
    func degradedLink() {
        // 40 Gbps cable, 40 Gbps port, 20 Gbps device, but the TB link
        // negotiated only 5 Gbps. This is the case the old draft wrongly
        // reported as "full speed".
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps
            devices: [device(speedRaw: 5)],              // 20 Gbps
            usb3Transports: [],
            cio: nil,
            tbActiveGbps: 5,                             // degraded link
            hostMaxGbps: 40
        )
        guard case .degraded(let active, let expected) = diag?.bottleneck else {
            Issue.record("expected .degraded, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(active == 5)
        #expect(expected == 20)
        #expect(diag!.isWarning)
    }

    @Test("No cable signal: honest 'can't tell'")
    func unknownCableWhenNoSignal() {
        // No e-marker, no controller data. Port 40, device 20, link 5.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [device(speedRaw: 5)],              // 20 Gbps
            usb3Transports: [usb3(signaling: 1)],        // active 5 Gbps
            cio: nil,
            hostMaxGbps: 40
        )
        guard case .unknownCable(let active) = diag?.bottleneck else {
            Issue.record("expected .unknownCable, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(active == 5)
        #expect(diag!.isWarning == false)
        #expect(diag!.cableSignalConflict == false)
    }

    @Test("Everything matched: fine")
    func everythingFine() {
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps
            devices: [],
            usb3Transports: [],
            cio: nil,
            tbActiveGbps: 40,                            // active 40 Gbps
            hostMaxGbps: 40
        )
        guard case .fine(let active) = diag?.bottleneck else {
            Issue.record("expected .fine, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(active == 40)
        #expect(diag!.isWarning == false)
    }

    @Test("Controller overrides a lying e-marker (issue #111)")
    func controllerWinsOverEmarker() {
        // E-marker claims USB 2.0 (passive under-report), but the TB
        // controller reports CableSpeed 3 (40 Gbps). We must NOT blame the
        // cable: report fine at 40 and flag the conflict.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 0)],   // e-marker says 0.48
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),                     // controller says 40
            tbActiveGbps: 40,
            hostMaxGbps: 40
        )
        guard case .fine(let active) = diag?.bottleneck else {
            Issue.record("expected .fine, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(active == 40)
        #expect(diag!.cableSignalConflict == true)
        #expect(diag!.detail.contains("disagree"))
    }

    @Test("E-marker claim above the CIO floor is not a conflict (issue #393 direction)")
    func emarkerClaimAboveFloorIsNotAConflict() {
        // Historical note: this fixture used to encode "the controller
        // always wins" -- e-marker claims USB4 Gen 4 (80 Gbps), CIO
        // reports CableSpeed 3 (40 Gbps), take the controller's lower
        // figure -- on the theory that a higher e-marker claim must be a
        // lying cable (issue #190, a zeroed-VID Amazon cable). Issue #393
        // proved that assumption wrong for genuine cables: a real,
        // registered-vendor CableMatters TB5 cable produces the exact
        // same shape (e-marker 80, CIO 40) whenever both endpoints cap at
        // 40. CIO is the negotiated floor, never a ceiling, so a claim
        // above it is not, by itself, evidence of a lying cable.
        // Suspicion about a specific cable (e.g. a zeroed VID) is
        // CableTrust's job, not this tiebreak's. cableMaxGbps must now
        // resolve to the e-marker's own claim (80), with no conflict.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 4)],   // e-marker says 80
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),            // controller floor: 40
            tbActiveGbps: 40,
            hostMaxGbps: 80                              // M4 Max-class host
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.cableEmarkerGbps == 80)
        #expect(facts.cableControllerGbps == 40)
        #expect(facts.cableGbps == 80,
            "The e-marker's claim must stand: CIO is a floor, not a cap. Got: \(String(describing: facts.cableGbps))")
        #expect(diag!.cableSignalConflict == false,
            "A claim above the CIO floor is not, by itself, a conflict")
    }

    @Test("Same-tier e-marker and CIO agree at 80: no conflict, take the value")
    func sameTierEmarkerAndCIOAgreeAtEighty() {
        // Both signals say 80 (TB5-class): agreement, not a conflict.
        // min(80, 80) via sameTier -> cableMaxGbps = 80.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 4)],   // e-marker: 80
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 4),            // controller: 80
            tbActiveGbps: 80,
            hostMaxGbps: 80
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.cableEmarkerGbps == 80)
        #expect(facts.cableControllerGbps == 80)
        #expect(facts.cableGbps == 80)
        #expect(diag!.cableSignalConflict == false)
    }

    @Test("Stale-controller guard: a higher CIO figure uncorroborated by the live link stays quiet")
    func staleCIOAboveEmarkerAndActiveStaysQuiet() {
        // CIO and the TB switch lane state come from two different IOKit
        // services on two different watcher streams, so a transient can
        // leave CIO reading higher than the link that is actually up.
        // Shape: e-marker claims 40, CIO says 80 (uncorroborated), the
        // live link runs 40. The e-marker matches the link; the higher
        // CIO figure matches nothing. Walk: sameTier(e 40, active 40)
        // holds and sameTier(c 80, active 40) does not (ratio 2), so the
        // guard keeps the e-marker's 40 with no conflict banner, and the
        // verdict is a plain full-speed .fine (40 = host = device tier).
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // e-marker: 40
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 4),            // CIO claims 80
            tbActiveGbps: 40,                            // but the link runs 40
            hostMaxGbps: 40
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.cableGbps == 40,
            "An uncorroborated higher CIO figure must not override the e-marker")
        #expect(diag!.cableSignalConflict == false,
            "No confirmed-conflict banner from possibly stale controller data")
    }

    @Test("Controller wins over the e-marker when the live link corroborates it (issue #111 direction)")
    func cioAboveEmarkerCorroboratedByActiveWins() {
        // The genuine #111 shape: e-marker under-reports (5 Gbps), CIO
        // says 40 and the live link really runs 40. sameTier(e 5,
        // active 40) fails, so the stale-controller guard does not
        // apply: the controller's corroborated figure wins, conflict on.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 1)],   // e-marker: 5
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),            // controller: 40
            tbActiveGbps: 40,
            hostMaxGbps: 40
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.cableGbps == 40)
        #expect(diag!.cableSignalConflict == true)
    }

    @Test("PD 3.0 Gen3 ambiguity: a 20 Gbps floor resolves the Gen3 claim to 20, not 40")
    func gen3ClaimResolvesToFloorOnTB3Link() {
        // A TB3-era passive cable e-marks "Gen3", which means 20 Gbps
        // under PD 3.0 but 40 under PD 3.1; the decoder hardcodes 40.
        // With the controller floor at 20 (a real TB3 link), the PD 3.0
        // reading is the one the evidence supports. Walk: claim resolves
        // to 20 = CIO 20, same tier, agreement; caps cable 20 / host 40,
        // expected 20 = active 20, cable is the unique floor below the
        // 40 Gbps host, so the verdict is the correct .cableLimit (a
        // faster cable would unlock more), NOT a false "slower than
        // expected" built on the phantom 40 Gbps reading.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // Gen3: 20 or 40
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 2),            // controller floor: 20
            tbActiveGbps: 20,
            hostMaxGbps: 40
        )
        guard let diag else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(diag.facts.cableGbps == 20)
        #expect(diag.cableSignalConflict == false)
        if case .cableLimit = diag.bottleneck {
        } else {
            Issue.record("expected .cableLimit for a 20 Gbps cable on a 40 Gbps host, got \(diag.bottleneck)")
        }
    }

    @Test("Issue #393 shape maps to amber trust, not a false green confirmation")
    func claimAboveFloorIsNotTrustConfirmed() {
        // Before the #393 fix, this shape deflated the cable's claim to
        // the negotiated 40 and reported .fine, which CableTrust read as
        // "delivered its claim" -> green. That green was circular: the
        // claim it confirmed was the bug's own deflation. The honest
        // behaviour-first verdict for an 80 Gbps claim that has only ever
        // been seen running 40 is "not yet seen to perform at its claim"
        // (amber): neither confirmed nor contradicted. Pin that mapping
        // so a future change can't quietly flip it back.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 4)],   // claims 80
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),            // floor: 40
            tbActiveGbps: 40,
            hostMaxGbps: 40
        )
        guard let diag else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        let behaviour = CableTrust.behaviour(
            for: diag.bottleneck,
            hasCableSpeedClaim: diag.facts.cableGbps != nil
        )
        #expect(behaviour.dataConfirmed == false,
            "An endpoint-limited link must not confirm an untested 80 Gbps claim")
        #expect(behaviour.contradiction == false,
            "Nor is an untested claim a contradiction")
    }

    @Test("Issue #393: e-marker claim above the floor names the device, not the cable")
    func emarkerClaimAboveFloorNamesDevice() {
        // The exact #393 shape: CableMatters TB5 cable (e-marker claims
        // USB4 Gen 4, 80 Gbps) between an M3 Pro host (TB4-class, 40
        // Gbps max) and a LaCie Rugged SSD4 (TB4-class TB partner, 40
        // Gbps max). CIO reports CableSpeed=3 (40 Gbps): the negotiated
        // floor, min(host, cable, device) = min(80, 40, 40) = 40.
        //
        // Arithmetic: caps = [cable=80, host=40, device=40].
        // expected = min(80, 40, 40) = 40. active (40) is sameTier as
        // expected (40), so this does NOT hit the "meaningfully slower"
        // branch at all -- it goes straight to culprit naming. limiters
        // (sameTier with 40) = [host, device]; fasterOthers
        // (meaningfullySlower(40, than: value)) = [cable] (40 < 80*0.9).
        // fasterOthers isn't empty, so it's not "fine"; priority
        // ["device", "host", "cable"] finds "device" first in limiters
        // -> .deviceLimit(40). The cable, being faster than both
        // endpoints, is never blamed.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xC, activeSpeed: .usb4Tb4)
        let partner = partnerSwitch(parent: host, parentLanePortNumber: 1, supportedRaw: 0xC)
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 4)],   // e-marker claims 80
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),            // controller floor: 40
            thunderboltSwitches: [host, partner],
            tbActiveGbps: 40,
            hostMaxGbps: 40
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.cableEmarkerGbps == 80)
        #expect(facts.cableControllerGbps == 40)
        #expect(facts.cableGbps == 80,
            "The e-marker's claim must stand: CIO is a floor, not a cap. Got: \(String(describing: facts.cableGbps))")
        #expect(diag!.cableSignalConflict == false,
            "A cable claiming more than its endpoints negotiated is not a conflict")
        guard case .deviceLimit(let d) = diag?.bottleneck else {
            Issue.record("expected .deviceLimit (host and device tie at the 40 Gbps floor), got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(d == 40)
        #expect(diag!.isWarning == false, "This is fastest-the-endpoints-support, not a fault")
    }

    @Test("All-known 80 Gbps rig with a 40 Gbps floor: degraded fires honestly")
    func allKnownEightyRigDegradedFiresHonestly() {
        // Adversarial counter-case to the unknown-endpoint guard: host
        // AND device are BOTH independently known to do 80 Gbps,
        // e-marker claims 80, but CIO (and the active link) only measured
        // 40. The guard must NOT suppress the verdict here: two
        // independently-known parts exceed the active rate, so something
        // really is holding the link back, and the honest answer is
        // "degraded", not a hedge.
        //
        // Arithmetic: caps = [cable=80, host=80, device=80].
        // expected = min(80, 80, 80) = 80. meaningfullySlower(40, than:
        // 80) is true (40 < 72), so this DOES enter the guard check.
        // hostExceedsActive = meaningfullySlower(40, than: 80) = true,
        // so the guard's `!hostExceedsActive` fails and the hedge does
        // NOT fire. Falls through to .degraded(active: 40, expected: 80).
        let host = hostSwitch(socketID: "1", supportedRaw: 0xE, activeSpeed: .usb4Tb4)
        let partner = partnerSwitch(parent: host, parentLanePortNumber: 1, supportedRaw: 0xE)   // TB5-class partner, 80 Gbps
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 4)],   // e-marker claims 80
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),            // controller floor: 40
            thunderboltSwitches: [host, partner],
            tbActiveGbps: 40,
            hostMaxGbps: 80
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.hostGbps == 80)
        #expect(facts.deviceGbps == 80, "Partner switch should report the TB5-class 80 Gbps mask")
        #expect(facts.cableGbps == 80, "E-marker claim stands: not contradicted, CIO tier is lower")
        guard case .degraded(let active, let expected) = diag?.bottleneck else {
            Issue.record("expected .degraded (host and device both independently exceed the active rate), got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(active == 40)
        #expect(expected == 80)
        #expect(diag!.isWarning)
    }

    @Test("Unknown host and device: an above-floor e-marker claim alone does not trigger a false degraded verdict")
    func unknownEndpointsHedgeInsteadOfFalseDegraded() {
        // Neither the Mac port's max nor the connected device's max is
        // known here (no TB switch graph, no USB device enumerated). The
        // e-marker's 80 Gbps claim is the only "capability" figure we
        // have, and it is unverified (CIO only measured 40). Without the
        // unknown-endpoint guard, `expected` would equal the claim (80)
        // and the link (measured 40) would read as "meaningfully slower
        // than expected", producing a false "Running slower than
        // expected" warning on a link that is not actually degraded,
        // just unverified.
        //
        // Arithmetic: caps = [cable=80] only (host and device both nil).
        // expected = 80. meaningfullySlower(40, than: 80) = true, so the
        // guard check runs. hostExceedsActive = false (host unknown),
        // deviceExceedsActive = false (device unknown).
        // cableClaimAboveCIOFloor = true (rule B fired above). All three
        // guard conditions hold -> hedge (.unknownCable), not .degraded.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 4)],   // e-marker claims 80
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),            // controller floor: 40
            tbActiveGbps: 40
            // hostMaxGbps and thunderboltSwitches both omitted: host and
            // device stay unresolved.
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.hostGbps == nil)
        #expect(facts.deviceGbps == nil)
        #expect(facts.cableGbps == 80)
        guard case .unknownCable(let active) = diag?.bottleneck else {
            Issue.record("expected the hedged .unknownCable verdict, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(active == 40)
        #expect(diag!.isWarning == false, "A hedge is informational, not a warning")
        #expect(diag!.detail.contains("80"), "The detail should still mention the cable's claim")
    }

    @Test("CIO cableSpeed 2 maps to 20 Gbps (TB3)")
    func cioSpeed2MapsTB3() {
        // TB3 dock on a TB4 host. CIO reports cableSpeed=2 (20 Gbps).
        // E-marker agrees (speed code 2 = 10 Gbps USB 3.2 Gen 2, but
        // that's the USB-PD encoding; the CIO 20 Gbps is the TB lane
        // rate). Host supports 40, so cable is the bottleneck.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 2),
            tbActiveGbps: 20,
            hostMaxGbps: 40
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.cableControllerGbps == 20)
        #expect(facts.activeGbps == 20)
        guard case .cableLimit(let cableGbps, let capableGbps) = diag?.bottleneck else {
            Issue.record("expected .cableLimit, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(cableGbps == 20)
        #expect(capableGbps == 40)
    }

    @Test("No capability known at all: unknownCable, not a guess")
    func noCapabilityKnown() {
        // Active 10 Gbps link, but no e-marker, no controller data, host
        // unresolved, no device. Nothing to compare against.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [],
            usb3Transports: [usb3(signaling: 2)],        // active 10 Gbps
            cio: nil,
            hostMaxGbps: nil
        )
        guard case .unknownCable(let active) = diag?.bottleneck else {
            Issue.record("expected .unknownCable, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(active == 10)
        #expect(diag!.isWarning == false)
    }

    @Test("Facts expose the resolved per-party numbers")
    func factsExposeResolvedNumbers() {
        // E-marker says 0.48 (USB 2.0), controller says 40 (TB4 class),
        // host 40, device 10 (speedRaw 4), link active at 40 (TB).
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 0)],   // 0.48
            devices: [device(speedRaw: 4)],              // 10
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),                     // 40
            tbActiveGbps: 40,
            hostMaxGbps: 40
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic with facts, got nil")
            return
        }
        #expect(facts.cableEmarkerGbps == 0.48)
        #expect(facts.cableControllerGbps == 40)
        #expect(facts.cableGbps == 40)        // controller wins
        #expect(facts.deviceGbps == 10)
        #expect(facts.hostGbps == 40)
        #expect(facts.activeGbps == 40)
        #expect(diag!.cableSignalConflict == true)
    }

    // MARK: - TransportsActive gating

    @Test("USB2-only link ignores lingering USB3 transport (issue #187)")
    func usb2OnlyLinkIgnoresLingeringUSB3Transport() {
        // A USB-C to Micro-USB cable negotiates only USB 2.0, but the
        // HPM port controller can leave a `IOPortTransportStateUSB3`
        // service registered (carrying Gen 2 signaling) and assert
        // `IOAccessoryUSBSuperSpeedActive=1`. Neither should produce a
        // 10 Gbps verdict: `TransportsActive` is the authority.
        let diag = DataLinkDiagnostic(
            port: makePort(transportsActive: ["CC", "USB2"], superSpeedActive: true),
            identities: [],
            devices: [],
            usb3Transports: [usb3(signaling: 2)],
            cio: nil,
            hostMaxGbps: nil
        )
        #expect(diag == nil,
            "USB2-only link must not produce a USB3 data-link verdict, got: \(String(describing: diag?.bottleneck))")
    }

    // MARK: - Mac port speed inference

    /// Build a host root TB switch with the given `supportedSpeed` mask and
    /// one active lane port matching `socketID`. Minimal fixture: just
    /// enough for `hostMaxGbpsFromSwitches` to walk to it.
    private func hostSwitch(socketID: String, supportedRaw: UInt8, activeSpeed: LinkGeneration) -> IOThunderboltSwitch {
        let lane = IOThunderboltPort(
            portNumber: 1,
            socketID: socketID,
            adapterType: .lane,
            currentSpeed: activeSpeed,
            currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil,
            rawTargetSpeed: nil,
            linkBandwidthRaw: nil
        )
        return IOThunderboltSwitch(
            id: 100,
            className: "IOIOThunderboltSwitchType5",
            vendorID: 1452,
            vendorName: "Apple Inc.",
            modelName: "Mac",
            routerID: 0,
            depth: 0,
            routeString: 0,
            upstreamPortNumber: 0,
            maxPortNumber: 8,
            supportedSpeed: SupportedSpeedMask(rawValue: supportedRaw),
            ports: [lane],
            parentSwitchUID: nil
        )
    }

    @Test("hostMaxGbps inferred from host root supportedSpeed (TB4-class controller)")
    func hostMaxGbpsInferredTB4() {
        // Mac with a Type5 controller: supports TB3 + TB4. Max = 40 Gbps.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xC, activeSpeed: .usb4Tb4)
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [],
            usb3Transports: [usb3(signaling: 2)],
            cio: nil,
            thunderboltSwitches: [host]
            // hostMaxGbps deliberately omitted; should be inferred from `host`.
        )
        #expect(diag?.facts.hostGbps == 40,
            "Expected 40 Gbps host max from Type5 supportedSpeed mask, got: \(String(describing: diag?.facts.hostGbps))")
    }

    @Test("hostMaxGbps inferred from host root supportedSpeed (TB5-class controller)")
    func hostMaxGbpsInferredTB5() {
        // Mac with a Type7 controller: supports TB3 + TB4 + TB5. Max = 80.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xE, activeSpeed: .tb5)
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [],
            usb3Transports: [usb3(signaling: 2)],
            cio: nil,
            thunderboltSwitches: [host]
        )
        #expect(diag?.facts.hostGbps == 80,
            "Expected 80 Gbps host max from Type7 supportedSpeed mask, got: \(String(describing: diag?.facts.hostGbps))")
    }

    @Test("Per-port supportedSpeed beats the switch aggregate (asymmetric controller)")
    func perPortSupportedSpeedBeatsAggregate() {
        // Build an asymmetric host root: port socket "1" supports only
        // TB4 (per-port mask 0xC), while the switch-level aggregate is
        // 0xE (TB3 + TB4 + TB5) -- the shape the OR-the-lane-ports
        // fallback would produce on a switch with another TB5-capable
        // lane elsewhere. Using `root.supportedSpeed.maxTotalGbps`
        // would falsely report 80 Gbps for the socket-1 user. The
        // matched port's own mask must win.
        let socket1Port = IOThunderboltPort(
            portNumber: 1, socketID: "1", adapterType: .lane,
            currentSpeed: .usb4Tb4, currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xC)   // TB3 + TB4 only
        )
        let socket9Port = IOThunderboltPort(
            portNumber: 9, socketID: "9", adapterType: .lane,
            currentSpeed: .tb5, currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE)   // TB3 + TB4 + TB5
        )
        let asymmetricRoot = IOThunderboltSwitch(
            id: 100,
            className: "IOThunderboltSwitchType7",
            vendorID: 1452,
            vendorName: "Apple Inc.",
            modelName: "Mac",
            routerID: 0,
            depth: 0,
            routeString: 0,
            upstreamPortNumber: 0,
            maxPortNumber: 8,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE),  // misleading aggregate
            ports: [socket1Port, socket9Port],
            parentSwitchUID: nil
        )
        let diag = DataLinkDiagnostic(
            port: makePort(),                                   // serviceName Port-USB-C@1 → socket "1"
            identities: [],
            devices: [],
            usb3Transports: [usb3(signaling: 2)],
            cio: nil,
            thunderboltSwitches: [asymmetricRoot]
        )
        #expect(diag?.facts.hostGbps == 40,
            "Expected 40 Gbps from port-1's own mask, not 80 Gbps from the switch aggregate. Got: \(String(describing: diag?.facts.hostGbps))")
    }

    @Test("Zero supportedSpeed mask returns nil (no host blame)")
    func zeroMaskReturnsNil() {
        // A switch with no supported-speed bits at all (mask 0) must
        // produce nil hostGbps so the diagnostic never blames the host.
        let host = hostSwitch(socketID: "1", supportedRaw: 0, activeSpeed: .usb4Tb4)
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [],
            usb3Transports: [usb3(signaling: 2)],
            cio: nil,
            thunderboltSwitches: [host]
        )
        #expect(diag?.facts.hostGbps == nil)
    }

    // MARK: - Thunderbolt partner switch as device cap (issue #190)

    /// Build a depth-1 partner switch attached to `parent` via `parent`'s
    /// lane port `parentLanePortNumber`. `supportedRaw` is the partner's
    /// own supported-speed mask, which is what the diagnostic uses as the
    /// connected device's capability.
    ///
    /// Mirrors what real IOKit topology looks like (verified against the
    /// Samsung C34J79x fixture in `ThunderboltLinkFromTests`):
    ///   * `parentSwitchUID` points at the parent's UID.
    ///   * `routeString` low byte is the parent's downstream port number
    ///     leading to this child (not the child's own port number).
    ///   * `upstreamPortNumber` is the child's OWN port number for its
    ///     upstream link. Real partners often have this value at 3 even
    ///     when the parent connects through port 1.
    private func partnerSwitch(
        parent: IOThunderboltSwitch,
        parentLanePortNumber: Int,
        supportedRaw: UInt8,
        partnerOwnUpstreamPortNumber: Int = 3
    ) -> IOThunderboltSwitch {
        let upstream = IOThunderboltPort(
            portNumber: partnerOwnUpstreamPortNumber, socketID: nil, adapterType: .lane,
            currentSpeed: .usb4Tb4, currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil,
            supportedSpeed: SupportedSpeedMask(rawValue: supportedRaw)
        )
        return IOThunderboltSwitch(
            id: parent.id + Int64(parentLanePortNumber),
            className: "IOThunderboltSwitchType5",
            vendorID: 9999,
            vendorName: "Partner",
            modelName: "Partner Device",
            routerID: 1,
            depth: 1,
            routeString: Int64(parentLanePortNumber),
            upstreamPortNumber: partnerOwnUpstreamPortNumber,
            maxPortNumber: 4,
            supportedSpeed: SupportedSpeedMask(rawValue: supportedRaw),
            ports: [upstream],
            parentSwitchUID: parent.id
        )
    }

    @Test("TB partner switch supplies the device cap (issue #190, Port 4)")
    func tbPartnerSwitchSuppliesDeviceCap() {
        // LaCie d2 TB3 scenario: TB3 partner (40 Gbps), no USB device, TB5
        // host (80 Gbps), 40 Gbps cable, link active at 40. Without the
        // partner-switch lookup the diagnostic had no device cap and
        // blamed the cable. With it: device = 40 from partner, cable = 40,
        // host = 80 → device limit, no cable blame.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xE, activeSpeed: .usb4Tb4)
        let partner = partnerSwitch(parent: host, parentLanePortNumber: 1, supportedRaw: 0x8)   // TB3 only
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps cable
            devices: [],                                  // TB-only device, no USB enum
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),                     // controller confirms 40
            thunderboltSwitches: [host, partner],
            tbActiveGbps: 40
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.deviceGbps == 40,
            "Expected 40 Gbps device cap from partner TB switch (TB3 mask). Got: \(String(describing: facts.deviceGbps))")
        if case .cableLimit = diag?.bottleneck {
            Issue.record("Expected device-side outcome, not cable blame: \(String(describing: diag?.bottleneck))")
        }
    }

    @Test("TB partner overrides a slow USB sub-device (issue #190, Ports 2/3)")
    func tbPartnerOverridesUSBSubDevice() {
        // WERO TBT4 hub scenario: TB4 partner (40 Gbps), but a 10 Gbps USB
        // hub IC inside the dock enumerates as a USB device. Active link is
        // 40 Gbps. Without the partner-switch lookup the diagnostic took
        // the USB device's 10 Gbps as the device cap and announced
        // "Device runs at 10 Gbps." With it: device = 40 from partner,
        // matching the 40 Gbps link → fine, no "10 Gbps" verdict.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xE, activeSpeed: .usb4Tb4)
        let partner = partnerSwitch(parent: host, parentLanePortNumber: 1, supportedRaw: 0xC)   // TB3 + TB4
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps cable
            devices: [device(speedRaw: 4)],              // 10 Gbps internal USB hub
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),                     // 40 Gbps
            thunderboltSwitches: [host, partner],
            tbActiveGbps: 40
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.deviceGbps == 40,
            "TB partner (40) must win over the internal USB hub IC (10). Got: \(String(describing: facts.deviceGbps))")
        // The link runs at the TB4 partner's cap (40 Gbps) against a TB5
        // host. That makes the device the (non-actionable) limit, which is
        // not a fault. The crucial thing is the *number*: 40, not 10.
        guard case .deviceLimit(let d) = diag?.bottleneck else {
            Issue.record("expected .deviceLimit at the partner's TB4 cap, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(d == 40, "Reported device limit should match the partner switch's mask, not the internal USB IC")
        #expect(diag!.isWarning == false, "A TB4 partner on a TB5 host is informational, not a warning")
    }

    @Test("Falls back to USB device speed when no TB partner switch present")
    func fallsBackToUSBDeviceWithoutPartner() {
        // Plain USB-C SSD: no TB partner, just a USB device at 10 Gbps.
        // The USB device cap should still drive the verdict.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xE, activeSpeed: .usb4Tb4)
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps cable
            devices: [device(speedRaw: 4)],              // 10 Gbps USB device
            usb3Transports: [usb3(signaling: 2)],        // active 10 Gbps
            cio: nil,
            thunderboltSwitches: [host]                  // host only, no partner
        )
        #expect(diag?.facts.deviceGbps == 10)
        guard case .deviceLimit(let d) = diag?.bottleneck else {
            Issue.record("expected .deviceLimit when only USB device present, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(d == 10)
    }

    @Test("Partner switch on a sibling lane port is not used for this port")
    func partnerSwitchOnOtherLaneIgnored() {
        // Controller hosts two user-visible USB-C ports on the same root.
        // Port-USB-C@1 has no partner. The sibling lane (socket "9") has
        // a TB5 partner. The diagnostic for socket "1" must not borrow
        // the sibling's partner; deviceGbps should fall back to USB.
        let socket1Lane = IOThunderboltPort(
            portNumber: 1, socketID: "1", adapterType: .lane,
            currentSpeed: .usb4Tb4, currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE)
        )
        let socket9Lane = IOThunderboltPort(
            portNumber: 9, socketID: "9", adapterType: .lane,
            currentSpeed: .usb4Tb4, currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE)
        )
        let root = IOThunderboltSwitch(
            id: 100,
            className: "IOThunderboltSwitchType7",
            vendorID: 1452,
            vendorName: "Apple Inc.",
            modelName: "Mac",
            routerID: 0,
            depth: 0,
            routeString: 0,
            upstreamPortNumber: 0,
            maxPortNumber: 16,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE),
            ports: [socket1Lane, socket9Lane],
            parentSwitchUID: nil
        )
        // Partner attached to the *sibling* lane (port 9), not port 1.
        let siblingPartner = partnerSwitch(parent: root, parentLanePortNumber: 9, supportedRaw: 0xE)
        let diag = DataLinkDiagnostic(
            port: makePort(),                             // Port-USB-C@1 → socket "1"
            identities: [],
            devices: [device(speedRaw: 4)],              // 10 Gbps USB device on this port
            usb3Transports: [usb3(signaling: 2)],
            cio: nil,
            thunderboltSwitches: [root, siblingPartner]
        )
        #expect(diag?.facts.deviceGbps == 10,
            "Sibling lane's TB partner must not be used as this port's device cap. Got: \(String(describing: diag?.facts.deviceGbps))")
    }

    // MARK: - Culprit priority on tied floors (issue #190, Port 1)

    @Test("Cable + device tied at the floor: blame device, not cable")
    func cableAndDeviceTiedAtFloorBlamesDevice() {
        // WERO TBT3 SSD scenario: TB3 device (40 Gbps), TB3 cable (40 Gbps
        // via controller), TB5 host (80 Gbps), active 40 Gbps. Both cable
        // and device are at the floor; replacing the cable would not
        // unlock more speed because the device caps there too. The verdict
        // must be device-side, not "cable is limiting."
        let host = hostSwitch(socketID: "1", supportedRaw: 0xE, activeSpeed: .usb4Tb4)
        let partner = partnerSwitch(parent: host, parentLanePortNumber: 1, supportedRaw: 0x8)   // TB3
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps cable
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),                     // 40 Gbps
            thunderboltSwitches: [host, partner],
            tbActiveGbps: 40
        )
        if case .cableLimit = diag?.bottleneck {
            Issue.record("Cable tied with device at 40 must not be blamed as the cable limit: got \(String(describing: diag?.bottleneck))")
        }
        guard case .deviceLimit(let d) = diag?.bottleneck else {
            Issue.record("expected .deviceLimit when cable + device tie at the floor, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(d == 40)
    }

    @Test("Partner switch matching uses routeString, not its own upstreamPortNumber")
    func partnerMatchingUsesRouteStringNotUpstreamPortNumber() {
        // Critical regression guard. Real partner switches report their
        // OWN upstream port number (3 on the Samsung C34J79x), which is
        // different from the parent host port they connect through (1).
        // Earlier drafts of this fix incorrectly matched against the
        // child's upstreamPortNumber and would not find the real partner.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xE, activeSpeed: .usb4Tb4)
        let partner = partnerSwitch(
            parent: host,
            parentLanePortNumber: 1,                 // parent's downstream port is 1
            supportedRaw: 0x8,                        // TB3-class partner
            partnerOwnUpstreamPortNumber: 3          // partner's own upstream is 3 (Samsung pattern)
        )
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),
            thunderboltSwitches: [host, partner],
            tbActiveGbps: 40
        )
        #expect(diag?.facts.deviceGbps == 40,
            "Partner must be found by routeString (low byte == parent port number), not by upstreamPortNumber. Got: \(String(describing: diag?.facts.deviceGbps))")
    }

    @Test("Partner with empty supportedSpeed mask uses active TB rate")
    func partnerWithEmptyMaskUsesActiveRate() {
        // Defence-in-depth: a partner switch can be present but expose an
        // empty `supportedSpeed` mask (unrecognised bits, firmware that
        // doesn't populate the field). Falling back to USB devices would
        // re-introduce the "Device runs at 10 Gbps" bug whenever the dock
        // has a USB hub IC. Instead, the active negotiated TB rate is the
        // floor: the partner is at least that fast (it just negotiated).
        let host = hostSwitch(socketID: "1", supportedRaw: 0xE, activeSpeed: .usb4Tb4)
        let partner = partnerSwitch(
            parent: host,
            parentLanePortNumber: 1,
            supportedRaw: 0                          // empty mask
        )
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],
            devices: [device(speedRaw: 4)],          // 10 Gbps USB IC behind the dock
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),
            thunderboltSwitches: [host, partner],
            tbActiveGbps: 40
        )
        #expect(diag?.facts.deviceGbps == 40,
            "Empty partner mask should fall back to the active TB rate (40), not the USB IC (10). Got: \(String(describing: diag?.facts.deviceGbps))")
    }

    // MARK: - E-marker claim above the CIO floor (issue #393)

    @Test("E-marker claim above the CIO floor resolves directly, independent of `active`")
    func cableSpeedFlooredAtActiveRate() {
        // Historical name: this used to test the old "promote cable to
        // active" floor hack for a hypothetical stale-CIO reading. That
        // branch is gone (CIO and the active TB rate are read from the
        // same lane state, so CIO can never legitimately disagree with
        // `active` in real data; see the deleted comment this test used
        // to reference). This fixture still exercises a real code path:
        // the e-marker's claim (80) is above the CIO floor (40), so per
        // the rule-B resolution `cableMaxGbps` takes the e-marker's value
        // (80) directly. It does not matter what `active` happens to be
        // here (80, in this fixture, purely as a test seam value); the
        // e-marker's claim is not derived from `active` at all.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 4)],   // e-marker says 80
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),            // controller floor: 40
            tbActiveGbps: 80,                            // link active (test seam value)
            hostMaxGbps: 80
        )
        #expect(diag?.facts.cableGbps == 80,
            "E-marker claim above the CIO floor resolves directly to the claim. Got: \(String(describing: diag?.facts.cableGbps))")
        #expect(diag?.cableSignalConflict == false,
            "Not a conflict: CIO tier is lower than the e-marker's claim")
    }

    @Test("Cable is unique floor: still blame cable")
    func cableUniqueFloorStillBlamesCable() {
        // 5 Gbps cable, 20 Gbps device, 20 Gbps host, active 5 Gbps.
        // Cable is the only thing at the floor; the priority swap must
        // not stop it from being identified as the actionable culprit.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 1)],   // 5 Gbps
            devices: [device(speedRaw: 5)],              // 20 Gbps
            usb3Transports: [usb3(signaling: 1)],        // active 5 Gbps
            cio: nil,
            hostMaxGbps: 20
        )
        guard case .cableLimit = diag?.bottleneck else {
            Issue.record("expected .cableLimit when cable is the unique floor, got \(String(describing: diag?.bottleneck))")
            return
        }
    }

    @Test("Explicit hostMaxGbps wins over the inference")
    func explicitHostMaxGbpsWins() {
        // Caller passes 5 Gbps explicitly even though the switch graph
        // would infer 40. The explicit value should be honoured (test seam).
        let host = hostSwitch(socketID: "1", supportedRaw: 0xC, activeSpeed: .usb4Tb4)
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [],
            usb3Transports: [usb3(signaling: 2)],
            cio: nil,
            thunderboltSwitches: [host],
            hostMaxGbps: 5
        )
        #expect(diag?.facts.hostGbps == 5)
    }

    // MARK: - Hub uplink (issue #245)

    @Test("USB3 hub: headline follows the Mac-to-hub uplink, not a slower deeper link (issue #245)")
    func hubUplinkSpeedNotDeeperLink() {
        // Satechi-hub shape from issue #245: a root 10 Gbps hub is the
        // Mac-to-hub uplink; a secondary 5 Gbps hub sits one hop deeper
        // inside it. The HPM USB3 transport reports the slower Gen 1 (5)
        // link. The verdict must follow the uplink (10), matching the port
        // summary's `usb3Speed` bullet, not the deeper 5 Gbps link. Before
        // this fix the active rate was taken straight from the transport
        // signaling and the headline read "Running at 5 Gbps" while the
        // bullet said 10.
        let rootHub = USBDevice(
            id: 20, locationID: 0x0020_0000,        // one nibble -> root device
            vendorID: 0x1234, productID: 0x0001,
            vendorName: nil, productName: "4-Port USB 3.0 Hub", serialNumber: nil,
            usbVersion: nil, speedRaw: 4,            // SuperSpeed+ 10 Gbps
            busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
        let deeperHub = USBDevice(
            id: 21, locationID: 0x0024_0000,        // two nibbles -> behind the hub
            vendorID: 0x2109, productID: 0x0817,
            vendorName: nil, productName: "USB3.0 Hub", serialNumber: nil,
            usbVersion: nil, speedRaw: 3,            // SuperSpeed 5 Gbps
            busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )

        let diag = DataLinkDiagnostic(
            port: makePort(transportsActive: ["CC", "USB3", "USB2"]),
            identities: [],                          // no e-marker
            devices: [rootHub, deeperHub],
            usb3Transports: [usb3(signaling: 1)],    // controller reports the slow Gen 1 link
            cio: nil
        )

        #expect(diag?.facts.activeGbps == 10)
        #expect(diag?.bottleneck == .fine(activeGbps: 10))
    }

    @Test("USB3 without a resolvable root device still falls back to transport signaling")
    func usb3FallsBackToTransportSignalingWithoutRootDevice() {
        // No clean root-nibble device present (e.g. an Apple Silicon front
        // USB-C port whose internal virtual root inflates the locationID
        // nibbles). rootSuperSpeed is empty, so the controller's USB3
        // signaling remains the active rate, exactly as before this fix.
        let diag = DataLinkDiagnostic(
            port: makePort(transportsActive: ["CC", "USB3", "USB2"]),
            identities: [],
            devices: [device(speedRaw: 4)],          // locationID 0x0100_0000, not a root nibble
            usb3Transports: [usb3(signaling: 2)],    // Gen 2 (10)
            cio: nil
        )

        #expect(diag?.facts.activeGbps == 10)
    }

    // MARK: - TRM blocked-by-security verdict (DAR-134)

    @Test("TRM-restricted USB3 transport yields .blockedBySecurity (DAR-134)")
    func trmRestrictedYieldsBlockedBySecurity() {
        // When TRM_TransportRestricted is true on the USB3 transport the link
        // is physically capable but macOS is withholding data. The old behaviour
        // falsely returned .fine; the fix emits .blockedBySecurity instead.
        let diag = DataLinkDiagnostic(
            port: makePort(transportsActive: ["CC", "USB3"]),
            identities: [],
            devices: [],
            usb3Transports: [usb3(signaling: 1, transportRestricted: true)],  // Gen 1 (5 Gbps), restricted
            cio: nil
        )
        guard case .blockedBySecurity(let signaledGbps) = diag?.bottleneck else {
            Issue.record("Expected .blockedBySecurity, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(signaledGbps == 5, "signaledGbps should be 5 from Gen 1 signaling")
        #expect(diag!.isWarning, "blockedBySecurity must be a warning verdict")
        #expect(diag!.summary == "Data blocked by macOS accessory security")
        #expect(diag!.detail.contains("5 Gbps"))
    }

    @Test("TRM-restricted false leaves previous verdict path unchanged")
    func trmRestrictedFalseDoesNotBlock() {
        // transportRestricted=false must not trigger the security verdict.
        // The diagnostic should proceed normally: in this case .unknownCable
        // because no e-marker and no host cap is supplied.
        let diag = DataLinkDiagnostic(
            port: makePort(transportsActive: ["CC", "USB3"]),
            identities: [],
            devices: [],
            usb3Transports: [usb3(signaling: 2, transportRestricted: false)],
            cio: nil
        )
        if case .blockedBySecurity = diag?.bottleneck {
            Issue.record("transportRestricted=false must not produce .blockedBySecurity")
        }
        // Expect a normal (non-security) verdict: unknownCable in this scenario.
        guard case .unknownCable = diag?.bottleneck else {
            Issue.record("Expected .unknownCable (no e-marker, no host cap), got \(String(describing: diag?.bottleneck))")
            return
        }
    }

    @Test("TRM-restricted nil leaves previous verdict path unchanged")
    func trmRestrictedNilDoesNotBlock() {
        // transportRestricted=nil (field absent) must not trigger the security verdict.
        let diag = DataLinkDiagnostic(
            port: makePort(transportsActive: ["CC", "USB3"]),
            identities: [],
            devices: [],
            usb3Transports: [usb3(signaling: 2)],    // nil transportRestricted by default
            cio: nil
        )
        if case .blockedBySecurity = diag?.bottleneck {
            Issue.record("transportRestricted=nil must not produce .blockedBySecurity")
        }
        guard case .unknownCable = diag?.bottleneck else {
            Issue.record("Expected .unknownCable (no e-marker, no host cap), got \(String(describing: diag?.bottleneck))")
            return
        }
    }
}
