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
// ─────────────────────────────────────────────────────────────────────
// BatterySnapshotReader.swift
//
// Phase 18 — reads a `BatteryInfo` snapshot from `AppleSmartBattery`.
// Returns `nil` on hardware where the service does not exist (desktop
// Macs).
//
// Design constraint per SPEC §20.2: every IOKit call goes through the
// §5 / §5.1 safe wrappers (`IOObject`, `forEachEntry`, `property(_:of:as:)`,
// `withMatchingServices`). No raw kernel-handle release / CF-property
// fetch / matching-service lookup calls in this file. The pre-existing
// `AdapterPowerReader.swift` is exempt (predates the §5.1 retrofit and
// is flagged for cleanup) but `BatterySnapshotReader` is a NEW file and
// must comply from day one. Reviewer enforces via the standard §5
// grep invariant on this filename.
//
// The split between `currentSnapshot()` (live, IOKit-touching) and
// `parse(properties:at:)` (pure, fixture-friendly) mirrors the same
// split `AdapterPowerReader` uses. Tests target `parse(...)` exclusively;
// the live `currentSnapshot()` path is exercised manually on the
// developer machine + at the `BATTERY-LIVE-UPDATES` Reviewer-deferred
// procedure (§18.0).

import Foundation
import IOKit
import ManifoldKit

enum BatterySnapshotReader {

    // MARK: - Live snapshot

    /// Live snapshot from the running IORegistry. Reads a fresh batch
    /// of properties on every call — the sampler invokes this on its
    /// tick. Nonisolated so it can be called from the sampler timer
    /// thread without an actor hop (the IORegistry is thread-safe;
    /// the sampler hops the *result* to MainActor before forwarding to
    /// `PortGraph.applyBattery(_:)`).
    ///
    /// Returns `nil` when:
    ///   - `IOServiceMatching("AppleSmartBattery")` returns nil
    ///     (kernel-side OOM — vanishingly rare).
    ///   - No `AppleSmartBattery` service exists in the registry
    ///     (desktop Macs — Mac mini, Studio, Pro). The desktop path
    ///     is the dominant nil-return case.
    ///   - All required properties parse but a required field can't
    ///     be coerced — the parser returns nil; we forward.
    nonisolated static func currentSnapshot() -> BatteryInfo? {
        guard let matching = IOServiceMatching(BatterySnapshotReaderConstants.serviceClass) else {
            return nil
        }

        var snapshot: BatteryInfo?
        withMatchingServices(matching) { iter in
            // `forEachEntry` takes ownership of each `IOObject` and
            // releases on closure exit. Only the first matching entry
            // is consumed — `AppleSmartBattery` is a singleton service
            // so any subsequent entries from the iterator would be
            // duplicates.
            forEachEntry(in: iter) { entry in
                guard snapshot == nil else { return }
                let properties = readAllProperties(of: entry)
                snapshot = parse(properties: properties, at: Date())
            }
        }
        return snapshot
    }

    /// All IORegistry property keys this reader consults. Centralized
    /// in one place so the live `readAllProperties` helper can iterate
    /// it without any duplicate stringly-typed names elsewhere in the
    /// file. Kept in array form (not a Set) so the order is stable for
    /// the DEBUG dump path.
    private static let queriedKeys: [String] = [
        "DesignCapacity",
        "NominalChargeCapacity",
        "AppleRawCurrentCapacity",
        "AppleRawMaxCapacity",
        "CycleCount",
        "IsCharging",
        "FullyCharged",
        "ExternalConnected",
        "Temperature",
        "Voltage",
        "Amperage",
        "AvgTimeToFull",
        "AvgTimeToEmpty"
    ]

    // MARK: - Pure parser (test target)

    /// Pure parser, used by `BatterySnapshotReaderTests` against
    /// captured plist fixtures. The `properties` dict is the raw
    /// `[String: Any]` keyed on the `AppleSmartBattery` IORegistry
    /// property names listed in SPEC §20.3.
    ///
    /// Returns nil only when the dict is missing the bare-minimum
    /// fields needed to build a meaningful snapshot (capacity for the
    /// charge percent, design + nominal capacity for the health
    /// percent). Optional fields (time-until-full, etc.) flow as nil.
    static func parse(properties: [String: Any], at sampledAt: Date) -> BatteryInfo? {
        // -- Required ------------------------------------------------
        guard
            let designCapacity = readInt(properties, key: "DesignCapacity"),
            let nominalCapacity = readInt(properties, key: "NominalChargeCapacity"),
            let currentCapacity = readInt(properties, key: "AppleRawCurrentCapacity"),
            let maxCapacity = readInt(properties, key: "AppleRawMaxCapacity"),
            designCapacity > 0,
            maxCapacity > 0
        else {
            return nil
        }

        // -- Discrete state ------------------------------------------
        // Read state flags first so the charge-percent math can honor
        // `FullyCharged` (Apple's Optimized Battery Charging stops the
        // raw ratio at ~80–98 % to extend battery life while reporting
        // the battery as full — macOS and Juicy display 100 % in this
        // state, and so do we).
        let cycleCount = readInt(properties, key: "CycleCount") ?? 0
        let isCharging = readBool(properties, key: "IsCharging") ?? false
        let isFullyCharged = readBool(properties, key: "FullyCharged") ?? false
        let isExternalConnected = readBool(properties, key: "ExternalConnected") ?? false

        // -- Charge / health math ------------------------------------
        let rawChargePercent = clamp(
            Int((Double(currentCapacity) / Double(maxCapacity) * BatterySnapshotReaderConstants.percentScale).rounded()),
            min: 0,
            max: BatterySnapshotReaderConstants.percentMax
        )
        // Pin to 100 when the firmware has flagged the battery as full.
        // The raw ratio can sit at 96–99 % indefinitely under Optimized
        // Battery Charging — surfacing that as "98 %" while the menu
        // bar / Juicy / System Settings all say "100 %" reads as a bug.
        let chargePercent = isFullyCharged
            ? BatterySnapshotReaderConstants.percentMax
            : rawChargePercent

        // Health % = nominal / design × 100, rounded + clamped 0...100.
        let healthPercent = clamp(
            Int((Double(nominalCapacity) / Double(designCapacity) * BatterySnapshotReaderConstants.percentScale).rounded()),
            min: 0,
            max: BatterySnapshotReaderConstants.percentMax
        )

        // -- Continuous values ---------------------------------------
        // Temperature is published in centi-degrees (e.g. 3240 → 32.4).
        let temperatureCelsius: Double = (readDouble(properties, key: "Temperature") ?? 0)
            / BatterySnapshotReaderConstants.temperatureDivisor

        // Voltage is published in millivolts (e.g. 12450 → 12.45).
        let voltageVolts: Double = (readDouble(properties, key: "Voltage") ?? 0)
            / BatterySnapshotReaderConstants.voltageDivisor

        // Amperage is signed; >0 charging, <0 discharging. D18 / Q16
        // pin this to `Amperage` (smoothed), NOT `InstantAmperage`.
        let amperageMilliamps = readInt(properties, key: "Amperage") ?? 0

        // Power = V × |mA| / 1000, since current is in mA.
        let powerWatts = voltageVolts
            * Double(abs(amperageMilliamps))
            / BatterySnapshotReaderConstants.milliampsPerAmp

        // -- Time remaining sentinels --------------------------------
        let timeUntilFullMinutes = parseTimeRemaining(properties["AvgTimeToFull"])
        let timeUntilEmptyMinutes = parseTimeRemaining(properties["AvgTimeToEmpty"])

        // -- Charge-state dispatch (§20.3, priority order) -----------
        let chargeState: BatteryInfo.ChargeState = {
            if isFullyCharged {
                return .fullyCharged
            }
            if isCharging && isExternalConnected {
                return .charging
            }
            if !isExternalConnected {
                return .discharging
            }
            if isExternalConnected && !isCharging && !isFullyCharged {
                return .notCharging
            }
            return .unknown
        }()

        return BatteryInfo(
            chargePercent: chargePercent,
            chargeState: chargeState,
            healthPercent: healthPercent,
            cycleCount: cycleCount,
            temperatureCelsius: temperatureCelsius,
            voltageVolts: voltageVolts,
            amperageMilliamps: amperageMilliamps,
            powerWatts: powerWatts,
            designCapacityMAh: designCapacity,
            nominalCapacityMAh: nominalCapacity,
            currentCapacityMAh: currentCapacity,
            timeUntilFullMinutes: timeUntilFullMinutes,
            timeUntilEmptyMinutes: timeUntilEmptyMinutes,
            isExternalConnected: isExternalConnected,
            isFullyCharged: isFullyCharged,
            sampledAt: sampledAt
        )
    }

    // MARK: - DEBUG fixture-capture helper

#if DEBUG
    /// DEBUG-only: dump the queried IORegistry properties of
    /// `AppleSmartBattery` to a binary plist at `url`. Used to capture
    /// `AppleSmartBattery_Healthy.plist` from a developer machine for
    /// the test fixtures; the synthetic `_Aged.plist` is hand-edited
    /// from a captured copy.
    ///
    /// Throws on any I/O / serialization failure. Returns silently on
    /// hardware with no battery (writes nothing — the caller can check
    /// the file's existence).
    ///
    /// Captures only the keys in `queriedKeys` — exactly the surface
    /// the parser inspects. That keeps the on-disk fixture small
    /// (~14 entries vs. the ~80 properties IOKit publishes for the
    /// service) and reproducible across machines without leaking
    /// model-specific firmware fields the parser doesn't read.
    static func dumpProperties(to url: URL) throws {
        guard let matching = IOServiceMatching(BatterySnapshotReaderConstants.serviceClass) else {
            return
        }
        var captured: [String: Any] = [:]
        withMatchingServices(matching) { iter in
            forEachEntry(in: iter) { entry in
                guard captured.isEmpty else { return }
                captured = readAllProperties(of: entry)
            }
        }
        guard !captured.isEmpty else { return }
        let data = try PropertyListSerialization.data(
            fromPropertyList: captured,
            format: .binary,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }
#endif

    // MARK: - Internals

    /// Read every property key listed in `queriedKeys`, one at a time,
    /// through the §5 safe `property(_:of:as:)` wrapper. ~13 round trips
    /// per call — measured below the IOKit-walk noise floor on M-series
    /// hardware (≈hundreds of microseconds each), comfortably under the
    /// sampler's 1 Hz tick budget.
    ///
    /// The per-key path keeps this file fully inside the §5 safe-wrapper
    /// surface — only the four blessed wrappers are referenced. A bulk
    /// kernel-properties read would be one round trip but would require
    /// a per-file exception; not worth it for ~ms savings on a 1 Hz
    /// sampler.
    private static func readAllProperties(of entry: borrowing IOObject) -> [String: Any] {
        var properties: [String: Any] = [:]
        for key in queriedKeys {
            // Most properties are NSNumber-bridged (Int / Double / Bool
            // all flow through NSNumber). A successful read always
            // produces an `NSNumber` instance — Bool / Int / Double
            // distinctions are folded out at the parser layer via
            // `.intValue`, `.doubleValue`, `.boolValue` accessors.
            if let value: NSNumber = property(key, of: entry, as: NSNumber.self) {
                properties[key] = value
            }
        }
        return properties
    }

    /// NSNumber → Int helper. Some firmware publishes capacity values
    /// as Double (NSNumber-bridged); accept both with `.intValue` /
    /// `Int(double)`. `NSNumber.intValue` truncates toward zero on
    /// large values — capacity values are always well under Int.max.
    private static func readInt(_ properties: [String: Any], key: String) -> Int? {
        if let n = properties[key] as? NSNumber {
            return n.intValue
        }
        return nil
    }

    /// NSNumber → Double helper. Same dual-firmware path.
    private static func readDouble(_ properties: [String: Any], key: String) -> Double? {
        if let n = properties[key] as? NSNumber {
            return n.doubleValue
        }
        return nil
    }

    /// IOKit Bool → Swift Bool. CFBoolean bridges as NSNumber.
    private static func readBool(_ properties: [String: Any], key: String) -> Bool? {
        if let n = properties[key] as? NSNumber {
            return n.boolValue
        }
        return nil
    }

    /// Time-remaining sentinel handler. Per §20.3:
    ///   - `≤ 0` is the "unknown / not estimable" sentinel.
    ///   - `≥ 65535` is the "uninitialized" sentinel (sometimes
    ///     reported as 0xFFFF on older firmware).
    /// Either case → nil.
    private static func parseTimeRemaining(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber else { return nil }
        let minutes = n.intValue
        if minutes <= 0 { return nil }
        if minutes >= BatterySnapshotReaderConstants.timeRemainingSentinel { return nil }
        return minutes
    }

    /// Constrain `value` to `[min, max]`. Reusable in-band even though
    /// `(0...).clamped(to:)` exists on Range, to avoid bringing in the
    /// `swift-collections` Clamped<T> initializer dance.
    private static func clamp(_ value: Int, min lower: Int, max upper: Int) -> Int {
        Swift.max(lower, Swift.min(upper, value))
    }
}

// MARK: - Constants

enum BatterySnapshotReaderConstants {
    /// IOKit service class matched by `IOServiceMatching(_:)`. Singleton
    /// service per SPEC §20.3 — desktop Macs have no entry under this
    /// name, which is the entire desktop-empty-state path.
    static let serviceClass: String = "AppleSmartBattery"

    /// Centi-degree → Celsius divisor for the `Temperature` property.
    /// Firmware publishes `3240` for `32.40°C`.
    static let temperatureDivisor: Double = 100.0

    /// Millivolt → volt divisor for the `Voltage` property. Firmware
    /// publishes `12450` for `12.45 V`.
    static let voltageDivisor: Double = 1000.0

    /// Milliamp → amp divisor for the power computation. Used so the
    /// `V × A` product lands in watts.
    static let milliampsPerAmp: Double = 1000.0

    /// 0...100 percent scale for the rounded chargePercent /
    /// healthPercent computations.
    static let percentScale: Double = 100.0

    /// Upper bound for clamped percent values. Mirrors `percentScale`
    /// as Int.
    static let percentMax: Int = 100

    /// IOKit time-remaining sentinel threshold. `AvgTimeToFull` /
    /// `AvgTimeToEmpty` ≥ this means "uninitialized" / "not estimable".
    static let timeRemainingSentinel: Int = 65535
}
