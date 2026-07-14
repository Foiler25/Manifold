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
public import Foundation

/// Compares charger output, cable rating, and currently negotiated PDO to
/// identify the bottleneck — the "why is my Mac charging slowly?" answer.
public struct ChargingDiagnostic {
    public enum Bottleneck: Hashable {
        case noCharger
        case chargerLimit(chargerW: Int)
        case cableLimit(cableW: Int, chargerW: Int)
        case macLimit(negotiatedW: Int, chargerW: Int, cableW: Int?)
        case fine(negotiatedW: Int)
        /// A charger is connected but the Mac is drawing power from a
        /// different port. macOS charges from one port at a time, so this
        /// one sits idle until the other is unplugged. Not a fault.
        case standbyCharger(chargerW: Int)
    }

    public let bottleneck: Bottleneck
    public let summary: String
    public let detail: String
    /// Charger ceiling in watts, available for display regardless of bottleneck.
    public let chargerW: Int?
    /// Cable rating in watts from the e-marker, available for display regardless of bottleneck.
    public let cableW: Int?

    public var isWarning: Bool {
        switch bottleneck {
        // Only a cable rated below the charger is an actionable charging
        // fault. `macLimit` ("the Mac is asking for less, this is normal")
        // and `chargerLimit` ("negotiation hasn't completed yet" / "wattage
        // is from the system reading") describe benign or transient states,
        // so they are informational, not warnings. `fine` / `standbyCharger`
        // are also fine.
        case .cableLimit: return true
        default: return false
        }
    }
}

extension ChargingDiagnostic {
    public init?(
        port: AppleHPMInterface,
        sources: [PowerSource],
        identities: [USBPDSOP],
        adapter: CableAdapterInfo? = nil,
        wattageSource: ChargerWattageSource = .unknown,
        batteryFullyCharged: Bool? = nil,
        batteryIsCharging: Bool? = nil,
        anotherPortActivelyCharging: Bool = false
    ) {
        guard let source = PowerSource.preferredChargingSource(in: sources) else {
            return nil
        }
        // MagSafe (and at least some USB-C ports) keep the last negotiated
        // PDO around as cached data even after the charger is unplugged, so
        // a port that is actually idle still looks like it is drawing ~94W.
        // Gate on the port-level ConnectionActive flag instead of trusting
        // the PowerSource node alone.
        guard port.connectionActive == true else { return nil }

        // Adapter wattage resolution moved to ChargerWattageSource.resolve;
        // parameter kept for API compatibility.
        _ = adapter

        let chargerMaxW: Int
        let isAdapterFallback: Bool
        switch wattageSource {
        case .portNegotiated(let w):
            chargerMaxW = w
            isAdapterFallback = false
        case .systemAdapterFallback(let w):
            chargerMaxW = w
            isAdapterFallback = true
        case .unknown:
            chargerMaxW = Int((Double(source.maxPowerMW) / 1000).rounded())
            isAdapterFallback = false
        }

        let negotiatedW = source.winning.map { Int((Double($0.maxPowerMW) / 1000).rounded()) }

        if chargerMaxW <= 0 && (negotiatedW ?? 0) <= 0 {
            return nil
        }

        let cableMaxW: Int? = identities
            .first(where: { $0.endpoint == .sopPrime || $0.endpoint == .sopDoublePrime })?
            .cableVDO?.maxWatts

        self.chargerW = chargerMaxW > 0 ? chargerMaxW : nil
        self.cableW = cableMaxW

        // Order of suspicion:
        // 1. If cable rated below charger, cable is the bottleneck.
        // 2. If negotiated below both, the Mac (or current state) limits.
        // 3. Otherwise charger is the ceiling.
        if let cableW = cableMaxW, cableW < chargerMaxW {
            self.bottleneck = .cableLimit(cableW: cableW, chargerW: chargerMaxW)
            self.summary = String(localized: "Cable is limiting charging speed", bundle: _coreLocalizedBundle)
            self.detail = String(localized: "Charger can deliver up to \(chargerMaxW)W, but this cable is only rated to carry \(cableW)W. Replace the cable to charge faster.", bundle: _coreLocalizedBundle)
        } else if let n = negotiatedW, n < chargerMaxW - max(5, chargerMaxW / 10),
                  (cableMaxW.map { n < $0 - max(5, $0 / 10) } ?? true) {
            self.bottleneck = .macLimit(negotiatedW: n, chargerW: chargerMaxW, cableW: cableMaxW)
            self.summary = String(localized: "Charging at \(n)W (charger can do up to \(chargerMaxW)W)", bundle: _coreLocalizedBundle)
            self.detail = String(localized: "Both the charger and cable can do more, but the Mac is currently asking for less. This is normal once the battery is mostly full, or when the system is idle.", bundle: _coreLocalizedBundle)
        } else if let n = negotiatedW {
            self.bottleneck = .fine(negotiatedW: n)
            if batteryFullyCharged == true {
                // The battery-full state is shown here (the banner), not
                // in the PortSummary subtitle, so the two don't repeat.
                self.summary = String(localized: "Battery full, not charging", bundle: _coreLocalizedBundle)
                self.detail = String(localized: "Charger and cable are fine. The Mac will draw up to \(n)W when it needs to.", bundle: _coreLocalizedBundle)
            } else if batteryIsCharging == false {
                // Charger is connected and negotiated a contract, but the
                // battery is not accepting charge. macOS does this when a
                // charge limit is active or Optimized Battery Charging has
                // paused charging. FullyCharged is still false, so the
                // battery-full branch above does not catch this.
                self.summary = String(localized: "Plugged in, charging on hold", bundle: _coreLocalizedBundle)
                self.detail = String(localized: "Charger and cable are fine. macOS has paused charging for now, usually a battery charge limit or Optimized Battery Charging. The Mac still draws power from the charger.", bundle: _coreLocalizedBundle)
            } else {
                self.summary = String(localized: "Charging well · up to \(n)W", bundle: _coreLocalizedBundle)
                self.detail = String(localized: "Charger and cable are well-matched. The Mac draws what it needs moment to moment, up to this limit.", bundle: _coreLocalizedBundle)
            }
        } else if anotherPortActivelyCharging {
            // No contract on this port, but another port is actively
            // charging. The Mac draws from one charger at a time, so this
            // one is on standby, not stuck mid-negotiation. See issue #264.
            self.bottleneck = .standbyCharger(chargerW: chargerMaxW)
            self.summary = String(localized: "Charger on standby", bundle: _coreLocalizedBundle)
            self.detail = String(localized: "Another charger is powering the Mac right now. macOS draws from one charger at a time, so this charger stays on standby until the other is unplugged.", bundle: _coreLocalizedBundle)
        } else if isAdapterFallback {
            self.bottleneck = .chargerLimit(chargerW: chargerMaxW)
            self.summary = String(localized: "System reports charger at \(chargerMaxW)W", bundle: _coreLocalizedBundle)
            self.detail = String(localized: "Per-port negotiation data is not available. Wattage is from the system-wide adapter reading.", bundle: _coreLocalizedBundle)
        } else {
            self.bottleneck = .chargerLimit(chargerW: chargerMaxW)
            self.summary = String(localized: "Charger advertises up to \(chargerMaxW)W", bundle: _coreLocalizedBundle)
            self.detail = String(localized: "Negotiation hasn't completed yet.", bundle: _coreLocalizedBundle)
        }
    }
}
