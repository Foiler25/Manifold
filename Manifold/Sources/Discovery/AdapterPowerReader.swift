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
// Reads the connected AC adapter's wattage from `AppleSmartBattery`'s
// `AdapterDetails` property in the IOKit registry. Works for both
// MagSafe and USB-C PD chargers — macOS's PMU exposes whichever is
// active in the same dictionary.
//
// Returns nil for:
//   - Desktop Macs (Mac mini / Studio / Pro) — no `AppleSmartBattery`
//   - Laptops on battery (no adapter connected, or adapter not yet
//     enumerated by the kernel)
//
// Uses double-CF-bridging because `AdapterDetails` is published as a
// CFDictionary; the cast through `[String: Any]` lets us pull the
// `Watts` integer cleanly.

import Foundation
import IOKit
import ManifoldKit

enum AdapterPowerReader {

    /// Read the connected charger's wattage. Returns nil when no
    /// charger is connected or the host doesn't expose
    /// `AppleSmartBattery` (desktop Macs).
    nonisolated static func currentInputPower() -> Watts? {
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

        // `Watts` is the integer wattage as the charger reports itself
        // (96 for a 96W MagSafe, 65 for a 65W USB-C PD brick, etc.).
        // Older keys ("AdapterPower") are micro-watts on some PMU
        // versions; we only consume the modern Watts key.
        if let watts = details["Watts"] as? Int, watts > 0 {
            return Watts(Double(watts))
        }

        // Some Apple Silicon firmwares publish the wattage as a
        // floating-point number under the same key. Cast guards
        // against that variation rather than dropping the value.
        if let watts = details["Watts"] as? Double, watts > 0 {
            return Watts(watts)
        }
        return nil
    }
}
