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

        // AvgTimeToFull = 65535 → sentinel → nil.
        XCTAssertNil(info.timeUntilFullMinutes)

        // AvgTimeToEmpty = 1385 → 1385 minutes.
        XCTAssertEqual(info.timeUntilEmptyMinutes, 1385)

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

        // AvgTimeToFull = 65535 → nil; AvgTimeToEmpty = 195.
        XCTAssertNil(info.timeUntilFullMinutes)
        XCTAssertEqual(info.timeUntilEmptyMinutes, 195)

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

    // MARK: - Time-remaining sentinels

    /// AvgTimeToFull = 0 → nil ("not estimable yet" sentinel).
    func test_timeUntilFull_zero_isNil() {
        let properties = makeBaseProperties(overrides: [
            "AvgTimeToFull": NSNumber(value: 0)
        ])
        XCTAssertNil(BatterySnapshotReader.parse(properties: properties, at: Date())?.timeUntilFullMinutes)
    }

    /// AvgTimeToFull < 0 → nil (defensive against signed firmware).
    func test_timeUntilFull_negative_isNil() {
        let properties = makeBaseProperties(overrides: [
            "AvgTimeToFull": NSNumber(value: -1)
        ])
        XCTAssertNil(BatterySnapshotReader.parse(properties: properties, at: Date())?.timeUntilFullMinutes)
    }

    /// AvgTimeToFull = 65535 → nil ("uninitialized" sentinel).
    func test_timeUntilFull_sentinelValue_isNil() {
        let properties = makeBaseProperties(overrides: [
            "AvgTimeToFull": NSNumber(value: 65535)
        ])
        XCTAssertNil(BatterySnapshotReader.parse(properties: properties, at: Date())?.timeUntilFullMinutes)
    }

    /// AvgTimeToFull > 65535 → still nil (anything ≥ sentinel).
    func test_timeUntilFull_aboveSentinel_isNil() {
        let properties = makeBaseProperties(overrides: [
            "AvgTimeToFull": NSNumber(value: 99999)
        ])
        XCTAssertNil(BatterySnapshotReader.parse(properties: properties, at: Date())?.timeUntilFullMinutes)
    }

    /// Real value preserved.
    func test_timeUntilFull_realValue_preserved() {
        let properties = makeBaseProperties(overrides: [
            "AvgTimeToFull": NSNumber(value: 24)
        ])
        XCTAssertEqual(BatterySnapshotReader.parse(properties: properties, at: Date())?.timeUntilFullMinutes, 24)
    }

    /// Same sentinel rules apply to AvgTimeToEmpty.
    func test_timeUntilEmpty_sentinelValue_isNil() {
        let properties = makeBaseProperties(overrides: [
            "AvgTimeToEmpty": NSNumber(value: 65535)
        ])
        XCTAssertNil(BatterySnapshotReader.parse(properties: properties, at: Date())?.timeUntilEmptyMinutes)
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
