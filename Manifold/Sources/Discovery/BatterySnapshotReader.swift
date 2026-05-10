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
import IOKit.ps
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

        // Read the IOPS-API smoothed values up front. These match
        // exactly what macOS shows in its menubar — kIOPSCurrentCapacity
        // is the *displayed* percent (not the raw AppleSmartBattery
        // ratio), and IOPSGetTimeRemainingEstimate is the *displayed*
        // time-until-full / time-until-empty. Without these overrides
        // we'd surface 95 % when macOS says 100 % (Optimized Battery
        // Charging gap) and 105 hours of remaining time when macOS
        // says 5 hours (raw AvgTimeToEmpty over-extrapolates at near-
        // idle current draw). The IORegistry properties are still the
        // source of truth for everything else (cycle count, voltage,
        // temperature, capacity in mAh).
        let smoothed = readIPSValues()

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
                snapshot = parse(
                    properties: properties,
                    at: Date(),
                    smoothedChargePercent: smoothed.percent,
                    smoothedTimeUntilFullMinutes: smoothed.timeUntilFullMinutes,
                    smoothedTimeUntilEmptyMinutes: smoothed.timeUntilEmptyMinutes
                )
            }
        }
        return snapshot
    }

    /// Smoothed charge percent + time-remaining tuple sourced from
    /// `IOPSCopyPowerSourcesInfo` / `IOPSGetTimeRemainingEstimate`.
    /// Each field independently nullable — if the IOPS API doesn't
    /// publish a value (no battery, calculating, or kIOPSTimeRemaining-
    /// Unlimited sentinel) the field stays nil and the caller falls
    /// back to the raw IORegistry values from `parse(properties:)`.
    ///
    /// IOPS is a higher-level macOS power-source API that wraps a
    /// large family of platform sources (AppleSmartBattery, UPS,
    /// dock-power adapters) behind a stable shape. The values it
    /// returns are the same ones the macOS menubar / Battery system
    /// pane / Juicy display, so preferring IOPS over the raw IOKit
    /// registry properties produces UI that matches every other
    /// macOS surface.
    ///
    /// `IOPSGetPowerSourceDescription` returns an unretained
    /// CFDictionary owned by `blob`; `IOPSCopyPowerSourcesInfo` and
    /// `IOPSCopyPowerSourcesList` are caller-owned (`takeRetainedValue`).
    /// This is a different API surface from the §5 IORegistry safe
    /// wrappers — IOPS doesn't traffic in `io_object_t` handles, so
    /// it's outside the §5 grep invariant by definition.
    nonisolated private static func readIPSValues()
        -> (percent: Int?, timeUntilFullMinutes: Int?, timeUntilEmptyMinutes: Int?)
    {
        var result: (percent: Int?, timeUntilFullMinutes: Int?, timeUntilEmptyMinutes: Int?)
            = (nil, nil, nil)

        guard let blobRef = IOPSCopyPowerSourcesInfo() else { return result }
        let blob = blobRef.takeRetainedValue()

        guard let listRef = IOPSCopyPowerSourcesList(blob) else { return result }
        let list = listRef.takeRetainedValue() as Array

        // Per-source direction inferred from the source dict's
        // charging / state keys. Used to route
        // `IOPSGetTimeRemainingEstimate()` (a single global
        // estimate, no direction) into the right field below — the
        // per-source `kIOPSTimeToEmpty` / `TimeToFullCharge` values
        // lag for ~1–2s after a power-source change, so without
        // this we'd surface a `nil` time-remaining caption every
        // plug/unplug even though the smoothed estimate IS
        // available.
        var sourceIsCharging: Bool?

        for sourceAny in list {
            let source = sourceAny as CFTypeRef
            guard let descRef = IOPSGetPowerSourceDescription(blob, source) else { continue }
            // `IOPSGetPowerSourceDescription` returns an unretained
            // reference owned by `blob` — Get*, not Copy*.
            guard let desc = descRef.takeUnretainedValue() as? [String: Any] else { continue }

            // Skip any non-internal source (UPS, dock-passthrough,
            // attached battery accessories) — only the laptop's main
            // battery feeds the percent / time-remaining display.
            if let type = desc[kIOPSTypeKey as String] as? String,
               type != (kIOPSInternalBatteryType as String) {
                continue
            }

            if let p = desc[kIOPSCurrentCapacityKey as String] as? Int,
               (0...BatterySnapshotReaderConstants.percentMax).contains(p) {
                result.percent = p
            }

            // Direction. Prefer the explicit `IsCharging` flag; fall
            // back to the `Power Source State` string ("AC Power" /
            // "Battery Power") when the flag is absent.
            if let charging = desc[kIOPSIsChargingKey as String] as? Bool {
                sourceIsCharging = charging
            } else if let state = desc[kIOPSPowerSourceStateKey as String] as? String {
                sourceIsCharging = (state == (kIOPSACPowerValue as String))
            }

            // IOPS publishes time-to-empty / time-to-full as integer
            // minutes. Negative or sentinel-large values mean
            // "calculating" / "unknown" → keep nil so the UI doesn't
            // show a stale figure.
            if let t = desc[kIOPSTimeToEmptyKey as String] as? Int, t > 0,
               t < BatterySnapshotReaderConstants.timeRemainingSentinel {
                result.timeUntilEmptyMinutes = t
            }
            if let t = desc[kIOPSTimeToFullChargeKey as String] as? Int, t > 0,
               t < BatterySnapshotReaderConstants.timeRemainingSentinel {
                result.timeUntilFullMinutes = t
            }
        }

        // `IOPSGetTimeRemainingEstimate` is the same number macOS's
        // menubar shows. It returns a `CFTimeInterval` in *seconds*:
        //   kIOPSTimeRemainingUnlimited (-2): plugged in or full,
        //                                     no countdown applies.
        //   kIOPSTimeRemainingUnknown   (-1): not enough samples yet.
        //   positive: seconds remaining.
        //
        // The estimate is unidirectional — the framework hands back
        // a single number and expects the caller to know which
        // direction applies. We use the IsCharging flag captured
        // above to route it. When IsCharging is nil (rare; happens
        // very briefly mid-transition), we fall back to whichever
        // per-source field had a value, then to "leave both nil".
        let estimate = IOPSGetTimeRemainingEstimate()
        if estimate > 0 {
            let estimatedMinutes = Int(estimate
                                       / Double(BatterySnapshotReaderConstants.secondsPerMinute))
            switch sourceIsCharging {
            case .some(true):
                result.timeUntilFullMinutes = estimatedMinutes
            case .some(false):
                result.timeUntilEmptyMinutes = estimatedMinutes
            case .none:
                if result.timeUntilEmptyMinutes != nil {
                    result.timeUntilEmptyMinutes = estimatedMinutes
                } else if result.timeUntilFullMinutes != nil {
                    result.timeUntilFullMinutes = estimatedMinutes
                }
            }
        }

        return result
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
        "InstantAmperage",
        "Amperage",
        "AvgTimeToFull",
        "AvgTimeToEmpty",
        // Read alongside the rest so the instant time-until-full math
        // can fall back on the adapter's rated current when
        // `InstantAmperage` reports 0 (Optimized Battery Charging
        // hold, or the moment between plug-in and PD negotiation).
        "AdapterDetails"
    ]

    // MARK: - Pure parser (test target)

    /// Pure parser, used by `BatterySnapshotReaderTests` against
    /// captured plist fixtures. The `properties` dict is the raw
    /// `[String: Any]` keyed on the `AppleSmartBattery` IORegistry
    /// property names listed in SPEC §20.3.
    ///
    /// The optional `smoothed*` parameters carry overrides sourced
    /// from the IOPS API (see `readIPSValues`). When a smoothed
    /// override is non-nil it wins over the IORegistry-derived
    /// computation — this is how the live `currentSnapshot()` path
    /// matches macOS's displayed values exactly. Tests pass nil
    /// (the default) and exercise the pure IORegistry math.
    ///
    /// Returns nil only when the dict is missing the bare-minimum
    /// fields needed to build a meaningful snapshot (capacity for the
    /// charge percent, design + nominal capacity for the health
    /// percent). Optional fields (time-until-full, etc.) flow as nil.
    static func parse(
        properties: [String: Any],
        at sampledAt: Date,
        smoothedChargePercent: Int? = nil,
        smoothedTimeUntilFullMinutes: Int? = nil,
        smoothedTimeUntilEmptyMinutes: Int? = nil
    ) -> BatteryInfo? {
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
        // Three-tier resolution for the displayed percentage:
        //   1. IOPS-smoothed value (matches macOS / Juicy exactly).
        //   2. Pin to 100 when the firmware flagged FullyCharged
        //      (handles the just-unplugged moment where IOPS may not
        //      have refreshed yet).
        //   3. Raw IORegistry ratio.
        // Tests pass nil for the smoothed override and validate (3).
        let chargePercent: Int
        if let smoothed = smoothedChargePercent {
            chargePercent = clamp(smoothed,
                                  min: 0,
                                  max: BatterySnapshotReaderConstants.percentMax)
        } else if isFullyCharged {
            chargePercent = BatterySnapshotReaderConstants.percentMax
        } else {
            chargePercent = rawChargePercent
        }

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

        // Amperage is signed; >0 charging, <0 discharging. The
        // original D18 / Q16 decision pinned this to the smoothed
        // `Amperage` for stable readings, but Brandon reverted that
        // on 2026-05-04 in favor of `InstantAmperage` so Manifold's
        // current/power readings track Juicy's live values. Falls
        // back to `Amperage` if the firmware doesn't publish the
        // instant variant. The 1 Hz sampler tick provides enough
        // pacing on its own — we surface what the hardware reports
        // each tick rather than averaging on top.
        let amperageMilliamps = readInt(properties, key: "InstantAmperage")
            ?? readInt(properties, key: "Amperage")
            ?? 0

        // Power = V × |mA| / 1000, since current is in mA.
        let powerWatts = voltageVolts
            * Double(abs(amperageMilliamps))
            / BatterySnapshotReaderConstants.milliampsPerAmp

        // -- Time remaining resolution --------------------------------
        // Two-tier policy:
        //   1. IOPS smoothed estimate when the kernel has stabilized
        //      it (typically 5–30 s after a plug/unplug edge). Same
        //      number macOS's menu bar and System Settings → Battery
        //      show.
        //   2. Instant estimate computed from `InstantAmperage` when
        //      IOPS hasn't published yet, so the user sees a value
        //      within tens of ms instead of waiting on the kernel.
        //      The charge variant applies a two-phase Li-ion curve
        //      (constant-current below 80 %, ramped constant-voltage
        //      above) so the value approximates the kernel's smoothed
        //      target rather than under-shooting wildly à la Juicy.
        //      The discharge variant is linear — discharge curves are
        //      effectively flat at the cell level, and load-induced
        //      current jitter is what the IOPS smoother absorbs over
        //      its 5–30 s window.
        //
        // The previous fallback to IOReg `AvgTimeToFull` /
        // `AvgTimeToEmpty` was dropped — those fields go through the
        // kernel's own smoothing and reproduce the very same lag IOPS
        // has, so they couldn't fill the "calibrating" window. The
        // instant estimate does.
        // Adapter rated current — used as a fallback when the cell
        // isn't actively pulling current right now (Optimized
        // Battery Charging hold, or the brief moment between plug-
        // in and PD negotiation completing). The kernel publishes
        // the adapter's spec under `AdapterDetails.Current` (mA);
        // when present and external power is connected, we use it
        // to project a charge-rate even if `InstantAmperage = 0`,
        // so the user sees a number immediately rather than waiting
        // on macOS's smoother.
        let adapterRatedCurrentMA = Self.adapterRatedChargingCurrentMA(from: properties)

        let timeUntilFullMinutes: Int?
        if let smoothed = smoothedTimeUntilFullMinutes {
            timeUntilFullMinutes = smoothed
        } else if isExternalConnected,
                  chargePercent < BatterySnapshotReaderConstants.percentMax {
            // Plugged in and not yet full: produce an instant
            // estimate from whatever current we can find. Live
            // `InstantAmperage` if it's positive; otherwise the
            // adapter's rated current. At 100 % the answer is
            // semantically nil ("Topped off" is rendered by chargeState
            // — `timeUntilFullMinutes` is unused on that branch).
            timeUntilFullMinutes = Self.instantTimeUntilFullMinutes(
                chargePercent: chargePercent,
                fullChargeCapacityMAh: maxCapacity,
                instantAmperageMilliamps: amperageMilliamps,
                fallbackChargingCurrentMA: adapterRatedCurrentMA
            )
        } else {
            timeUntilFullMinutes = nil
        }

        let timeUntilEmptyMinutes: Int?
        if let smoothed = smoothedTimeUntilEmptyMinutes {
            timeUntilEmptyMinutes = smoothed
        } else if !isExternalConnected, amperageMilliamps != 0 {
            // Discharge sign convention varies — some Apple-silicon
            // Macs publish a positive `InstantAmperage` while on
            // battery. The caller guarantees we're not externally
            // connected, so any non-zero magnitude is drain. The
            // helper takes `abs()` internally.
            timeUntilEmptyMinutes = Self.instantTimeUntilEmptyMinutes(
                currentCapacityMAh: currentCapacity,
                instantAmperageMilliamps: amperageMilliamps
            )
        } else {
            timeUntilEmptyMinutes = nil
        }

        // -- Charge-state dispatch (§20.3, priority order) -----------
        // The kernel keeps `FullyCharged = Yes` at 100% even after
        // unplug — pmset's "100%; discharging; 6:10 remaining" is the
        // semantically-correct view, so we treat the battery as
        // discharging once external power goes away. Only report
        // `.fullyCharged` when BOTH the kernel flag is set AND
        // external power is still connected.
        let chargeState: BatteryInfo.ChargeState = {
            if isFullyCharged && isExternalConnected {
                return .fullyCharged
            }
            if isCharging && isExternalConnected {
                return .charging
            }
            if !isExternalConnected {
                return .discharging
            }
            if isExternalConnected && !isCharging {
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
                continue
            }
            // `AdapterDetails` is a CFDictionary — bridges through
            // NSDictionary, not NSNumber. Without this fallback the
            // first attempt silently drops the whole dictionary, the
            // adapter-rated-current fallback in
            // `adapterRatedChargingCurrentMA(...)` finds nothing,
            // and the instant time-until-full math returns nil
            // whenever live `InstantAmperage` is 0 (Optimized Battery
            // Charging hold, post-plug PD-negotiation window). One
            // extra round-trip per dictionary-typed key — fine.
            if let value: NSDictionary = property(key, of: entry, as: NSDictionary.self) {
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

    /// Compute time-until-full from the instantaneous current draw,
    /// applying a two-phase Li-ion charge-curve model. Used as a
    /// fallback while macOS's IOPS smoother is calibrating after a
    /// plug edge (the kernel takes 5–30 s to publish a stable
    /// estimate). Once `IOPSGetTimeRemainingEstimate()` returns a
    /// positive value, the parse function prefers that.
    ///
    /// Model:
    ///   - Below 80 %: constant-current phase. Linear math is
    ///     accurate. `mAh_remaining ÷ |amps| × 60`.
    ///   - 80–100 %: constant-voltage phase. Charge current ramps
    ///     down exponentially as cell voltage approaches max. We
    ///     model this with a multiplier that grows from 1.0× at the
    ///     start of CV to `cvCeiling` (2.5×) at 100 %, taking the
    ///     average over the remaining CV span as the effective
    ///     multiplier.
    ///
    /// The 80 % CV-start and 2.5× ceiling are empirical fits for
    /// Apple-silicon MagSafe / USB-C PD chargers — within ~10 % of
    /// the kernel's smoothed estimate at typical charge-state mid-
    /// points. Hardware-specific tuning would land closer; this
    /// model keeps the instant fallback in the right ballpark
    /// without per-Mac calibration.
    ///
    /// `fallbackChargingCurrentMA` covers the cases where
    /// `instantAmperageMilliamps` reports 0 even though external
    /// power is connected — Optimized Battery Charging holds the
    /// cell at the current level, or the brief moment between plug-
    /// in and PD negotiation completing. The adapter's rated current
    /// (read from `AdapterDetails.Current`) is the right substitute
    /// — that's what charging WILL be once the system releases the
    /// hold or finishes negotiating. Without this fallback the user
    /// stares at "Calculating…" until macOS's smoother catches up.
    nonisolated static func instantTimeUntilFullMinutes(
        chargePercent: Int,
        fullChargeCapacityMAh: Int,
        instantAmperageMilliamps: Int,
        fallbackChargingCurrentMA: Int? = nil
    ) -> Int? {
        let effectiveCurrentMA: Int
        if instantAmperageMilliamps > 0 {
            effectiveCurrentMA = instantAmperageMilliamps
        } else if let fallback = fallbackChargingCurrentMA, fallback > 0 {
            effectiveCurrentMA = fallback
        } else {
            return nil
        }
        guard fullChargeCapacityMAh > 0 else { return nil }
        let pct = clamp(chargePercent,
                        min: 0,
                        max: BatterySnapshotReaderConstants.percentMax)
        if pct >= BatterySnapshotReaderConstants.percentMax { return 0 }

        let cvStart = BatterySnapshotReaderConstants.cvStartPercent
        let cvCeiling = BatterySnapshotReaderConstants.cvCeilingMultiplier

        let ccPct: Int
        let cvPct: Int
        if pct >= cvStart {
            ccPct = 0
            cvPct = BatterySnapshotReaderConstants.percentMax - pct
        } else {
            ccPct = cvStart - pct
            cvPct = BatterySnapshotReaderConstants.percentMax - cvStart
        }

        // Average CV multiplier over the remaining CV span. The
        // multiplier rises linearly from 1.0× at `cvStart` to
        // `cvCeiling` at 100 %; if we're already partway into CV,
        // we average from our current position to 100 %.
        let cvSpanTotal = BatterySnapshotReaderConstants.percentMax - cvStart
        let cvStartFracHere: Double = pct >= cvStart && cvSpanTotal > 0
            ? Double(pct - cvStart) / Double(cvSpanTotal)
            : 0.0
        let avgFrac = (cvStartFracHere + 1.0) / 2.0
        let cvAvgMultiplier = 1.0 + avgFrac * (cvCeiling - 1.0)

        let mAhPerPct = Double(fullChargeCapacityMAh) / 100.0
        let weightedMAh = Double(ccPct) * mAhPerPct
            + Double(cvPct) * mAhPerPct * cvAvgMultiplier

        let minutes = weightedMAh / Double(effectiveCurrentMA) * 60.0
        return clamp(Int(minutes.rounded()),
                     min: 0,
                     max: BatterySnapshotReaderConstants.maxReasonableMinutes)
    }

    /// Compute time-until-empty from the current capacity and the
    /// instantaneous discharge current. Linear — discharge curves
    /// are essentially flat at the cell level, and load-induced
    /// current jitter is exactly what the IOPS smoother is meant to
    /// absorb (over a 5–30 s window). This estimate fluctuates with
    /// workload until IOPS publishes its smoothed value.
    ///
    /// Sign-agnostic: takes `abs(instantAmperageMilliamps)` as the
    /// drain rate. `InstantAmperage` is documented as signed
    /// (negative on discharge) but on some Apple-silicon Macs it
    /// arrives positive even when `ExternalConnected = No`. The
    /// caller has already established that we're on battery, so any
    /// non-zero magnitude is power flowing out of the cell.
    nonisolated static func instantTimeUntilEmptyMinutes(
        currentCapacityMAh: Int,
        instantAmperageMilliamps: Int
    ) -> Int? {
        guard instantAmperageMilliamps != 0 else { return nil }
        guard currentCapacityMAh > 0 else { return nil }
        let drainMA = abs(instantAmperageMilliamps)
        let minutes = Double(currentCapacityMAh) / Double(drainMA) * 60.0
        return clamp(Int(minutes.rounded()),
                     min: 0,
                     max: BatterySnapshotReaderConstants.maxReasonableMinutes)
    }

    /// Pull the adapter's rated charging current from
    /// `AdapterDetails.Current` (in mA). Used as a fallback for the
    /// instant time-until-full math when `InstantAmperage` is 0 —
    /// the kernel keeps the rated current populated whenever an
    /// adapter is connected, regardless of whether the cell is
    /// actively pulling charge right now. Falls through to deriving
    /// the value from `Watts × 1000 / Voltage` when `Current` is
    /// missing (rare; some firmware variants).
    nonisolated private static func adapterRatedChargingCurrentMA(
        from properties: [String: Any]
    ) -> Int? {
        guard let details = properties["AdapterDetails"] as? [String: Any] else {
            return nil
        }
        if let current = details["Current"] as? Int, current > 0 {
            return current
        }
        if let current = details["Current"] as? Double, current > 0 {
            return Int(current.rounded())
        }
        // Fallback: compute mA from Watts × 1000 / mV. Both must be
        // positive for the math to be meaningful.
        let watts = (details["Watts"] as? Int).map(Double.init)
            ?? (details["Watts"] as? Double)
        let voltageMV = (details["AdapterVoltage"] as? Int).map(Double.init)
            ?? (details["AdapterVoltage"] as? Double)
        if let watts, let voltageMV, watts > 0, voltageMV > 0 {
            // `Watts` is in watts, `AdapterVoltage` in millivolts.
            // → Current (mA) = (Watts × 1000) ÷ (Voltage_mV ÷ 1000)
            //                = Watts × 1_000_000 ÷ Voltage_mV
            return Int((watts * 1_000_000.0 / voltageMV).rounded())
        }
        return nil
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

    /// 1 minute → 60 seconds. Used for the IOPSGetTimeRemainingEstimate
    /// → minutes conversion (the IOPS API returns CFTimeInterval in
    /// seconds; Manifold's UI surfaces minutes).
    static let secondsPerMinute: Int = 60

    /// Constant-current → constant-voltage transition percent in the
    /// instant time-until-full model. Empirical fit for Apple-silicon
    /// MagSafe / USB-C PD chargers — the cell holds full charge
    /// current up to roughly 80 %, then ramps down through the CV
    /// tail.
    static let cvStartPercent: Int = 80

    /// Time-per-percent multiplier at 100 % in the CV phase, used
    /// to approximate the exponential current ramp-down. Linear
    /// interpolation from 1.0× at `cvStartPercent` to this value at
    /// 100 %; the model takes the average over the remaining CV span.
    /// 2.5× is the empirical value that best reproduces
    /// `IOPSGetTimeRemainingEstimate` at typical 80 %–95 % charge
    /// states on M-series Macs.
    static let cvCeilingMultiplier: Double = 2.5

    /// Sanity ceiling for instant time-remaining estimates. 24 hours
    /// is well past any reasonable battery / charger combination —
    /// any computed value above this is firmware noise (e.g. a
    /// near-zero current draw at 1 % capacity), so we clamp.
    static let maxReasonableMinutes: Int = 24 * 60
}
