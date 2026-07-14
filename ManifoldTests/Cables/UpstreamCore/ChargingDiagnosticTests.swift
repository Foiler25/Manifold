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

@Suite("Charging Diagnostic")
struct ChargingDiagnosticTests {

    // MARK: - Fixtures

    private var port: AppleHPMInterface {
        AppleHPMInterface(
            id: 1,
            serviceName: "Port-USB-C@1",
            className: "AppleHPMInterfaceType10",
            portDescription: nil,
            portTypeDescription: "USB-C",
            portNumber: 1,
            connectionActive: true,
            activeCable: nil,
            opticalCable: nil,
            usbActive: nil,
            superSpeedActive: nil,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: [],
            transportsActive: [],
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

    /// Build a USB-PD source advertising up to `maxW` and currently negotiating `winningW`.
    private func usbPD(maxW: Int, winningW: Int) -> PowerSource {
        let winning = PowerOption(voltageMV: 20_000, maxCurrentMA: winningW * 50, maxPowerMW: winningW * 1000)
        let max = PowerOption(voltageMV: 20_000, maxCurrentMA: maxW * 50, maxPowerMW: maxW * 1000)
        return PowerSource(
            id: 1, name: "USB-PD", parentPortType: 2, parentPortNumber: 1,
            options: [max], winning: winning
        )
    }

    private func brickID(maxW: Int, winningW: Int) -> PowerSource {
        let winning = PowerOption(voltageMV: 20_000, maxCurrentMA: winningW * 50, maxPowerMW: winningW * 1000)
        let max = PowerOption(voltageMV: 20_000, maxCurrentMA: maxW * 50, maxPowerMW: maxW * 1000)
        return PowerSource(
            id: 2, name: "Brick ID", parentPortType: 0x11, parentPortNumber: 1,
            options: [max], winning: winning
        )
    }

    private func brickIDWithoutPDOs() -> PowerSource {
        PowerSource(
            id: 2, name: "Brick ID", parentPortType: 0x11, parentPortNumber: 1,
            options: [], winning: nil
        )
    }

    /// Build a cable e-marker identity advertising the given watt rating.
    /// We pin watts via maxV/current bits: 5A @ 20V = 100W, 3A @ 20V = 60W.
    private func cableIdentity(watts: Int) -> USBPDSOP {
        // Latency = 0001 (~10 ns / ~1 m). Real cables emit a non-zero
        // latency; using 0 here would make every fixture trip the
        // reservedCableLatencyEncoding warning even though these tests
        // care only about the wattage maths.
        let validLatency: UInt32 = 1 << 13
        let cableVDO: UInt32 = {
            switch watts {
            case 100: return 0b011 | (1 << 4) | (2 << 5) | validLatency  // 5A passive
            case 60:  return 0b000 | (1 << 5)            | validLatency  // 3A USB2
            case 240: return 0b011 | (2 << 5) | (3 << 9) | validLatency  // 5A @ 50V (EPR)
            default:  fatalError("unhandled fixture wattage \(watts)")
            }
        }()
        // ID header: ufpProductType = 3 (passive cable), bits 29..27 = 011
        let idHeader: UInt32 = 0x1800_0000
        // VDO[3] holds the cable VDO; pad indices 1 and 2 with zero.
        return USBPDSOP(
            id: 2, endpoint: .sopPrime,
            parentPortType: 2, parentPortNumber: 1,
            vendorID: 0, productID: 0, bcdDevice: 0,
            vdos: [idHeader, 0, 0, cableVDO],
            specRevision: 0
        )
    }

    // MARK: - Cases

    /// Same shape as `port` but with ConnectionActive=false. Reproduces the
    /// "Charging well at 94W" bug on a disconnected MagSafe port: the
    /// PowerSource node still exposes a winning PDO with cached values, and
    /// without this guard we would still report active charging.
    private var inactiveMagSafePort: AppleHPMInterface {
        AppleHPMInterface(
            id: 1, serviceName: "Port-MagSafe 3@1", className: "AppleHPMInterfaceType11",
            portDescription: nil, portTypeDescription: "MagSafe 3", portNumber: 1,
            connectionActive: false,
            activeCable: nil, opticalCable: nil, usbActive: nil, superSpeedActive: nil,
            usbModeType: nil, usbConnectString: nil,
            transportsSupported: [], transportsActive: [], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil, rawProperties: [:]
        )
    }

    @Test("Returns nil on inactive port with stale PDO")
    func returnsNilOnInactivePortWithStalePDO() {
        let diag = ChargingDiagnostic(
            port: inactiveMagSafePort,
            sources: [usbPD(maxW: 94, winningW: 94)],
            identities: []
        )
        #expect(diag == nil)
    }

    @Test("Returns nil without USB-PD source")
    func returnsNilWithoutUSBPDSource() {
        let diag = ChargingDiagnostic(port: port, sources: [], identities: [])
        #expect(diag == nil)
    }

    @Test("Cable limits charger")
    func cableLimitsCharger() {
        // 96W charger + 60W cable -> cable is the bottleneck
        let diag = ChargingDiagnostic(
            port: port,
            sources: [usbPD(maxW: 96, winningW: 60)],
            identities: [cableIdentity(watts: 60)]
        )
        guard case .cableLimit(let cableW, let chargerW) = diag?.bottleneck else {
            Issue.record("expected .cableLimit, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(cableW == 60)
        #expect(chargerW == 96)
        #expect(diag!.isWarning)
    }

    @Test("Mac is requesting less")
    func macIsRequestingLess() {
        // 96W charger + 100W cable, but Mac is only pulling 30W (battery near full)
        let diag = ChargingDiagnostic(
            port: port,
            sources: [usbPD(maxW: 96, winningW: 30)],
            identities: [cableIdentity(watts: 100)]
        )
        guard case .macLimit(let n, let chargerW, let cableW) = diag?.bottleneck else {
            Issue.record("expected .macLimit, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(n == 30)
        #expect(chargerW == 96)
        #expect(cableW == 100)
        // The Mac drawing less than the charger/cable can do is normal
        // (battery near full / idle), so this is informational, not a warning.
        #expect(diag!.isWarning == false)
    }

    @Test("Everything matched")
    func everythingMatched() {
        // 96W charger + 100W cable + 96W winning -> .fine
        let diag = ChargingDiagnostic(
            port: port,
            sources: [usbPD(maxW: 96, winningW: 96)],
            identities: [cableIdentity(watts: 100)]
        )
        guard case .fine(let n) = diag?.bottleneck else {
            Issue.record("expected .fine, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(n == 96)
        #expect(diag!.isWarning == false)
    }

    @Test("Battery full: banner says 'not charging', not 'charging well'")
    func batteryFull_BannerSaysNotCharging() {
        // Same as "Everything matched" but the battery is full. The banner
        // is the single place that explains it (PortSummary drops its
        // redundant battery-full subtitle), so it must still appear here.
        let diag = ChargingDiagnostic(
            port: port,
            sources: [usbPD(maxW: 96, winningW: 96)],
            identities: [cableIdentity(watts: 100)],
            batteryFullyCharged: true
        )
        guard case .fine(let n) = diag?.bottleneck else {
            Issue.record("expected .fine, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(n == 96)
        #expect(diag!.isWarning == false)
        #expect(diag!.summary == "Battery full, not charging")
    }

    @Test("Battery not full: still 'charging well'")
    func batteryNotFull_ChargingWell() {
        let diag = ChargingDiagnostic(
            port: port,
            sources: [usbPD(maxW: 96, winningW: 96)],
            identities: [cableIdentity(watts: 100)],
            batteryFullyCharged: false
        )
        guard case .fine = diag?.bottleneck else {
            Issue.record("expected .fine, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(diag!.summary == "Charging well · up to 96W")
    }

    @Test("No cable e-marker, fine if matched")
    func noCableEmarker_FineIfMatched() {
        // Charger advertises 60W, Mac negotiates 60W, no cable identity.
        let diag = ChargingDiagnostic(
            port: port,
            sources: [usbPD(maxW: 60, winningW: 60)],
            identities: []
        )
        if case .fine = diag?.bottleneck { return }
        Issue.record("expected .fine without cable identity, got \(String(describing: diag?.bottleneck))")
    }

    @Test("Brick ID power source is valid for MagSafe")
    func brickIDPowerSourceIsValidForMagSafe() {
        let diag = ChargingDiagnostic(
            port: port,
            sources: [brickID(maxW: 140, winningW: 140)],
            identities: []
        )
        guard case .fine(let n) = diag?.bottleneck else {
            Issue.record("expected .fine from Brick ID source, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(n == 140)
    }

    @Test("USB-PD is preferred when both USB-PD and Brick ID present")
    func usbPDIsPreferredWhenBothPresent() {
        let diag = ChargingDiagnostic(
            port: port,
            sources: [brickID(maxW: 30, winningW: 30), usbPD(maxW: 96, winningW: 96)],
            identities: [cableIdentity(watts: 100)]
        )
        guard case .fine(let n) = diag?.bottleneck else {
            Issue.record("expected .fine from USB-PD source, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(n == 96)
    }

    @Test("System adapter watts are not used as per-port fallback")
    func systemAdapterWattsAreNotUsedAsPerPortFallback() {
        // Regression for issue #46. Per-port USB-PD source has no winning PDO
        // and no options, so we have nothing real to report. The system-wide
        // adapter wattage must NOT be substituted, because on a Mac with two
        // chargers attached it belongs to a different port.
        let diag = ChargingDiagnostic(
            port: port,
            sources: [brickIDWithoutPDOs()],
            identities: [],
            adapter: CableAdapterInfo(watts: 140, isCharging: nil, source: "AC")
        )
        #expect(diag == nil)
    }

    @Test("Zero watt winning PDO suppresses diagnostic")
    func zeroWattWinningPDOSuppressesDiagnostic() {
        // A winning PDO with maxPowerMW rounding to 0 is just as useless as
        // a missing one. Don't render "Charging well at 0W".
        let zeroWinning = PowerSource(
            id: 1, name: "USB-PD", parentPortType: 2, parentPortNumber: 1,
            options: [],
            winning: PowerOption(voltageMV: 0, maxCurrentMA: 0, maxPowerMW: 0)
        )
        let diag = ChargingDiagnostic(port: port, sources: [zeroWinning], identities: [])
        #expect(diag == nil)
    }

    @Test("Two ports with different chargers do not cross-contaminate")
    func twoPortsWithDifferentChargersDoNotCrossContaminate() {
        // Issue #46: M1 MBA with an 87W adapter on @1 and a 30W power bank on
        // @2 that briefly reports a USB-PD source without a winning PDO.
        // The diagnostic for @2 must not borrow the 87W system adapter watts.
        let port2 = AppleHPMInterface(
            id: 2, serviceName: "Port-USB-C@2", className: "AppleHPMInterfaceType10",
            portDescription: nil, portTypeDescription: "USB-C", portNumber: 2,
            connectionActive: true,
            activeCable: nil, opticalCable: nil, usbActive: nil, superSpeedActive: nil,
            usbModeType: nil, usbConnectString: nil,
            transportsSupported: [], transportsActive: [], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil, rawProperties: [:]
        )
        let bareUSBPDOnPort2 = PowerSource(
            id: 99, name: "USB-PD", parentPortType: 2, parentPortNumber: 2,
            options: [], winning: nil
        )
        let diag = ChargingDiagnostic(
            port: port2,
            sources: [bareUSBPDOnPort2],
            identities: [],
            adapter: CableAdapterInfo(watts: 87, isCharging: nil, source: "AC")
        )
        #expect(diag == nil, "port @2 must not inherit port @1's adapter wattage")
    }

    // MARK: - Edge cases (#15)

    @Test("Stale PDO at zero watts on disconnected port")
    func stalePDOAtZeroWattsOnDisconnectedPort() {
        let diag = ChargingDiagnostic(
            port: inactiveMagSafePort,
            sources: [usbPD(maxW: 0, winningW: 0)],
            identities: []
        )
        #expect(diag == nil)
    }

    @Test("Stale PDO at 240W on disconnected port")
    func stalePDOAt240WOnDisconnectedPort() {
        let diag = ChargingDiagnostic(
            port: inactiveMagSafePort,
            sources: [usbPD(maxW: 240, winningW: 240)],
            identities: []
        )
        #expect(diag == nil)
    }

    @Test("Cable 240W, charger 60W, cable is not bottleneck")
    func cable240W_Charger60W_CableIsNotBottleneck() {
        let diag = ChargingDiagnostic(
            port: port,
            sources: [usbPD(maxW: 60, winningW: 60)],
            identities: [cableIdentity(watts: 240)]
        )
        guard case .fine(let n) = diag?.bottleneck else {
            Issue.record("expected .fine, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(n == 60)
    }

    @Test("MagSafe power source uses correct port type")
    func magSafePowerSourceUsesCorrectPortType() {
        let magSafeSource = PowerSource(
            id: 1, name: "USB-PD", parentPortType: 0x11, parentPortNumber: 1,
            options: [PowerOption(voltageMV: 20_000, maxCurrentMA: 4700, maxPowerMW: 94_000)],
            winning: PowerOption(voltageMV: 20_000, maxCurrentMA: 4700, maxPowerMW: 94_000)
        )
        let magSafePort = AppleHPMInterface(
            id: 1, serviceName: "Port-MagSafe 3@1", className: "AppleHPMInterfaceType11",
            portDescription: nil, portTypeDescription: "MagSafe 3", portNumber: 1,
            connectionActive: true,
            activeCable: nil, opticalCable: nil, usbActive: nil, superSpeedActive: nil,
            usbModeType: nil, usbConnectString: nil,
            transportsSupported: [], transportsActive: [], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil, rawProperties: ["PortType": "17"]
        )
        let diag = ChargingDiagnostic(
            port: magSafePort,
            sources: [magSafeSource],
            identities: []
        )
        guard case .fine(let n) = diag?.bottleneck else {
            Issue.record("expected .fine, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(n == 94)
        #expect(magSafePort.portKey == magSafeSource.portKey)
    }

    @Test("Multiple sources picks USB-PD")
    func multipleSourcesPicksUSBPD() {
        let brickID = PowerSource(
            id: 10, name: "Brick ID", parentPortType: 2, parentPortNumber: 1,
            options: [PowerOption(voltageMV: 20_000, maxCurrentMA: 1500, maxPowerMW: 30_000)],
            winning: PowerOption(voltageMV: 20_000, maxCurrentMA: 1500, maxPowerMW: 30_000)
        )
        let usbPDSource = usbPD(maxW: 96, winningW: 96)
        // Brick ID listed first to ensure USB-PD is found regardless of order
        let diag = ChargingDiagnostic(
            port: port,
            sources: [brickID, usbPDSource],
            identities: [cableIdentity(watts: 100)]
        )
        guard case .fine(let n) = diag?.bottleneck else {
            Issue.record("expected .fine from USB-PD source, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(n == 96)
    }

    // MARK: - System adapter fallback (issue #141)

    @Test("System adapter fallback shows wattage")
    func systemAdapterFallbackShowsWattage() {
        // Issue #141: TB dock delivers power but only registers a Brick ID
        // source with no PDOs. With a single active port and a system
        // adapter reading, the fallback should produce a diagnostic.
        let wattageSource = ChargerWattageSource.resolve(
            portSources: [brickIDWithoutPDOs()],
            activePortCount: 1,
            adapter: CableAdapterInfo(watts: 96, isCharging: nil, source: "AC")
        )
        #expect(wattageSource == .systemAdapterFallback(watts: 96))

        let diag = ChargingDiagnostic(
            port: port,
            sources: [brickIDWithoutPDOs()],
            identities: [],
            wattageSource: wattageSource
        )
        guard case .chargerLimit(let w) = diag?.bottleneck else {
            Issue.record("expected .chargerLimit from adapter fallback, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(w == 96)
        #expect(diag?.summary == "System reports charger at 96W")
    }

    @Test("System adapter fallback blocked when USB-PD present")
    func systemAdapterFallbackBlockedWhenUSBPDPresent() {
        // Issue #46 regression: a USB-PD source exists (even with no
        // options), so the resolver must not fall back to the system
        // adapter. The USB-PD source owns this port's wattage.
        let bareUSBPD = PowerSource(
            id: 1, name: "USB-PD", parentPortType: 2, parentPortNumber: 1,
            options: [], winning: nil
        )
        let wattageSource = ChargerWattageSource.resolve(
            portSources: [bareUSBPD],
            activePortCount: 1,
            adapter: CableAdapterInfo(watts: 87, isCharging: nil, source: "AC")
        )
        #expect(wattageSource == .unknown)
    }

    @Test("System adapter fallback blocked when multiple ports active")
    func systemAdapterFallbackBlockedWhenMultiplePortsActive() {
        // Two active ports, both with Brick ID only. We can't tell which
        // port the system adapter reading belongs to.
        let wattageSource = ChargerWattageSource.resolve(
            portSources: [brickIDWithoutPDOs()],
            activePortCount: 2,
            adapter: CableAdapterInfo(watts: 96, isCharging: nil, source: "AC")
        )
        #expect(wattageSource == .unknown)
    }

    @Test("Resolver returns portNegotiated for normal USB-PD")
    func resolverReturnsPortNegotiatedForNormalUSBPD() {
        let wattageSource = ChargerWattageSource.resolve(
            portSources: [usbPD(maxW: 96, winningW: 96)],
            activePortCount: 1,
            adapter: nil
        )
        #expect(wattageSource == .portNegotiated(watts: 96))
    }

    // MARK: - MagSafe Brick ID vs system adapter (issue #154)

    /// A third-party 100W PD brick via Apple MagSafe: the port exposes
    /// only a low-power "Brick ID" (no winning PDO), the real contract
    /// is in the system adapter reading.
    private func lowMagSafeBrickID() -> PowerSource {
        PowerSource(
            id: 2, name: "Brick ID", parentPortType: 0x11, parentPortNumber: 1,
            options: [PowerOption(voltageMV: 5_000, maxCurrentMA: 500, maxPowerMW: 2_500)],
            winning: nil
        )
    }

    @Test("MagSafe Brick ID defers to higher system adapter wattage")
    func magSafeBrickIDPrefersSystemAdapter() {
        let wattageSource = ChargerWattageSource.resolve(
            portSources: [lowMagSafeBrickID()],
            activePortCount: 1,
            adapter: CableAdapterInfo(watts: 100, isCharging: nil, source: "AC")
        )
        #expect(wattageSource == .systemAdapterFallback(watts: 100))
    }

    @Test("Brick ID kept when system adapter is not higher")
    func brickIDKeptWhenAdapterNotHigher() {
        // A legitimate high-wattage Brick ID equal to the adapter reading
        // must stay port-negotiated, not get rewritten as a fallback.
        let wattageSource = ChargerWattageSource.resolve(
            portSources: [brickID(maxW: 100, winningW: 100)],
            activePortCount: 1,
            adapter: CableAdapterInfo(watts: 100, isCharging: nil, source: "AC")
        )
        #expect(wattageSource == .portNegotiated(watts: 100))
    }

    @Test("Brick ID divert blocked with multiple active ports")
    func brickIDDivertBlockedWhenMultiplePortsActive() {
        // #46 protection: with two active ports we can't attribute the
        // system adapter reading, so the low Brick ID stands.
        let wattageSource = ChargerWattageSource.resolve(
            portSources: [lowMagSafeBrickID()],
            activePortCount: 2,
            adapter: CableAdapterInfo(watts: 100, isCharging: nil, source: "AC")
        )
        #expect(wattageSource == .portNegotiated(watts: 3))
    }

    @Test("Third-party MagSafe brick reports adapter wattage, not 3W")
    func magSafeThirdPartyBrickShowsAdapterWattage() {
        // Before the fix this rendered "Charger advertises up to 3W /
        // Negotiation hasn't completed yet". It must now read 100W.
        let adapter = CableAdapterInfo(watts: 100, isCharging: nil, source: "AC")
        let wattageSource = ChargerWattageSource.resolve(
            portSources: [lowMagSafeBrickID()],
            activePortCount: 1,
            adapter: adapter
        )
        #expect(wattageSource == .systemAdapterFallback(watts: 100))

        let diag = ChargingDiagnostic(
            port: port,
            sources: [lowMagSafeBrickID()],
            identities: [],
            adapter: adapter,
            wattageSource: wattageSource
        )
        guard case .chargerLimit(let w) = diag?.bottleneck else {
            Issue.record("expected .chargerLimit from adapter fallback, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(w == 100)
        #expect(diag?.summary == "System reports charger at 100W")
    }

    // MARK: - Standby charger (issue #264)

    /// A USB-PD charger that is connected and advertising, but has no
    /// winning (negotiated) PDO because the Mac is drawing from elsewhere.
    private func usbPDNoContract(maxW: Int) -> PowerSource {
        PowerSource(
            id: 1, name: "USB-PD", parentPortType: 2, parentPortNumber: 1,
            options: [PowerOption(voltageMV: 20_000, maxCurrentMA: maxW * 50, maxPowerMW: maxW * 1000)],
            winning: nil
        )
    }

    @Test("Second charger reads as standby, not stuck negotiating")
    func secondChargerReadsAsStandby() {
        // Two chargers attached: this 60W one has no contract because the
        // Mac chose the other port. With the cross-port flag set it must
        // read as standby (calm, no warning), not "negotiation incomplete".
        let diag = ChargingDiagnostic(
            port: port,
            sources: [usbPDNoContract(maxW: 60)],
            identities: [],
            anotherPortActivelyCharging: true
        )
        guard case .standbyCharger(let w) = diag?.bottleneck else {
            Issue.record("expected .standbyCharger, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(w == 60)
        #expect(diag!.isWarning == false)
        #expect(diag!.summary == "Charger on standby")
    }

    @Test("Single charger with no contract still reads as negotiating")
    func singleChargerNoContractStillNegotiating() {
        // Same inputs, but no other port is charging. This is the genuine
        // "negotiation hasn't completed" case and must be preserved.
        let diag = ChargingDiagnostic(
            port: port,
            sources: [usbPDNoContract(maxW: 60)],
            identities: [],
            anotherPortActivelyCharging: false
        )
        guard case .chargerLimit(let w) = diag?.bottleneck else {
            Issue.record("expected .chargerLimit, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(w == 60)
        // "Negotiation hasn't completed yet" is a transient state, not a
        // fault, so it is informational rather than a warning.
        #expect(diag!.isWarning == false)
        #expect(diag!.detail == "Negotiation hasn't completed yet.")
    }

    @Test("hasLiveChargingContract reflects a winning PDO")
    func hasLiveChargingContractReflectsWinningPDO() {
        #expect(PowerSource.hasLiveChargingContract(in: [usbPD(maxW: 96, winningW: 96)]))
        #expect(PowerSource.hasLiveChargingContract(in: [usbPDNoContract(maxW: 60)]) == false)
        #expect(PowerSource.hasLiveChargingContract(in: []) == false)
    }

    // MARK: - Charge hold (issue #319)

    @Test("Charge hold: batteryIsCharging=false shows on-hold summary, not a warning")
    func chargeHoldIsNotAWarning() {
        // batteryIsCharging=false with a live contract is the charge-hold state:
        // macOS has a charge limit or OBC active. The bottleneck stays .fine,
        // so it must NOT be flagged as a warning.
        let diag = ChargingDiagnostic(
            port: port,
            sources: [usbPD(maxW: 96, winningW: 96)],
            identities: [cableIdentity(watts: 100)],
            batteryIsCharging: false
        )
        #expect(diag != nil)
        #expect(diag!.isWarning == false)
        #expect(diag!.summary == "Plugged in, charging on hold")
    }

    @Test("Charge hold: batteryFullyCharged=true takes precedence over batteryIsCharging=false")
    func batteryFullyChargedTakesPrecedenceOverChargeHold() {
        // When the battery is fully charged, that message wins even if IsCharging is also false.
        let diag = ChargingDiagnostic(
            port: port,
            sources: [usbPD(maxW: 96, winningW: 96)],
            identities: [cableIdentity(watts: 100)],
            batteryFullyCharged: true,
            batteryIsCharging: false
        )
        #expect(diag != nil)
        #expect(diag!.summary == "Battery full, not charging")
    }

    @Test("Charge hold: batteryIsCharging=nil keeps existing charging-well behaviour")
    func chargeHoldNilKeepsChargingWell() {
        // When batteryIsCharging is nil (desktop or unknown), summary stays "Charging well".
        let diag = ChargingDiagnostic(
            port: port,
            sources: [usbPD(maxW: 96, winningW: 96)],
            identities: [cableIdentity(watts: 100)],
            batteryIsCharging: nil
        )
        #expect(diag != nil)
        #expect(diag!.summary.contains("Charging well"))
    }
}
