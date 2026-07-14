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

public struct PowerSample: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let systemVoltageIn: Int
    public let systemCurrentIn: Int
    public let systemPowerIn: Int

    public init(timestamp: Date, systemVoltageIn: Int, systemCurrentIn: Int, systemPowerIn: Int) {
        self.timestamp = timestamp
        self.systemVoltageIn = systemVoltageIn
        self.systemCurrentIn = systemCurrentIn
        self.systemPowerIn = systemPowerIn
    }
}

public struct PortPowerSample: Codable, Sendable, Equatable {
    public let portIndex: Int
    public let portKey: String
    public let current: Int
    public let watts: Int
    public let configuredVoltage: Int
    public let configuredCurrent: Int
    public let adapterVoltage: Int
    public let vconnCurrent: Int
    public let vconnPower: Int
    /// Smoothed power reading (centiwatts).
    public let filteredPower: Int
    /// PD contract negotiated power (mW).
    public let pdPowerMW: Int
    /// Maximum VConn current the cable claimed (mA).
    public let vconnMaxCurrent: Int
    /// Lifetime accumulated energy through this port.
    public let accumulatedPower: Int
    /// Number of energy measurement samples taken.
    public let accumulatorCount: Int
    /// Number of energy measurement errors.
    public let accumulatorErrorCount: Int
    /// Lifetime VConn energy accumulated.
    public let vconnAccumulatedPower: Int
    /// VConn energy sample count.
    public let vconnAccumulatorCount: Int
    /// VConn energy measurement errors.
    public let vconnAccumulatorErrorCount: Int
    /// Number of liquid detection collision events on this port.
    public let numLDCMCollisions: Int
    /// Reserved sleep power for USB devices (mW).
    public let usbSleepPoolPowerMW: Int
    /// Reserved wake power for USB devices (mW).
    public let usbWakePoolPowerMW: Int
    /// Power delivery state.
    public let powerState: Int
    /// Port type identifier.
    public let portType: Int
    // True when the sample came from PortControllerInfo (contracted/port-max
    // only, no live per-port metering). Voltage is unrecoverable in this
    // path, so configuredVoltage stays 0 and the UI shows the honest
    // contracted-max card instead of a synthesized live reading.
    public let isContractedFallback: Bool
    // True when the sample came from the SMC per-port channels (desktop Macs,
    // which have no battery controller and so no PortControllerInfo /
    // PowerOutDetails). This is a live measured reading tied to the port by
    // controller UUID, so it is trusted as proof the port is live.
    public let isSMCMeasured: Bool

    public init(
        portIndex: Int,
        portKey: String = "",
        current: Int,
        watts: Int,
        configuredVoltage: Int,
        configuredCurrent: Int,
        adapterVoltage: Int,
        vconnCurrent: Int,
        vconnPower: Int,
        filteredPower: Int = 0,
        pdPowerMW: Int = 0,
        vconnMaxCurrent: Int = 0,
        accumulatedPower: Int = 0,
        accumulatorCount: Int = 0,
        accumulatorErrorCount: Int = 0,
        vconnAccumulatedPower: Int = 0,
        vconnAccumulatorCount: Int = 0,
        vconnAccumulatorErrorCount: Int = 0,
        numLDCMCollisions: Int = 0,
        usbSleepPoolPowerMW: Int = 0,
        usbWakePoolPowerMW: Int = 0,
        powerState: Int = 0,
        portType: Int = 0,
        isContractedFallback: Bool = false,
        isSMCMeasured: Bool = false
    ) {
        self.portIndex = portIndex
        self.portKey = portKey
        self.current = current
        self.watts = watts
        self.configuredVoltage = configuredVoltage
        self.configuredCurrent = configuredCurrent
        self.adapterVoltage = adapterVoltage
        self.vconnCurrent = vconnCurrent
        self.vconnPower = vconnPower
        self.filteredPower = filteredPower
        self.pdPowerMW = pdPowerMW
        self.vconnMaxCurrent = vconnMaxCurrent
        self.accumulatedPower = accumulatedPower
        self.accumulatorCount = accumulatorCount
        self.accumulatorErrorCount = accumulatorErrorCount
        self.vconnAccumulatedPower = vconnAccumulatedPower
        self.vconnAccumulatorCount = vconnAccumulatorCount
        self.vconnAccumulatorErrorCount = vconnAccumulatorErrorCount
        self.numLDCMCollisions = numLDCMCollisions
        self.usbSleepPoolPowerMW = usbSleepPoolPowerMW
        self.usbWakePoolPowerMW = usbWakePoolPowerMW
        self.powerState = powerState
        self.portType = portType
        self.isContractedFallback = isContractedFallback
        self.isSMCMeasured = isSMCMeasured
    }

    private enum CodingKeys: String, CodingKey {
        case portIndex, portKey, current, watts, configuredVoltage
        case configuredCurrent, adapterVoltage, vconnCurrent, vconnPower
        case filteredPower, pdPowerMW, vconnMaxCurrent
        case accumulatedPower, accumulatorCount, accumulatorErrorCount
        case vconnAccumulatedPower, vconnAccumulatorCount, vconnAccumulatorErrorCount
        case numLDCMCollisions, usbSleepPoolPowerMW, usbWakePoolPowerMW
        case powerState, portType
        case isContractedFallback
        case isSMCMeasured
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        portIndex = try c.decode(Int.self, forKey: .portIndex)
        portKey = try c.decode(String.self, forKey: .portKey)
        current = try c.decode(Int.self, forKey: .current)
        watts = try c.decode(Int.self, forKey: .watts)
        configuredVoltage = try c.decode(Int.self, forKey: .configuredVoltage)
        configuredCurrent = try c.decode(Int.self, forKey: .configuredCurrent)
        adapterVoltage = try c.decode(Int.self, forKey: .adapterVoltage)
        vconnCurrent = try c.decode(Int.self, forKey: .vconnCurrent)
        vconnPower = try c.decode(Int.self, forKey: .vconnPower)
        filteredPower = try c.decodeIfPresent(Int.self, forKey: .filteredPower) ?? 0
        pdPowerMW = try c.decodeIfPresent(Int.self, forKey: .pdPowerMW) ?? 0
        vconnMaxCurrent = try c.decodeIfPresent(Int.self, forKey: .vconnMaxCurrent) ?? 0
        accumulatedPower = try c.decodeIfPresent(Int.self, forKey: .accumulatedPower) ?? 0
        accumulatorCount = try c.decodeIfPresent(Int.self, forKey: .accumulatorCount) ?? 0
        accumulatorErrorCount = try c.decodeIfPresent(Int.self, forKey: .accumulatorErrorCount) ?? 0
        vconnAccumulatedPower = try c.decodeIfPresent(Int.self, forKey: .vconnAccumulatedPower) ?? 0
        vconnAccumulatorCount = try c.decodeIfPresent(Int.self, forKey: .vconnAccumulatorCount) ?? 0
        vconnAccumulatorErrorCount = try c.decodeIfPresent(Int.self, forKey: .vconnAccumulatorErrorCount) ?? 0
        numLDCMCollisions = try c.decodeIfPresent(Int.self, forKey: .numLDCMCollisions) ?? 0
        usbSleepPoolPowerMW = try c.decodeIfPresent(Int.self, forKey: .usbSleepPoolPowerMW) ?? 0
        usbWakePoolPowerMW = try c.decodeIfPresent(Int.self, forKey: .usbWakePoolPowerMW) ?? 0
        powerState = try c.decodeIfPresent(Int.self, forKey: .powerState) ?? 0
        portType = try c.decodeIfPresent(Int.self, forKey: .portType) ?? 0
        isContractedFallback = try c.decodeIfPresent(Bool.self, forKey: .isContractedFallback) ?? false
        isSMCMeasured = try c.decodeIfPresent(Bool.self, forKey: .isSMCMeasured) ?? false
    }
}

public struct CableResistanceEstimate: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case insufficient
        case converging
        case stable
        case unreliable
    }

    public let milliohms: Double
    public let sampleCount: Int
    public let rSquared: Double
    public let status: Status

    public init(milliohms: Double, sampleCount: Int, rSquared: Double, status: Status) {
        self.milliohms = milliohms
        self.sampleCount = sampleCount
        self.rSquared = rSquared
        self.status = status
    }

    /// How a stable resistance reading rates against the USB-C spec budget.
    public enum Tier: String, Sendable {
        /// Comfortably within the spec budget.
        case good
        /// Within the budget but approaching the ceiling.
        case marginal
        /// Over the spec budget: out of spec for this cable's rating.
        /// (A reading exactly at the budget is `.marginal`; only strictly
        /// over is `.high`.)
        case high
    }

    /// Classify the resistance against the USB Type-C IR-drop budget
    /// (spec §4.4.1), which the estimate measures as the VBUS+GND loop (the
    /// Mac can only sense VBUS relative to its own ground, so its reading
    /// includes the GND return drop). The budget is current-rated, so a 5 A
    /// cable's ceiling is tighter than a 3 A's:
    ///
    /// - 5 A loop budget ≈ 150 mΩ → Good < 100, Marginal 100–150, High > 150.
    /// - 3 A loop budget ≈ 250 mΩ → Good < 165, Marginal 165–250, High > 250.
    ///
    /// Full working: `research/cable-resistance-thresholds.md`.
    ///
    /// - Parameter ratedFiveA: whether the cable is a 5 A-class cable. Pass
    ///   `true` only when known (e.g. the negotiated contract exceeded 3 A,
    ///   which only a 5 A-rated cable allows). Default `false` applies the
    ///   looser 3 A budget so a lightly-loaded 5 A cable is never over-flagged.
    /// - Returns: the tier, or `nil` when the estimate isn't `stable` (no
    ///   trustworthy reading yet).
    public func tier(ratedFiveA: Bool) -> Tier? {
        guard status == .stable else { return nil }
        let goodBelow = ratedFiveA ? 100.0 : 165.0
        let budget = ratedFiveA ? 150.0 : 250.0
        if milliohms < goodBelow { return .good }
        if milliohms <= budget { return .marginal }
        return .high
    }
}

public struct PowerMonitorSnapshot: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let systemSample: PowerSample
    public let portSamples: [PortPowerSample]
    public let resistanceEstimate: CableResistanceEstimate?
    /// True when an external power source (a charger) is connected. Drives the
    /// "Charger" vs "Battery" indicator and chart colour. Defaults to true so a
    /// desktop Mac (no battery) reads as plugged in.
    public let externalConnected: Bool
    /// True when a battery is present (a laptop). Desktops report false, so they
    /// never show "on battery".
    public let batteryInstalled: Bool

    /// Battery discharge, used when on battery so the card keeps tracking
    /// voltage/current/power instead of going blank (there is no power *in*
    /// from a charger then). All magnitudes (mV / mA / mW), already abs'd.
    public let batteryVoltageMV: Int
    public let batteryCurrentMA: Int
    public let batteryPowerMW: Int

    /// True when at least one port has a struck power contract (a winning
    /// `IOPortFeaturePowerSource`). Carried in the snapshot so the System Power
    /// card decides "negotiating vs waiting for live data" from one atomic
    /// source, not a second watcher on a different clock.
    public let hasContract: Bool

    /// True when this Mac can read per-port power from the SMC (a desktop with
    /// the M3+ controller UUID key and a readable SMC). Distinguishes "this Mac
    /// can meter but nothing is drawing" (idle ports show a clean no-data state)
    /// from "this Mac cannot meter per-port at all" (M1/M2, Mac Pro, SMC open
    /// refused), which the UI states plainly instead. Always false on laptops,
    /// where per-port comes from the battery controller, not the SMC.
    public let perPortMeteringSupported: Bool

    /// On battery means a battery is installed and no charger is connected.
    public var onBattery: Bool { batteryInstalled && !externalConnected }

    /// What the System Power card displays: the charger input when plugged in,
    /// the battery discharge when on battery. One set of numbers tracks the
    /// active source.
    public var activeVoltageMV: Int { onBattery ? batteryVoltageMV : systemSample.systemVoltageIn }
    public var activeCurrentMA: Int { onBattery ? batteryCurrentMA : systemSample.systemCurrentIn }
    public var activePowerMW: Int { onBattery ? batteryPowerMW : systemSample.systemPowerIn }

    public init(
        timestamp: Date,
        systemSample: PowerSample,
        portSamples: [PortPowerSample],
        resistanceEstimate: CableResistanceEstimate?,
        externalConnected: Bool = true,
        batteryInstalled: Bool = false,
        batteryVoltageMV: Int = 0,
        batteryCurrentMA: Int = 0,
        batteryPowerMW: Int = 0,
        hasContract: Bool = false,
        perPortMeteringSupported: Bool = false
    ) {
        self.timestamp = timestamp
        self.systemSample = systemSample
        self.portSamples = portSamples
        self.resistanceEstimate = resistanceEstimate
        self.externalConnected = externalConnected
        self.batteryInstalled = batteryInstalled
        self.batteryVoltageMV = batteryVoltageMV
        self.batteryCurrentMA = batteryCurrentMA
        self.batteryPowerMW = batteryPowerMW
        self.hasContract = hasContract
        self.perPortMeteringSupported = perPortMeteringSupported
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, systemSample, portSamples, resistanceEstimate
        case externalConnected, batteryInstalled
        case batteryVoltageMV, batteryCurrentMA, batteryPowerMW
        case hasContract, perPortMeteringSupported
    }

    // Custom decode (encode stays synthesised) so a snapshot encoded by an
    // older build, missing newer keys, decodes with sensible defaults instead
    // of throwing. Same defensive pattern as `PortPowerSample`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        systemSample = try c.decode(PowerSample.self, forKey: .systemSample)
        portSamples = try c.decode([PortPowerSample].self, forKey: .portSamples)
        resistanceEstimate = try c.decodeIfPresent(CableResistanceEstimate.self, forKey: .resistanceEstimate)
        externalConnected = try c.decodeIfPresent(Bool.self, forKey: .externalConnected) ?? true
        batteryInstalled = try c.decodeIfPresent(Bool.self, forKey: .batteryInstalled) ?? false
        batteryVoltageMV = try c.decodeIfPresent(Int.self, forKey: .batteryVoltageMV) ?? 0
        batteryCurrentMA = try c.decodeIfPresent(Int.self, forKey: .batteryCurrentMA) ?? 0
        batteryPowerMW = try c.decodeIfPresent(Int.self, forKey: .batteryPowerMW) ?? 0
        hasContract = try c.decodeIfPresent(Bool.self, forKey: .hasContract) ?? false
        perPortMeteringSupported = try c.decodeIfPresent(Bool.self, forKey: .perPortMeteringSupported) ?? false
    }
}
