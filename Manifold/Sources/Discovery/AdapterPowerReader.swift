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
// ─────────────────────────────────────────────────────────────────────
// AdapterPowerReader.swift
//
// Reads the active charger's wattage AND classifies its source
// (MagSafe / USB-C / Wireless) from `AppleSmartBattery`'s
// `AdapterDetails` property in IOReg.
//
// macOS reports details about ONE active adapter even when multiple
// chargers are physically connected (e.g. MagSafe + USB-C PD). The SMC
// picks one based on connect order + negotiated capability — there's
// no public API that enumerates the inactive sources, so we surface
// what we can: the active adapter and its source.
//
// Source classification heuristics:
//   - `IsWireless == true` → `.wireless`
//   - `Description` containing "MagSafe" → `.magsafe`
//   - `Description` containing "USB" / "USB-C" / "Type-C" → `.usbC`
//   - `FamilyCode` 0xe000_4006 (Apple's USB-C PD family) → `.usbC`
//   - `FamilyCode` 0xe000_4001 / 0xe000_4007 (MagSafe family) → `.magsafe`
//   - otherwise → `.unknown`
//
// The FamilyCode constants are observed values, not Apple-published; if
// a future macOS revision changes them, the Description-string fallback
// above still classifies most chargers correctly.

import Foundation
import IOKit
import ManifoldKit

enum AdapterPowerReader {

    /// Read the connected charger's adapter info. Returns nil when no
    /// charger is connected or the host doesn't expose
    /// `AppleSmartBattery` (desktop Macs).
    nonisolated static func currentInputPower() -> AdapterInfo? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else {
            return nil
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let details = IORegistryEntryCreateCFProperty(
            service,
            "AdapterDetails" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        guard let watts = parseWatts(from: details) else {
            return nil
        }

        // Voltage is published in mV, current in mA. Promote both to
        // SI units so the UI doesn't have to care.
        let voltage = (details["Voltage"] as? Int).map { Double($0) / 1000.0 }
            ?? (details["Voltage"] as? Double).map { $0 / 1000.0 }
        let amperage = (details["Current"] as? Int).map { Double($0) / 1000.0 }
            ?? (details["Current"] as? Double).map { $0 / 1000.0 }

        return AdapterInfo(
            watts: Watts(Double(watts)),
            source: classify(details: details),
            description: details["Description"] as? String,
            manufacturer: details["Manufacturer"] as? String,
            model: details["Model"] as? String
                ?? details["Name"] as? String
                ?? details["HwVersion"] as? String,
            voltage: voltage,
            amperage: amperage,
            familyCode: details["FamilyCode"] as? Int
        )
    }

    /// DEBUG-only: dumps the raw `AdapterDetails` dictionary keys + values
    /// to os_log so we can verify what each Mac actually publishes (key
    /// names, FamilyCode values, etc.). The Power tab also renders the
    /// captured fields visibly so this log is rarely needed in practice.
    nonisolated static func dumpAdapterDetails() {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        let raw = IORegistryEntryCreateCFProperty(
            service,
            "AdapterDetails" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
        if let dict = raw as? [String: Any] {
            for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
                Swift.print("[AdapterDetails] \(key) = \(value)")
            }
        }
    }

    // MARK: - Field parsers

    /// `Watts` is published as either Int or Double depending on the
    /// firmware. Both branches must accept `> 0` only — a charger that
    /// reports 0 W is effectively absent (kernel bookkeeping during
    /// hot-plug).
    private static func parseWatts(from details: [String: Any]) -> Int? {
        if let watts = details["Watts"] as? Int, watts > 0 {
            return watts
        }
        if let watts = details["Watts"] as? Double, watts > 0 {
            return Int(watts)
        }
        return nil
    }

    /// Classify the adapter into MagSafe / USB-C / Wireless / Unknown.
    /// Tries the IsWireless flag first, then the FamilyCode, then a
    /// case-insensitive substring match on the Description string.
    private static func classify(details: [String: Any]) -> AdapterInfo.Source {
        if let wireless = details["IsWireless"] as? Bool, wireless {
            return .wireless
        }

        // FamilyCode is Apple's adapter taxonomy. Observed values:
        //   0xe000_4001 — original MagSafe (Intel-era)
        //   0xe000_4007 — Apple Silicon MagSafe 3
        //   0xe000_4006 — USB-C PD
        // A non-Apple PD brick may not set FamilyCode at all; fall
        // through to the Description heuristic in that case.
        if let family = details["FamilyCode"] as? Int {
            switch family {
            case 0xe000_4001, 0xe000_4007:
                return .magsafe
            case 0xe000_4006:
                return .usbC
            default:
                break
            }
        }

        let description = (details["Description"] as? String ?? "").lowercased()
        if description.contains("magsafe") {
            return .magsafe
        }
        if description.contains("usb-c") || description.contains("usbc")
            || description.contains("type-c") || description.contains("usb")
        {
            return .usbC
        }
        return .unknown
    }
}
