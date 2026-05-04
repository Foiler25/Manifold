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
// BatteryInfoTests.swift
//
// Phase 18 — pin the `HealthCondition.classify` boundary points and
// the `Codable` round trip. Both are public surface; renaming a case
// or shifting a band silently would orphan persisted preview data
// AND change which color band a given health % renders into.

import XCTest
@testable import ManifoldKit
import Foundation

final class BatteryInfoTests: XCTestCase {

    // MARK: - HealthCondition.classify boundaries

    func test_classify_atOneHundred_isExcellent() {
        XCTAssertEqual(BatteryInfo.HealthCondition.classify(healthPercent: 100), .excellent)
    }

    func test_classify_atNinety_isExcellent() {
        XCTAssertEqual(BatteryInfo.HealthCondition.classify(healthPercent: 90), .excellent)
    }

    func test_classify_atEightyNine_isGood() {
        XCTAssertEqual(BatteryInfo.HealthCondition.classify(healthPercent: 89), .good)
    }

    func test_classify_atEighty_isGood() {
        XCTAssertEqual(BatteryInfo.HealthCondition.classify(healthPercent: 80), .good)
    }

    func test_classify_atSeventyNine_isFair() {
        XCTAssertEqual(BatteryInfo.HealthCondition.classify(healthPercent: 79), .fair)
    }

    func test_classify_atSeventy_isFair() {
        XCTAssertEqual(BatteryInfo.HealthCondition.classify(healthPercent: 70), .fair)
    }

    func test_classify_atSixtyNine_isPoor() {
        XCTAssertEqual(BatteryInfo.HealthCondition.classify(healthPercent: 69), .poor)
    }

    func test_classify_atSixty_isPoor() {
        XCTAssertEqual(BatteryInfo.HealthCondition.classify(healthPercent: 60), .poor)
    }

    func test_classify_atFiftyNine_isVeryPoor() {
        XCTAssertEqual(BatteryInfo.HealthCondition.classify(healthPercent: 59), .veryPoor)
    }

    func test_classify_atZero_isVeryPoor() {
        XCTAssertEqual(BatteryInfo.HealthCondition.classify(healthPercent: 0), .veryPoor)
    }

    /// Defensive against a firmware misreport that produces a negative
    /// nominal/design ratio. Per `HealthCondition.classify`'s
    /// `default` branch, anything below 60 (including negatives) is
    /// `.veryPoor`.
    func test_classify_negativeValue_isVeryPoor() {
        XCTAssertEqual(BatteryInfo.HealthCondition.classify(healthPercent: -5), .veryPoor)
    }

    // MARK: - healthCondition computed property mirrors classify

    func test_healthCondition_computedProperty_matchesClassify() {
        let info = makeInfo(healthPercent: 85)
        XCTAssertEqual(info.healthCondition, .good)
        XCTAssertEqual(info.healthCondition,
                       BatteryInfo.HealthCondition.classify(healthPercent: 85))
    }

    // MARK: - Localization keys

    /// Catalog keys are what the View layer reads. Renaming a case
    /// without updating the catalog would silently fall back to the
    /// raw key on screen — the test pins the contract.
    func test_chargeState_labelKeys_areStable() {
        XCTAssertEqual(BatteryInfo.ChargeState.charging.labelKey,
                       "host.battery.chargeState.charging")
        XCTAssertEqual(BatteryInfo.ChargeState.fullyCharged.labelKey,
                       "host.battery.chargeState.fullyCharged")
        XCTAssertEqual(BatteryInfo.ChargeState.discharging.labelKey,
                       "host.battery.chargeState.discharging")
        XCTAssertEqual(BatteryInfo.ChargeState.notCharging.labelKey,
                       "host.battery.chargeState.notCharging")
        XCTAssertEqual(BatteryInfo.ChargeState.unknown.labelKey,
                       "host.battery.chargeState.unknown")
    }

    func test_healthCondition_labelKeys_areStable() {
        XCTAssertEqual(BatteryInfo.HealthCondition.excellent.labelKey,
                       "host.battery.health.condition.excellent")
        XCTAssertEqual(BatteryInfo.HealthCondition.good.labelKey,
                       "host.battery.health.condition.good")
        XCTAssertEqual(BatteryInfo.HealthCondition.fair.labelKey,
                       "host.battery.health.condition.fair")
        XCTAssertEqual(BatteryInfo.HealthCondition.poor.labelKey,
                       "host.battery.health.condition.poor")
        XCTAssertEqual(BatteryInfo.HealthCondition.veryPoor.labelKey,
                       "host.battery.health.condition.veryPoor")
    }

    // MARK: - Codable round trip

    /// Full struct round-trips through JSON without lossy fields.
    /// Catches a future `Codable` conformance bug (a custom encoder
    /// that drops a field, a key drift in CodingKeys).
    func test_codable_roundTrip_preservesAllFields() throws {
        let original = BatteryInfo(
            chargePercent: 84,
            chargeState: .charging,
            healthPercent: 96,
            cycleCount: 47,
            temperatureCelsius: 32.4,
            voltageVolts: 12.45,
            amperageMilliamps: 1234,
            powerWatts: 12.45 * 1.234,
            designCapacityMAh: 4380,
            nominalCapacityMAh: 4205,
            currentCapacityMAh: 3680,
            timeUntilFullMinutes: 24,
            timeUntilEmptyMinutes: nil,
            isExternalConnected: true,
            isFullyCharged: false,
            sampledAt: Date(timeIntervalSince1970: 1_735_689_600)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(BatteryInfo.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// Both optional time fields nil → still round-trips, and the
    /// decoded value's nil fields stay nil.
    func test_codable_roundTrip_nilTimeFields() throws {
        let original = makeInfo(
            chargeState: .discharging,
            timeUntilFull: nil,
            timeUntilEmpty: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BatteryInfo.self, from: data)
        XCTAssertNil(decoded.timeUntilFullMinutes)
        XCTAssertNil(decoded.timeUntilEmptyMinutes)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Helpers

    private func makeInfo(
        healthPercent: Int = 96,
        chargeState: BatteryInfo.ChargeState = .charging,
        timeUntilFull: Int? = 24,
        timeUntilEmpty: Int? = nil
    ) -> BatteryInfo {
        BatteryInfo(
            chargePercent: 84,
            chargeState: chargeState,
            healthPercent: healthPercent,
            cycleCount: 47,
            temperatureCelsius: 32.4,
            voltageVolts: 12.45,
            amperageMilliamps: 1234,
            powerWatts: 15.36,
            designCapacityMAh: 4380,
            nominalCapacityMAh: 4205,
            currentCapacityMAh: 3680,
            timeUntilFullMinutes: timeUntilFull,
            timeUntilEmptyMinutes: timeUntilEmpty,
            isExternalConnected: chargeState != .discharging,
            isFullyCharged: chargeState == .fullyCharged,
            sampledAt: Date(timeIntervalSince1970: 1_735_689_600)
        )
    }
}
