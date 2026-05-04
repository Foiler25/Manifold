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
// BatteryInfo.swift
//
// Phase 18 — pure data model for one battery snapshot. Lives in
// `ManifoldKit` (not the `Manifold` app target) so a future widget /
// snapshot phase can pick it up without changing the public type
// (per SPEC §20.1 + Q14).
//
// All wattage is computed from
// `voltageVolts × |amperageMilliamps| / 1000` so consumers don't have
// to. Capacity values stay raw mAh straight from the IORegistry — no
// conversion to mWh, since no current consumer asks for it.

// `public import Foundation` because `BatteryInfo.sampledAt: Date` is
// part of the public surface — the InternalImportsByDefault upcoming
// feature treats a plain `import Foundation` as internal, which would
// hide `Date` from the public init signature.
public import Foundation

/// Snapshot of battery state at a single sampling tick. Immutable +
/// `Codable` from day one so the snapshot machinery can serialize it
/// later without a layer migration.
public struct BatteryInfo: Sendable, Hashable, Codable {

    /// Charge-state dispatch. Derived from `IsCharging`, `FullyCharged`,
    /// `ExternalConnected`, and signed `Amperage` per SPEC §20.3.
    ///
    /// `.notCharging` covers the "plugged in but the battery management
    /// system is throttling charging" path — Apple silicon laptops do
    /// this routinely once the battery passes ~80% if "Optimized Battery
    /// Charging" is on. The user sees the explicit state in the UI
    /// rather than a misleading "discharging".
    public enum ChargeState: String, Sendable, Hashable, Codable, CaseIterable {
        case charging
        case fullyCharged
        case discharging
        case notCharging
        case unknown
    }

    /// Health-condition bands. Boundary classifier in
    /// `classify(healthPercent:)`. Bands per SPEC §20.3:
    /// Excellent ≥90, Good 80–89, Fair 70–79, Poor 60–69, VeryPoor <60.
    ///
    /// The bands match Apple's own "Battery Health" dispatch (System
    /// Settings → Battery) at the boundary points the macOS UI exposes.
    public enum HealthCondition: String, Sendable, Hashable, Codable, CaseIterable {
        case excellent
        case good
        case fair
        case poor
        case veryPoor

        /// Pure boundary classifier. `default` covers anything <60 AND
        /// any pathological negative value (defensive — IORegistry
        /// returns Int, but a `nominal/design` ratio can produce odd
        /// negatives if the firmware misreports).
        public static func classify(healthPercent: Int) -> HealthCondition {
            switch healthPercent {
            case 90...:    return .excellent
            case 80..<90:  return .good
            case 70..<80:  return .fair
            case 60..<70:  return .poor
            default:       return .veryPoor
            }
        }

        /// Localized string-catalog key suffix matching the
        /// `host.battery.health.condition.<rawValue>` pattern §20.8
        /// enumerates. Provided so call sites don't have to hand-build
        /// the key — keeps the coupling between the enum and the
        /// catalog one-place.
        public var labelKey: String {
            "host.battery.health.condition.\(rawValue)"
        }
    }

    // MARK: - Stored properties (per §20.1 / §20.3)

    /// Live charge percent, 0...100. Derived from `currentCapacity /
    /// AppleRawMaxCapacity × 100`, rounded.
    public let chargePercent: Int

    /// Composite charge-state per the §20.3 dispatch table.
    public let chargeState: ChargeState

    /// Battery health percent, 0...100. Derived from
    /// `nominalCapacityMAh / designCapacityMAh × 100`, rounded + clamped.
    /// A factory-fresh battery is 100; one that's lost 22% capacity is 78.
    public let healthPercent: Int

    /// Lifetime full charge cycles per `CycleCount`.
    public let cycleCount: Int

    /// Current battery temperature in °C. Raw IORegistry `Temperature`
    /// (centi-degrees, e.g. `3240`) divided by 100.
    public let temperatureCelsius: Double

    /// Bus voltage in volts. Raw IORegistry `Voltage` (millivolts, e.g.
    /// `12450`) divided by 1000.
    public let voltageVolts: Double

    /// Signed milliamps. `>0` charging, `<0` discharging. Per D18 / Q16
    /// the IORegistry `Amperage` (smoothed) feeds this — NOT
    /// `InstantAmperage`.
    public let amperageMilliamps: Int

    /// Computed power: `voltageVolts × |amperageMilliamps| / 1000`.
    /// Always non-negative; the sign is carried by `amperageMilliamps`.
    public let powerWatts: Double

    /// Manufacturer-rated capacity in mAh. Constant for the life of the
    /// battery.
    public let designCapacityMAh: Int

    /// Effective full-charge capacity in mAh. Declines over time; the
    /// numerator of `healthPercent`.
    public let nominalCapacityMAh: Int

    /// Live charge in mAh.
    public let currentCapacityMAh: Int

    /// Estimated minutes until fully charged. Nil when not charging,
    /// when the IOKit sentinel value (≤0 or ≥65535) is returned, or
    /// when the value is otherwise unreliable.
    public let timeUntilFullMinutes: Int?

    /// Estimated minutes until empty. Same nil semantics as
    /// `timeUntilFullMinutes`.
    public let timeUntilEmptyMinutes: Int?

    /// Whether `ExternalConnected == true` — wall power is plugged in.
    public let isExternalConnected: Bool

    /// Whether `FullyCharged == true` — the battery has reached its
    /// effective full-charge target (which is below 100% in optimized-
    /// charging mode).
    public let isFullyCharged: Bool

    /// Wall-clock timestamp when the snapshot was sampled. The sampler
    /// stamps this; `parse(properties:at:)` uses the caller-supplied
    /// `Date` so tests can pin a fixed value.
    public let sampledAt: Date

    /// Convenience computed property — same dispatch as
    /// `HealthCondition.classify(healthPercent:)`. Provided so call
    /// sites don't have to remember the static.
    public var healthCondition: HealthCondition {
        HealthCondition.classify(healthPercent: healthPercent)
    }

    // MARK: - Init

    public init(
        chargePercent: Int,
        chargeState: ChargeState,
        healthPercent: Int,
        cycleCount: Int,
        temperatureCelsius: Double,
        voltageVolts: Double,
        amperageMilliamps: Int,
        powerWatts: Double,
        designCapacityMAh: Int,
        nominalCapacityMAh: Int,
        currentCapacityMAh: Int,
        timeUntilFullMinutes: Int?,
        timeUntilEmptyMinutes: Int?,
        isExternalConnected: Bool,
        isFullyCharged: Bool,
        sampledAt: Date
    ) {
        self.chargePercent = chargePercent
        self.chargeState = chargeState
        self.healthPercent = healthPercent
        self.cycleCount = cycleCount
        self.temperatureCelsius = temperatureCelsius
        self.voltageVolts = voltageVolts
        self.amperageMilliamps = amperageMilliamps
        self.powerWatts = powerWatts
        self.designCapacityMAh = designCapacityMAh
        self.nominalCapacityMAh = nominalCapacityMAh
        self.currentCapacityMAh = currentCapacityMAh
        self.timeUntilFullMinutes = timeUntilFullMinutes
        self.timeUntilEmptyMinutes = timeUntilEmptyMinutes
        self.isExternalConnected = isExternalConnected
        self.isFullyCharged = isFullyCharged
        self.sampledAt = sampledAt
    }
}

// MARK: - Charge state localization

public extension BatteryInfo.ChargeState {
    /// Localized string-catalog key matching
    /// `host.battery.chargeState.<rawValue>` per §20.8.
    var labelKey: String {
        "host.battery.chargeState.\(rawValue)"
    }
}
