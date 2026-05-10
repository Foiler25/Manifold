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
// BatterySnapshotReaderTests.swift
//
// Phase 18 — fixture-based, IOKit-free. Targets the pure
// `parse(properties:at:)` entry point with captured plist fixtures so
// the test suite never touches live hardware. Two fixtures:
//   - `AppleSmartBattery_Healthy.plist` — captured live via the
//     DEBUG `dumpProperties(to:)` helper on this developer machine.
//   - `AppleSmartBattery_Aged.plist` — synthetic edit
//     (NominalChargeCapacity halved, CycleCount 1200, capacity at
//     38%, discharging) to exercise the Poor / Very Poor health
//     bands without acquiring an actually-degraded battery.

import XCTest
@testable import Manifold
import ManifoldKit
import Foundation

final class BatterySnapshotReaderTests: XCTestCase {

    // MARK: - Fixtures

    /// Load one of the captured plist fixtures from the test bundle.
    /// `Bundle.module` is provided automatically by SPM/Xcode for any
    /// resource in the test target.
    private func loadFixture(named name: String) throws -> [String: Any] {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: "plist") else {
            // Bundle.module fallback — Xcode's xctest bundles can land
            // resources at the bundle root rather than `module/`.
            let alt = Bundle(for: type(of: self)).url(forResource: name, withExtension: "plist")
                ?? URL(fileURLWithPath: "ManifoldTests/DiscoveryTests/Fixtures/\(name).plist")
            return try loadPlist(from: alt)
        }
        return try loadPlist(from: url)
    }

    private func loadPlist(from url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let dict = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw NSError(domain: "BatterySnapshotReaderTests",
                          code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "fixture \(url.lastPathComponent) is not a [String: Any] plist"])
        }
        return dict
    }

    // MARK: - Healthy fixture

    /// Healthy fixture: live-captured from a running MacBook on AC, fully
    /// charged. Expected dispatch: `.fullyCharged` (FullyCharged=1 wins
    /// the §20.3 priority order regardless of IsCharging / Amperage).
    func test_parse_healthyFixture_populatesAllFields() throws {
        let properties = try loadFixture(named: "AppleSmartBattery_Healthy")
        let stamp = Date(timeIntervalSince1970: 1_735_689_600)

        guard let info = BatterySnapshotReader.parse(properties: properties, at: stamp) else {
            XCTFail("parse returned nil for healthy fixture")
            return
        }

        // Charge percent from the live capture: 5125/5152 ≈ 99.5% → 100.
        XCTAssertGreaterThanOrEqual(info.chargePercent, 95, "Live healthy fixture should be near full")

        // FullyCharged=1 → .fullyCharged regardless of other fields.
        XCTAssertEqual(info.chargeState, .fullyCharged)
        XCTAssertTrue(info.isFullyCharged)
        XCTAssertTrue(info.isExternalConnected)

        // Health: NominalChargeCapacity / DesignCapacity × 100,
        // rounded. Live: 5302/6075 ≈ 87.27 → 87 (Good band).
        let expectedHealth = Int((Double(5302) / Double(6075) * 100).rounded())
        XCTAssertEqual(info.healthPercent, expectedHealth)
        XCTAssertEqual(info.healthCondition, .good)

        // Cycles match raw IOKit value.
        XCTAssertEqual(info.cycleCount, 478)

        // Temperature ÷ 100: 3094 → 30.94°C (within float tolerance).
        XCTAssertEqual(info.temperatureCelsius, 30.94, accuracy: 0.001)

        // Voltage ÷ 1000: 12687 → 12.687 V.
        XCTAssertEqual(info.voltageVolts, 12.687, accuracy: 0.001)

        // Amperage signed mA, raw: -141 (slow trickle on standby).
        XCTAssertEqual(info.amperageMilliamps, -141)

        // Power = V × |mA| / 1000.
        XCTAssertEqual(info.powerWatts, 12.687 * 141 / 1000, accuracy: 0.001)

        // FullyCharged + ExternalConnected: chargeState is
        // .fullyCharged, neither time-remaining branch fires.
        // (Old behavior pulled `AvgTimeToEmpty` even when plugged
        // in; the new instant-policy correctly suppresses it.)
        XCTAssertNil(info.timeUntilFullMinutes)
        XCTAssertNil(info.timeUntilEmptyMinutes)

        // Capacity values verbatim.
        XCTAssertEqual(info.designCapacityMAh, 6075)
        XCTAssertEqual(info.nominalCapacityMAh, 5302)
        XCTAssertEqual(info.currentCapacityMAh, 5125)

        // sampledAt round-trips the caller-supplied stamp.
        XCTAssertEqual(info.sampledAt, stamp)
    }

    // MARK: - Aged fixture

    /// Synthetic aged fixture: NominalChargeCapacity ≈ DesignCapacity / 2.
    /// Expected dispatch: `.discharging` (ExternalConnected=0).
    /// Health band: 50% → Very Poor.
    func test_parse_agedFixture_classifiesAsVeryPoor() throws {
        let properties = try loadFixture(named: "AppleSmartBattery_Aged")

        guard let info = BatterySnapshotReader.parse(properties: properties, at: Date()) else {
            XCTFail("parse returned nil for aged fixture")
            return
        }

        XCTAssertEqual(info.healthPercent, 50)
        XCTAssertEqual(info.healthCondition, .veryPoor)
        XCTAssertEqual(info.cycleCount, 1200)

        // ExternalConnected=0, IsCharging=0, FullyCharged=0 → .discharging.
        XCTAssertEqual(info.chargeState, .discharging)
        XCTAssertFalse(info.isExternalConnected)
        XCTAssertFalse(info.isFullyCharged)

        // Discharging: `timeUntilFullMinutes` always nil; instant
        // `timeUntilEmptyMinutes` = `currentCap ÷ |amps| × 60`. The
        // aged fixture has `AppleRawCurrentCapacity = 1154` and
        // `Amperage = -2150` → 1154 ÷ 2150 × 60 ≈ 32 min.
        XCTAssertNil(info.timeUntilFullMinutes)
        XCTAssertEqual(info.timeUntilEmptyMinutes, 32)

        // Negative amperage = discharging.
        XCTAssertEqual(info.amperageMilliamps, -2150)

        // Charge: 38% of (halved) max.
        XCTAssertEqual(info.chargePercent, 38)
    }

    // MARK: - Unit conversions

    /// Temperature 3240 → 32.4°C. Test with a constructed dict so the
    /// expected value can be computed from a single source of truth.
    func test_parse_temperatureUnitConversion() throws {
        let properties = makeBaseProperties(overrides: [
            "Temperature": NSNumber(value: 3240)
        ])
        let info = try XCTUnwrap(BatterySnapshotReader.parse(properties: properties, at: Date()))
        XCTAssertEqual(info.temperatureCelsius, 32.4, accuracy: 0.0001)
    }

    /// Voltage 12450 → 12.45 V.
    func test_parse_voltageUnitConversion() throws {
        let properties = makeBaseProperties(overrides: [
            "Voltage": NSNumber(value: 12450)
        ])
        let info = try XCTUnwrap(BatterySnapshotReader.parse(properties: properties, at: Date()))
        XCTAssertEqual(info.voltageVolts, 12.45, accuracy: 0.0001)
    }

    // MARK: - Charge-state dispatch (§20.3 priority table)

    func test_dispatch_fullyChargedWins() {
        let properties = makeBaseProperties(overrides: [
            "FullyCharged": NSNumber(value: 1),
            "IsCharging": NSNumber(value: 1),  // even with IsCharging set
            "ExternalConnected": NSNumber(value: 1)
        ])
        XCTAssertEqual(BatterySnapshotReader.parse(properties: properties, at: Date())?.chargeState,
                       .fullyCharged)
    }

    func test_dispatch_chargingNeedsBothChargingAndExternal() {
        let properties = makeBaseProperties(overrides: [
            "FullyCharged": NSNumber(value: 0),
            "IsCharging": NSNumber(value: 1),
            "ExternalConnected": NSNumber(value: 1)
        ])
        XCTAssertEqual(BatterySnapshotReader.parse(properties: properties, at: Date())?.chargeState,
                       .charging)
    }

    func test_dispatch_dischargingWhenNotExternal() {
        let properties = makeBaseProperties(overrides: [
            "FullyCharged": NSNumber(value: 0),
            "IsCharging": NSNumber(value: 0),
            "ExternalConnected": NSNumber(value: 0)
        ])
        XCTAssertEqual(BatterySnapshotReader.parse(properties: properties, at: Date())?.chargeState,
                       .discharging)
    }

    /// Plugged in but not charging — battery management throttle
    /// (e.g. macOS "Optimized Battery Charging" mode at >80%).
    func test_dispatch_notCharging_whenExternalAndNotChargingAndNotFull() {
        let properties = makeBaseProperties(overrides: [
            "FullyCharged": NSNumber(value: 0),
            "IsCharging": NSNumber(value: 0),
            "ExternalConnected": NSNumber(value: 1)
        ])
        XCTAssertEqual(BatterySnapshotReader.parse(properties: properties, at: Date())?.chargeState,
                       .notCharging)
    }

    /// Unplugged at 100 %: kernel keeps `FullyCharged = Yes` but
    /// `ExternalConnected = No`. `pmset` reports this as
    /// `100%; discharging; X:XX remaining` — we must agree.
    /// The dispatch table requires BOTH flags for `.fullyCharged`;
    /// otherwise we fall through to `.discharging`.
    func test_dispatch_fullyChargedButUnplugged_isDischarging() {
        let properties = makeBaseProperties(overrides: [
            "FullyCharged": NSNumber(value: 1),
            "IsCharging": NSNumber(value: 0),
            "ExternalConnected": NSNumber(value: 0),
            "Amperage": NSNumber(value: -500)
        ])
        XCTAssertEqual(BatterySnapshotReader.parse(properties: properties, at: Date())?.chargeState,
                       .discharging)
    }

    // MARK: - Time-remaining instant fallback policy
    //
    // The parse path prefers `IOPSGetTimeRemainingEstimate()`'s
    // smoothed value when one is available (passed in via the
    // `smoothedTimeUntilXMinutes` parameters in production). When
    // those are nil — the IOPS smoother is calibrating — the parser
    // falls through to an instant calculation derived from the
    // battery's current draw. These tests exercise the fallback
    // path; the smoothed-override path is straight assignment and
    // doesn't need its own test.

    /// Charging at a reasonable rate → curve-adjusted instant
    /// estimate appears (no IOPS override here).
    func test_timeUntilFull_chargingFallsBackToInstantEstimate() {
        let properties = makeBaseProperties(overrides: [
            "IsCharging": NSNumber(value: 1),
            "ExternalConnected": NSNumber(value: 1),
            "Amperage": NSNumber(value: 1000),
            "AppleRawCurrentCapacity": NSNumber(value: 4500),
            "AppleRawMaxCapacity": NSNumber(value: 5400)
        ])
        let info = BatterySnapshotReader.parse(properties: properties, at: Date())
        XCTAssertNotNil(info?.timeUntilFullMinutes)
        XCTAssertGreaterThan(info?.timeUntilFullMinutes ?? 0, 0)
    }

    /// Externally connected but `IsCharging = No` AND no current
    /// flow (e.g. Optimized Battery Charging holding) → no instant
    /// time-until-full. Without a current rate there's nothing to
    /// project from.
    func test_timeUntilFull_notChargingZeroCurrent_isNil() {
        let properties = makeBaseProperties(overrides: [
            "IsCharging": NSNumber(value: 0),
            "ExternalConnected": NSNumber(value: 1),
            "Amperage": NSNumber(value: 0)
        ])
        XCTAssertNil(BatterySnapshotReader.parse(properties: properties, at: Date())?.timeUntilFullMinutes)
    }

    /// Externally connected, `IsCharging = No` (PD still negotiating)
    /// but current is already flowing in → instant estimate fires.
    /// Covers the gap between `ExternalConnected` flipping (immediate
    /// on plug-in) and `IsCharging` flipping (after PD negotiation).
    func test_timeUntilFull_notChargingButCurrentFlowing_appears() {
        let properties = makeBaseProperties(overrides: [
            "IsCharging": NSNumber(value: 0),
            "ExternalConnected": NSNumber(value: 1),
            "Amperage": NSNumber(value: 1000)
        ])
        let info = BatterySnapshotReader.parse(properties: properties, at: Date())
        XCTAssertNotNil(info?.timeUntilFullMinutes)
        XCTAssertGreaterThan(info?.timeUntilFullMinutes ?? 0, 0)
    }

    /// Plugged in, `InstantAmperage = 0` (Optimized Battery Charging
    /// is holding the cell), but `AdapterDetails.Current` is
    /// populated. The parser uses the adapter's rated current as a
    /// fallback so the user sees a real estimate immediately rather
    /// than waiting on macOS's smoother.
    func test_timeUntilFull_zeroAmperageWithAdapterCurrent_usesFallback() {
        var properties = makeBaseProperties(overrides: [
            "IsCharging": NSNumber(value: 0),
            "ExternalConnected": NSNumber(value: 1),
            "Amperage": NSNumber(value: 0)
        ])
        properties["AdapterDetails"] = [
            "Current": 3000,  // 65 W MagSafe rated at ~3.0 A
            "Watts": 65,
            "AdapterVoltage": 20000
        ] as [String: Any]
        let info = BatterySnapshotReader.parse(properties: properties, at: Date())
        XCTAssertNotNil(info?.timeUntilFullMinutes,
                        "Adapter rated current should fill in for zero InstantAmperage")
        XCTAssertGreaterThan(info?.timeUntilFullMinutes ?? 0, 0)
    }

    /// Same as above but `AdapterDetails.Current` is missing — the
    /// parser computes `Watts × 1000 / AdapterVoltage` from the
    /// other two fields and falls back on that.
    func test_timeUntilFull_zeroAmperageWithAdapterWattsOnly_usesFallback() {
        var properties = makeBaseProperties(overrides: [
            "IsCharging": NSNumber(value: 0),
            "ExternalConnected": NSNumber(value: 1),
            "Amperage": NSNumber(value: 0)
        ])
        // Watts × 1_000_000 ÷ AdapterVoltage_mV = 65 × 1_000_000 ÷ 20000
        // ≈ 3250 mA implied current.
        properties["AdapterDetails"] = [
            "Watts": 65,
            "AdapterVoltage": 20000
        ] as [String: Any]
        let info = BatterySnapshotReader.parse(properties: properties, at: Date())
        XCTAssertNotNil(info?.timeUntilFullMinutes)
        XCTAssertGreaterThan(info?.timeUntilFullMinutes ?? 0, 0)
    }

    /// Plugged in, `InstantAmperage = 0`, AND no `AdapterDetails` →
    /// no estimate possible. Defensive path covering hardware
    /// (third-party non-PD bricks) where the adapter publishes
    /// nothing.
    func test_timeUntilFull_zeroAmperageNoAdapterDetails_isNil() {
        let properties = makeBaseProperties(overrides: [
            "IsCharging": NSNumber(value: 0),
            "ExternalConnected": NSNumber(value: 1),
            "Amperage": NSNumber(value: 0)
        ])
        XCTAssertNil(BatterySnapshotReader.parse(properties: properties, at: Date())?.timeUntilFullMinutes)
    }

    /// On battery (`ExternalConnected = 0`) → no time-until-full.
    func test_timeUntilFull_externalDisconnected_isNil() {
        let properties = makeBaseProperties(overrides: [
            "IsCharging": NSNumber(value: 0),
            "ExternalConnected": NSNumber(value: 0),
            "Amperage": NSNumber(value: -800)
        ])
        XCTAssertNil(BatterySnapshotReader.parse(properties: properties, at: Date())?.timeUntilFullMinutes)
    }

    /// Discharging (negative current, no AC) → instant time-until-
    /// empty appears.
    func test_timeUntilEmpty_dischargingFallsBackToInstantEstimate() {
        let properties = makeBaseProperties(overrides: [
            "IsCharging": NSNumber(value: 0),
            "ExternalConnected": NSNumber(value: 0),
            "Amperage": NSNumber(value: -2150),
            "AppleRawCurrentCapacity": NSNumber(value: 1154),
            "AppleRawMaxCapacity": NSNumber(value: 3037)
        ])
        let info = BatterySnapshotReader.parse(properties: properties, at: Date())
        // 1154 mAh ÷ 2150 mA × 60 ≈ 32 min.
        XCTAssertEqual(info?.timeUntilEmptyMinutes, 32)
    }

    /// Plugged in → no time-until-empty even with negative current
    /// (occasional trickle while topped off).
    func test_timeUntilEmpty_externalConnected_isNil() {
        let properties = makeBaseProperties(overrides: [
            "ExternalConnected": NSNumber(value: 1),
            "Amperage": NSNumber(value: -100)
        ])
        XCTAssertNil(BatterySnapshotReader.parse(properties: properties, at: Date())?.timeUntilEmptyMinutes)
    }

    /// On battery with `InstantAmperage` reported as positive — some
    /// Apple-silicon Macs publish a positive magnitude while on
    /// battery. The parser treats any non-zero magnitude as drain
    /// when external power is disconnected, so a real estimate
    /// appears immediately rather than waiting on macOS's smoother.
    func test_timeUntilEmpty_positiveAmperageOnBattery_usesMagnitude() {
        let properties = makeBaseProperties(overrides: [
            "ExternalConnected": NSNumber(value: 0),
            "IsCharging": NSNumber(value: 0),
            "Amperage": NSNumber(value: 449),
            "AppleRawCurrentCapacity": NSNumber(value: 4374),
            "AppleRawMaxCapacity": NSNumber(value: 5016)
        ])
        let info = BatterySnapshotReader.parse(properties: properties, at: Date())
        XCTAssertNotNil(info?.timeUntilEmptyMinutes)
        // 4374 mAh ÷ |449 mA| × 60 ≈ 585 min (low drain on a quiet
        // machine). Allow ±5 min of rounding noise.
        XCTAssertEqual(info?.timeUntilEmptyMinutes ?? -1, 585, accuracy: 5)
    }

    // MARK: - Instant time-until-full helper (CC + CV curve)

    /// Below 80 % the model is purely linear: `mAh_remaining / mA × 60`.
    /// At 50 % charge with FCC = 6000 mAh and 2000 mA: half the CC
    /// region remains (50→80, 30 % of FCC = 1800 mAh), the entire
    /// CV region (20 %, 1200 mAh) carries the average CV multiplier
    /// (1.75× — see the spec). Result: 1800 + 1200 × 1.75 = 3900
    /// mAh-equivalent ÷ 2000 mA × 60 ≈ 117 min.
    func test_instantTimeUntilFull_belowCV_appliesCurveAhead() {
        let result = BatterySnapshotReader.instantTimeUntilFullMinutes(
            chargePercent: 50,
            fullChargeCapacityMAh: 6000,
            instantAmperageMilliamps: 2000
        )
        XCTAssertNotNil(result)
        // Allow ±2 min wiggle for rounding within the model.
        XCTAssertEqual(result ?? -1, 117, accuracy: 2)
    }

    /// At the CV start (80 %), the remaining 20 % all sits in CV
    /// with average multiplier 1.75×: 6000 × 0.20 × 1.75 = 2100
    /// mAh-equivalent ÷ 2000 mA × 60 ≈ 63 min.
    func test_instantTimeUntilFull_atCVStart_appliesAverageMultiplier() {
        let result = BatterySnapshotReader.instantTimeUntilFullMinutes(
            chargePercent: 80,
            fullChargeCapacityMAh: 6000,
            instantAmperageMilliamps: 2000
        )
        XCTAssertEqual(result ?? -1, 63, accuracy: 2)
    }

    /// 90 % matches the Apple-silicon real-world data point that
    /// motivated the curve: 6075 mAh FCC at 2100 mA charge current,
    /// kernel reports ~37 min. The curve-adjusted instant estimate
    /// should land within a few minutes of that.
    func test_instantTimeUntilFull_90pct_matchesKernelEstimate() {
        let result = BatterySnapshotReader.instantTimeUntilFullMinutes(
            chargePercent: 90,
            fullChargeCapacityMAh: 6075,
            instantAmperageMilliamps: 2100
        )
        // Kernel publishes 37 min in production. Within ±5 min is
        // close enough for a curve-fit instant fallback.
        XCTAssertEqual(result ?? -1, 37, accuracy: 5)
    }

    /// At 100 % the model returns 0 (already full).
    func test_instantTimeUntilFull_atFull_returnsZero() {
        let result = BatterySnapshotReader.instantTimeUntilFullMinutes(
            chargePercent: 100,
            fullChargeCapacityMAh: 6000,
            instantAmperageMilliamps: 100
        )
        XCTAssertEqual(result, 0)
    }

    /// Zero current → nil (prevents divide-by-zero; semantically
    /// "we're not actually charging right now").
    func test_instantTimeUntilFull_zeroCurrent_isNil() {
        let result = BatterySnapshotReader.instantTimeUntilFullMinutes(
            chargePercent: 50,
            fullChargeCapacityMAh: 6000,
            instantAmperageMilliamps: 0
        )
        XCTAssertNil(result)
    }

    /// Negative current → nil (we're discharging, not charging).
    func test_instantTimeUntilFull_negativeCurrent_isNil() {
        let result = BatterySnapshotReader.instantTimeUntilFullMinutes(
            chargePercent: 50,
            fullChargeCapacityMAh: 6000,
            instantAmperageMilliamps: -1000
        )
        XCTAssertNil(result)
    }

    /// Zero `InstantAmperage` + positive `fallbackChargingCurrentMA`
    /// → uses the fallback to compute. Mirrors the OBC-hold case.
    func test_instantTimeUntilFull_zeroCurrentWithFallback_usesFallback() {
        let result = BatterySnapshotReader.instantTimeUntilFullMinutes(
            chargePercent: 50,
            fullChargeCapacityMAh: 6000,
            instantAmperageMilliamps: 0,
            fallbackChargingCurrentMA: 2000
        )
        XCTAssertNotNil(result)
        // 50 % at 2000 mA with the curve: ~117 min, same as the
        // direct-current 50 % case above.
        XCTAssertEqual(result ?? -1, 117, accuracy: 2)
    }

    /// Live current > 0 takes precedence over any fallback —
    /// fallback only fills in for zero/negative current.
    func test_instantTimeUntilFull_liveCurrentBeatsFallback() {
        let withFallback = BatterySnapshotReader.instantTimeUntilFullMinutes(
            chargePercent: 50,
            fullChargeCapacityMAh: 6000,
            instantAmperageMilliamps: 4000,
            fallbackChargingCurrentMA: 1000  // would give a much longer estimate
        )
        let withoutFallback = BatterySnapshotReader.instantTimeUntilFullMinutes(
            chargePercent: 50,
            fullChargeCapacityMAh: 6000,
            instantAmperageMilliamps: 4000
        )
        XCTAssertEqual(withFallback, withoutFallback,
                       "Fallback must not influence the result when live current is available")
    }

    /// Zero FCC → nil (defensive; firmware glitch case).
    func test_instantTimeUntilFull_zeroFCC_isNil() {
        let result = BatterySnapshotReader.instantTimeUntilFullMinutes(
            chargePercent: 50,
            fullChargeCapacityMAh: 0,
            instantAmperageMilliamps: 1000
        )
        XCTAssertNil(result)
    }

    // MARK: - Instant time-until-empty helper (linear)

    /// Linear: 3000 mAh ÷ 1500 mA × 60 = 120 min.
    func test_instantTimeUntilEmpty_linear() {
        let result = BatterySnapshotReader.instantTimeUntilEmptyMinutes(
            currentCapacityMAh: 3000,
            instantAmperageMilliamps: -1500
        )
        XCTAssertEqual(result, 120)
    }

    /// Sign-agnostic: positive `InstantAmperage` is treated as
    /// drain magnitude (some Apple-silicon Macs publish a positive
    /// value while on battery). Caller handles the
    /// `!isExternalConnected` precondition; the helper itself is
    /// just doing the math.
    func test_instantTimeUntilEmpty_positiveCurrent_treatedAsMagnitude() {
        // 3000 mAh ÷ |+500 mA| × 60 = 360 min. Identical to the
        // negative-amperage path above.
        let result = BatterySnapshotReader.instantTimeUntilEmptyMinutes(
            currentCapacityMAh: 3000,
            instantAmperageMilliamps: 500
        )
        XCTAssertEqual(result, 360)
    }

    /// Zero current → nil (no rate to compute from).
    func test_instantTimeUntilEmpty_zeroCurrent_isNil() {
        let result = BatterySnapshotReader.instantTimeUntilEmptyMinutes(
            currentCapacityMAh: 3000,
            instantAmperageMilliamps: 0
        )
        XCTAssertNil(result)
    }

    /// Zero capacity → nil (battery is empty already; no estimate).
    func test_instantTimeUntilEmpty_zeroCapacity_isNil() {
        let result = BatterySnapshotReader.instantTimeUntilEmptyMinutes(
            currentCapacityMAh: 0,
            instantAmperageMilliamps: -1500
        )
        XCTAssertNil(result)
    }

    // MARK: - Required-field guards

    /// Missing DesignCapacity → nil. Without it the health % formula
    /// has no denominator.
    func test_parse_missingDesignCapacity_returnsNil() {
        var properties = makeBaseProperties()
        properties.removeValue(forKey: "DesignCapacity")
        XCTAssertNil(BatterySnapshotReader.parse(properties: properties, at: Date()))
    }

    /// Zero DesignCapacity → nil (avoid divide-by-zero in healthPercent).
    func test_parse_zeroDesignCapacity_returnsNil() {
        let properties = makeBaseProperties(overrides: [
            "DesignCapacity": NSNumber(value: 0)
        ])
        XCTAssertNil(BatterySnapshotReader.parse(properties: properties, at: Date()))
    }

    /// Zero AppleRawMaxCapacity → nil (chargePercent denominator).
    func test_parse_zeroMaxCapacity_returnsNil() {
        let properties = makeBaseProperties(overrides: [
            "AppleRawMaxCapacity": NSNumber(value: 0)
        ])
        XCTAssertNil(BatterySnapshotReader.parse(properties: properties, at: Date()))
    }

    // MARK: - Helpers

    /// Build a baseline `[String: Any]` dict with every field the
    /// parser requires set to a sensible value. Tests override only
    /// the field they're exercising, so each test reads as a one-line
    /// substitution rather than a full dict literal.
    private func makeBaseProperties(overrides: [String: NSNumber] = [:]) -> [String: Any] {
        var properties: [String: Any] = [
            "DesignCapacity": NSNumber(value: 6000),
            "NominalChargeCapacity": NSNumber(value: 5400),
            "AppleRawCurrentCapacity": NSNumber(value: 4500),
            "AppleRawMaxCapacity": NSNumber(value: 5400),
            "CycleCount": NSNumber(value: 100),
            "IsCharging": NSNumber(value: 1),
            "FullyCharged": NSNumber(value: 0),
            "ExternalConnected": NSNumber(value: 1),
            "Temperature": NSNumber(value: 3000),
            "Voltage": NSNumber(value: 12000),
            "Amperage": NSNumber(value: 1000),
            "AvgTimeToFull": NSNumber(value: 30),
            "AvgTimeToEmpty": NSNumber(value: 0)
        ]
        for (key, value) in overrides {
            properties[key] = value
        }
        return properties
    }
}
