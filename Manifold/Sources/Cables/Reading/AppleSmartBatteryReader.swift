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
import IOKit

/// Reads AppleSmartBattery properties from IOKit. Desktop Macs have no
/// AppleSmartBattery service at all, or report BatteryInstalled = false.
public enum AppleSmartBatteryReader {
    public struct Result {
        public let isDesktopMac: Bool
        public let federatedIdentities: [FederatedIdentity]
        public let battery: AppleSmartBattery?
    }

    public static func read() -> Result {
        let matching = IOServiceMatching("AppleSmartBattery")
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return Result(isDesktopMac: true, federatedIdentities: [], battery: nil)
        }
        defer { IOObjectRelease(iter) }

        let service = IOIteratorNext(iter)
        guard service != 0 else {
            return Result(isDesktopMac: true, federatedIdentities: [], battery: nil)
        }
        defer { IOObjectRelease(service) }

        // Read keys individually rather than fetching the full property
        // dictionary. The bulk fetch (IORegistryEntryCreateCFProperties)
        // can abort the process from inside IOCFUnserializeBinary when
        // the kernel returns a malformed serialised properties blob,
        // typically when the service is being torn down mid-read. The
        // per-key call has no such failure path. See issue #181.
        func read(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        let batteryInstalled = boolVal(read("BatteryInstalled"))
        if !batteryInstalled {
            return Result(isDesktopMac: true, federatedIdentities: [], battery: nil)
        }

        let fedDetails = parseFedDetails(read("FedDetails"))
        let battery = parseBattery(read, federatedIdentities: fedDetails)
        return Result(isDesktopMac: false, federatedIdentities: fedDetails, battery: battery)
    }

    private static func parseBattery(_ read: (String) -> Any?, federatedIdentities: [FederatedIdentity]) -> AppleSmartBattery {
        AppleSmartBattery(
            batteryInstalled: true,
            deviceName: (read("DeviceName") as? String) ?? "",
            serial: (read("Serial") as? String) ?? "",
            designCapacity: intVal(read("DesignCapacity")),
            nominalChargeCapacity: intVal(read("NominalChargeCapacity")),
            designCycleCount: intVal(read("DesignCycleCount9C")),
            gasGaugeFirmwareVersion: intVal(read("GasGaugeFirmwareVersion")),
            currentCapacity: intVal(read("CurrentCapacity")),
            maxCapacity: intVal(read("MaxCapacity")),
            voltage: intVal(read("Voltage")),
            amperage: intVal(read("Amperage")),
            instantAmperage: intVal(read("InstantAmperage")),
            temperature: intVal(read("Temperature")),
            virtualTemperature: intVal(read("VirtualTemperature")),
            cycleCount: intVal(read("CycleCount")),
            isCharging: boolVal(read("IsCharging")),
            fullyCharged: boolVal(read("FullyCharged")),
            externalConnected: boolVal(read("ExternalConnected")),
            externalChargeCapable: boolVal(read("ExternalChargeCapable")),
            atCriticalLevel: boolVal(read("AtCriticalLevel")),
            timeRemaining: intVal(read("TimeRemaining")),
            avgTimeToFull: intVal(read("AvgTimeToFull")),
            avgTimeToEmpty: intVal(read("AvgTimeToEmpty")),
            rawCurrentCapacity: intVal(read("AppleRawCurrentCapacity")),
            rawMaxCapacity: intVal(read("AppleRawMaxCapacity")),
            rawBatteryVoltage: intVal(read("AppleRawBatteryVoltage")),
            rawExternalConnected: boolVal(read("AppleRawExternalConnected")),
            chargerConfiguration: intVal(read("ChargerConfiguration")),
            packReserve: intVal(read("PackReserve")),
            postChargeWaitSeconds: intVal(read("PostChargeWaitSeconds")),
            postDischargeWaitSeconds: intVal(read("PostDischargeWaitSeconds")),
            batteryInvalidWakeSeconds: intVal(read("BatteryInvalidWakeSeconds")),
            bootVoltage: intVal(read("BootVoltage")),
            permanentFailureStatus: intVal(read("PermanentFailureStatus")),
            batteryCellDisconnectCount: intVal(read("BatteryCellDisconnectCount")),
            updateTime: intVal(read("UpdateTime")),
            fullPathUpdated: intVal(read("FullPathUpdated")),
            bootPathUpdated: intVal(read("BootPathUpdated")),
            userVisiblePathUpdated: intVal(read("UserVisiblePathUpdated")),
            chargerData: parseChargerData(read("ChargerData")),
            carrierMode: parseCarrierMode(read("CarrierMode")),
            batteryShutdownReason: parseShutdownReason(read("BatteryShutdownReason")),
            adapterDetails: parseAdapterDetails(read("AdapterDetails")),
            powerTelemetryData: parsePowerTelemetry(read("PowerTelemetryData")),
            portControllerInfo: parsePortControllerInfo(read("PortControllerInfo")),
            federatedIdentities: federatedIdentities
        )
    }

    // MARK: - Sub-parsers

    private static func parseChargerData(_ value: Any?) -> ChargerData? {
        guard let d = value as? [String: Any] else { return nil }
        return ChargerData(
            chargingVoltage: intVal(d["ChargingVoltage"]),
            chargingCurrent: intVal(d["ChargingCurrent"]),
            notChargingReason: intVal(d["NotChargingReason"]),
            slowChargingReason: intVal(d["SlowChargingReason"]),
            chargerID: intVal(d["ChargerID"]),
            chargerResetCounter: intVal(d["ChargerResetCounter"]),
            chargerInhibitReason: intVal(d["ChargerInhibitReason"]),
            timeChargingThermallyLimited: intVal(d["TimeChargingThermallyLimited"]),
            vacVoltageLimit: intVal(d["VacVoltageLimit"])
        )
    }

    private static func parseCarrierMode(_ value: Any?) -> CarrierMode? {
        guard let d = value as? [String: Any] else { return nil }
        return CarrierMode(
            lowVoltage: intVal(d["CarrierModeLowVoltage"]),
            highVoltage: intVal(d["CarrierModeHighVoltage"]),
            status: intVal(d["CarrierModeStatus"])
        )
    }

    private static func parseShutdownReason(_ value: Any?) -> BatteryShutdownReason? {
        guard let d = value as? [String: Any] else { return nil }
        return BatteryShutdownReason(
            shutDownVoltage: intVal(d["ShutDownVoltage"]),
            shutDownTemperature: intVal(d["ShutDownTemperature"]),
            shutDownTimestamp: intVal(d["ShutDownTimestamp"]),
            shutDownFullChargeCapacity: intVal(d["ShutDownFullChargeCapacity"]),
            shutDownNominalChargeCapacity: intVal(d["ShutDownNominalChargeCapacity"]),
            shutDownRemainingCapacity: intVal(d["ShutDownRemainingCapacity"]),
            shutDownPassedCharge: intVal(d["ShutDownPassedCharge"]),
            dataError: intVal(d["ShutDownDataError"]),
            criticalFlags: intVal(d["ShutdownDataCriticalFlagsKey"])
        )
    }

    private static func parseAdapterDetails(_ value: Any?) -> CableAdapterInfo? {
        guard let d = value as? [String: Any] else { return nil }
        let watts = (d["Watts"] as? NSNumber)?.intValue
        let hvcMenu = parseHVCMenu(d["UsbHvcMenu"])
        return CableAdapterInfo(
            watts: watts,
            isCharging: nil,
            source: nil,
            voltageMV: (d["AdapterVoltage"] as? NSNumber)?.intValue,
            currentMA: (d["Current"] as? NSNumber)?.intValue,
            adapterDescription: d["Description"] as? String,
            powerTier: (d["AdapterPowerTier"] as? NSNumber)?.intValue,
            isWireless: (d["IsWireless"] as? NSNumber)?.boolValue,
            hvcMenu: hvcMenu,
            hvcActiveIndex: (d["UsbHvcHvcIndex"] as? NSNumber)?.intValue,
            familyCode: (d["FamilyCode"] as? NSNumber)?.intValue,
            adapterID: (d["AdapterID"] as? NSNumber)?.intValue,
            pmuConfiguration: (d["PMUConfiguration"] as? NSNumber)?.intValue,
            manufacturer: nonEmptyString(d["Manufacturer"]),
            name: nonEmptyString(d["Name"]),
            model: nonEmptyString(d["Model"])
        )
    }

    /// Returns the value as a non-empty trimmed string, or nil when the
    /// value is missing or only whitespace. Used so the AdapterDetails
    /// identity fields (Manufacturer, Name, Model) are either present-
    /// and-meaningful or nil, with no in-between empty case.
    ///
    /// Accepts both `String` and `NSNumber`. IOKit's AdapterDetails dict
    /// has stored `Model` as a string ("0x7019") in every observed
    /// sample, but the dict is `[String: Any]` and a future macOS or a
    /// different brick could return it as a number; recover that case
    /// rather than silently dropping it.
    private static func nonEmptyString(_ value: Any?) -> String? {
        let raw: String?
        if let s = value as? String {
            raw = s
        } else if let n = value as? NSNumber {
            raw = n.stringValue
        } else {
            raw = nil
        }
        guard let s = raw else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseHVCMenu(_ value: Any?) -> [AdapterHVCEntry] {
        guard let arr = value as? [[String: Any]] else { return [] }
        return arr.compactMap { entry in
            guard let mv = (entry["MaxVoltage"] as? NSNumber)?.intValue,
                  let ma = (entry["MaxCurrent"] as? NSNumber)?.intValue else { return nil }
            return AdapterHVCEntry(voltageMV: mv, currentMA: ma)
        }
    }

    private static func parsePowerTelemetry(_ value: Any?) -> PowerTelemetrySystemData? {
        guard let d = value as? [String: Any] else { return nil }
        return PowerTelemetrySystemData(
            systemVoltageIn: intVal(d["SystemVoltageIn"]),
            systemCurrentIn: intVal(d["SystemCurrentIn"]),
            systemPowerIn: intVal(d["SystemPowerIn"]),
            systemLoad: intVal(d["SystemLoad"]),
            batteryPower: intVal(d["BatteryPower"]),
            wallEnergyEstimate: intVal(d["WallEnergyEstimate"]),
            adapterEfficiencyLoss: intVal(d["AdapterEfficiencyLoss"]),
            systemEnergyConsumed: intVal(d["SystemEnergyConsumed"]),
            powerTelemetryErrorCount: intVal(d["PowerTelemetryErrorCount"]),
            accumulatedSystemPowerIn: intVal(d["AccumulatedSystemPowerIn"]),
            accumulatedSystemLoad: intVal(d["AccumulatedSystemLoad"]),
            accumulatedSystemEnergyConsumed: intVal(d["AccumulatedSystemEnergyConsumed"]),
            accumulatedWallEnergyEstimate: intVal(d["AccumulatedWallEnergyEstimate"]),
            accumulatedBatteryPower: intVal(d["AccumulatedBatteryPower"]),
            accumulatedBatteryDischarge: intVal(d["AccumulatedBatteryDischarge"]),
            accumulatedAdapterEfficiencyLoss: intVal(d["AccumulatedAdapterEfficiencyLoss"]),
            systemPowerInAccumulatorCount: intVal(d["SystemPowerInAccumulatorCount"]),
            systemLoadAccumulatorCount: intVal(d["SystemLoadAccumulatorCount"]),
            batteryPowerAccumulatorCount: intVal(d["BatteryPowerAccumulatorCount"]),
            batteryDischargeAccumulatorCount: intVal(d["BatteryDischargeAccumulatorCount"]),
            adapterEfficiencyLossAccumulatorCount: intVal(d["AdapterEfficiencyLossAccumulatorCount"])
        )
    }

    private static func parsePortControllerInfo(_ value: Any?) -> [PortControllerEntry] {
        guard let arr = value as? [[String: Any]] else { return [] }
        return arr.enumerated().map { offset, d in
            let pdos: [UInt32]
            if let pdoArr = d["PortControllerPortPDO"] as? [Any] {
                pdos = pdoArr.compactMap { item -> UInt32? in
                    if let n = item as? NSNumber { return UInt32(truncatingIfNeeded: n.int64Value) }
                    return nil
                }
            } else {
                pdos = []
            }
            return PortControllerEntry(
                portIndex: offset + 1,
                firmwareVersion: intVal(d["PortControllerFwVersion"]),
                powerState: intVal(d["PortControllerPowerState"]),
                portMode: intVal(d["PortControllerPortMode"]),
                maxPower: intVal(d["PortControllerMaxPower"]),
                activeContractRdo: uint32Val(d["PortControllerActiveContractRdo"]),
                numberOfPDOs: intVal(d["PortControllerNPDOs"]),
                numberOfEprPDOs: intVal(d["PortControllerNEprPDOs"]),
                portPDOs: pdos,
                fetStatus: intVal(d["PortControllerFetStatus"]),
                bootFlags: intVal(d["PortControllerBootFlags"]),
                capMismatch: intVal(d["PortControllerCapMismatch"]),
                attachCount: intVal(d["PortControllerAttachCount"]),
                detachCount: intVal(d["PortControllerDetachCount"]),
                hardResetCount: intVal(d["PortControllerHardResetCount"]),
                dataRoleSwapCount: intVal(d["PortControllerDataRoleSwapCount"]),
                dataRoleSwapFailCount: intVal(d["PortControllerDataRoleSwapFailCount"]),
                pwrRoleSwapCount: intVal(d["PortControllerPwrRoleSwapCount"]),
                pwrRoleSwapFailCount: intVal(d["PortControllerPwrRoleSwapFailCount"]),
                vdoFailCount: intVal(d["PortControllerVdoFailCount"]),
                shortDetectCount: intVal(d["PortControllerShortDetectCount"]),
                wakeFailCount: intVal(d["PortControllerWakeFailCount"]),
                wakeTimeoutCount: intVal(d["PortControllerWakeTimeoutCount"]),
                sleepCmdFailCount: intVal(d["PortControllerSleepCmdFailCount"]),
                wakeCmdFailCount: intVal(d["PortControllerWakeCmdFailCount"]),
                stuckCmdCount: intVal(d["PortControllerStuckCmdCount"]),
                surpriseAckCount: intVal(d["PortControllerSurpriseAckCount"]),
                surpriseNackCount: intVal(d["PortControllerSurpriseNackCount"]),
                srdyCount: intVal(d["PortControllerSrdyCount"]),
                srdoCount: intVal(d["PortControllerSrdoCount"]),
                srdyRejectCount: intVal(d["PortControllerSrdyRejectCount"]),
                srdoRejectCount: intVal(d["PortControllerSrdoRejectCount"]),
                srdoRetryCount: intVal(d["PortControllerSrdoRetryCount"]),
                hvEnRecoveryCount: intVal(d["PortControllerHvEnRecoveryCount"]),
                inpFetEnFailCount: intVal(d["PortControllerInpFetEnFailCount"]),
                i2cErrCount: intVal(d["PortControllerI2cErrCount"]),
                loserReason: intVal(d["PortControllerLoserReason"]),
                electionFailReason: intVal(d["PortControllerElectionFailReason"]),
                uvdmStatus: intVal(d["PortControllerUvdmStatus"]),
                srcTypes: intVal(d["PortControllerSrcTypes"]),
                dnSt: intVal(d["PortControllerDnSt"]),
                pdSt: intVal(d["PortControllerPDst"]),
                isSleepEnabled: intVal(d["PortControllerSlpWakIsSleepEnabled"]) != 0,
                sleepDisableTime: intVal(d["PortControllerSlpWakDisTime"]),
                sleepDisableCause: intVal(d["PortControllerSlpWakDisCause"])
            )
        }
    }

    // MARK: - FedDetails

    private static func parseFedDetails(_ value: Any?) -> [FederatedIdentity] {
        guard let arr = value as? NSArray else { return [] }
        var results: [FederatedIdentity] = []
        for (offset, element) in arr.enumerated() {
            guard let entry = element as? NSDictionary else { continue }
            let vid = (entry["FedVendorID"] as? NSNumber)?.intValue ?? 0
            let pid = (entry["FedProductID"] as? NSNumber)?.intValue ?? 0
            let pdRev = (entry["FedPdSpecRevision"] as? NSNumber)?.intValue ?? 0
            let role = (entry["FedPortPowerRole"] as? NSNumber)?.intValue ?? 0
            let drp = (entry["FedDualRolePower"] as? NSNumber)?.intValue ?? 0
            let ext = (entry["FedExternalConnected"] as? NSNumber)?.intValue ?? 0
            results.append(FederatedIdentity(
                portIndex: offset + 1,
                vendorID: vid,
                productID: pid,
                pdSpecRevision: pdRev,
                powerRole: role,
                dualRolePower: drp != 0,
                externalConnected: ext != 0
            ))
        }
        return results
    }

    // MARK: - Helpers

    private static func intVal(_ value: Any?) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        if let i = value as? Int { return i }
        return 0
    }

    private static func uint32Val(_ value: Any?) -> UInt32 {
        if let n = value as? NSNumber { return UInt32(truncatingIfNeeded: n.int64Value) }
        if let i = value as? Int { return UInt32(truncatingIfNeeded: i) }
        return 0
    }

    private static func boolVal(_ value: Any?) -> Bool {
        if let n = value as? NSNumber { return n.boolValue }
        if let b = value as? Bool { return b }
        return false
    }
}
