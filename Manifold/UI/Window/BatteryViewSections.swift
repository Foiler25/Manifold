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
// BatteryViewSections.swift
//
// Phase 18 — five card subviews rendered inside the Battery tab:
//   1. ChargeBannerSection (large %, "Until full / Until empty",
//      charge-state pill, segmented capacity bar)
//   2. BatteryHealthSection (health %, cycleCount, condition badge,
//      info popover button)
//   3. TemperatureSection (°C primary + °F secondary, color-graded,
//      info popover button)
//   4. PowerElectricalSection (W, V, signed mA + charging arrow,
//      info popover button)
//   5. CapacityDetailsSection (Remaining / Full charge / Design mAh,
//      health % ratio next to Full charge, info popover button)
//
// Every section header has an info `(i)` button that opens a SwiftUI
// `.popover(isPresented:)` (per Q15 — NOT NSPopover; the AppKit
// popover is reserved for the menu-bar slot). The popovers explain
// what each metric means in Manifold-voice copy (window.battery.info.*
// keys per §20.8).

import SwiftUI
import ManifoldKit

// MARK: - 1. Charge Banner

struct ChargeBannerSection: View {
    let battery: BatteryInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Large monospaced percent + charge-state pill.
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("\(battery.chargePercent)%")
                    .font(.system(size: 56, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.manifoldText)
                ChargeStatePill(state: battery.chargeState)
                Spacer()
            }

            // Subtitle: time-until-full or time-until-empty depending
            // on charge state. Falls back to a static "Fully charged"
            // when isFullyCharged is true and no time field is set.
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Segmented capacity bar — 10 segments, each lit if the
            // chargePercent crosses its boundary. Reads as a static
            // "battery icon" representation of the same percentage
            // for at-a-glance pickup.
            CapacityBar(percent: battery.chargePercent, isCharging: battery.chargeState == .charging)
        }
    }

    /// "Until full in 24 minutes" / "Until empty in 3 hours 15 minutes" /
    /// "Fully charged" / "Plugged in, not charging".
    ///
    /// `DateComponentsFormatter` does the localized minutes →
    /// "1 hour 24 minutes" conversion on every call. `formatString` is
    /// the format-key half of `String(localized:)` so pluralization +
    /// language fallback land via the catalog.
    private var subtitle: String {
        switch battery.chargeState {
        case .fullyCharged:
            return NSLocalizedString("window.battery.fullyCharged", comment: "")
        case .charging:
            if let minutes = battery.timeUntilFullMinutes,
               let formatted = formatMinutes(minutes) {
                return String.localizedStringWithFormat(
                    NSLocalizedString("window.battery.timeUntilFull", comment: ""),
                    formatted
                )
            }
            return NSLocalizedString(battery.chargeState.labelKey, comment: "")
        case .discharging:
            if let minutes = battery.timeUntilEmptyMinutes,
               let formatted = formatMinutes(minutes) {
                return String.localizedStringWithFormat(
                    NSLocalizedString("window.battery.timeUntilEmpty", comment: ""),
                    formatted
                )
            }
            return NSLocalizedString(battery.chargeState.labelKey, comment: "")
        case .notCharging, .unknown:
            return NSLocalizedString(battery.chargeState.labelKey, comment: "")
        }
    }

    private func formatMinutes(_ minutes: Int) -> String? {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .full
        return formatter.string(from: TimeInterval(minutes * BatteryViewSectionsConstants.secondsPerMinute))
    }
}

/// Charge-state pill — colored capsule matching the
/// `DiagnosticBadge` shape (per the SPEC §20 plan).
struct ChargeStatePill: View {
    let state: BatteryInfo.ChargeState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.caption2.weight(.semibold))
            Text(LocalizedStringKey(state.labelKey))
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint, in: Capsule())
    }

    private var iconName: String {
        switch state {
        case .charging:      return "bolt.fill"
        case .fullyCharged:  return "checkmark.circle.fill"
        case .discharging:   return "arrow.down"
        case .notCharging:   return "pause"
        case .unknown:       return "questionmark"
        }
    }

    private var tint: Color {
        switch state {
        case .charging, .fullyCharged: return Color.manifoldAccent
        case .discharging:             return .secondary
        case .notCharging:             return Color.manifoldWarning
        case .unknown:                 return .secondary
        }
    }
}

/// Segmented "battery icon" capacity bar. 10 segments, lit per 10%.
/// When charging, the bar tints accent green; when discharging or on
/// battery, it tints the default text color so it doesn't fight the
/// charge-state pill for attention.
struct CapacityBar: View {
    let percent: Int
    let isCharging: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<BatteryViewSectionsConstants.capacityBarSegments, id: \.self) { index in
                Rectangle()
                    .fill(fillColor(for: index))
                    .frame(height: BatteryViewSectionsConstants.capacityBarHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func fillColor(for index: Int) -> Color {
        let threshold = (index + 1) * (BatteryViewSectionsConstants.percentScale
                                       / BatteryViewSectionsConstants.capacityBarSegments)
        if percent >= threshold {
            return isCharging ? Color.manifoldAccent : Color.manifoldText
        }
        return Color.manifoldCard
    }
}

// MARK: - 2. Battery Health

struct BatteryHealthSection: View {
    let battery: BatteryInfo

    @State private var isInfoShown: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BatterySectionHeader(
                titleKey: "window.battery.section.health",
                infoTitleKey: "window.battery.info.health.title",
                infoBodyKey: "window.battery.info.health.body",
                isShown: $isInfoShown
            )
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("\(battery.healthPercent)%")
                    .font(.title.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.manifoldText)
                ConditionBadge(condition: battery.healthCondition)
                Spacer()
            }
            BatteryDetailRow(
                labelKey: "window.battery.field.cycleCount",
                value: String(battery.cycleCount)
            )
        }
    }
}

/// Health-condition pill rendered next to the health %.
struct ConditionBadge: View {
    let condition: BatteryInfo.HealthCondition

    var body: some View {
        Text(LocalizedStringKey(condition.labelKey))
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint, in: Capsule())
    }

    private var tint: Color {
        switch condition {
        case .excellent, .good: return Color.manifoldAccent
        case .fair:             return Color.manifoldWarning
        case .poor, .veryPoor:  return Color.manifoldCritical
        }
    }
}

// MARK: - 3. Temperature

struct TemperatureSection: View {
    let battery: BatteryInfo

    @State private var isInfoShown: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BatterySectionHeader(
                titleKey: "window.battery.section.temperature",
                infoTitleKey: "window.battery.info.temperature.title",
                infoBodyKey: "window.battery.info.temperature.body",
                isShown: $isInfoShown
            )
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(String(format: "%.1f°C", battery.temperatureCelsius))
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(temperatureColor)
                Text(String(format: "(%.1f°F)", celsiusToFahrenheit(battery.temperatureCelsius)))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    /// Color-graded threshold readouts. <30°C reads as healthy accent
    /// green; 30–40°C as default text (ordinary warm operation);
    /// 40–45°C as warning amber; ≥45°C as critical red. Matches the
    /// rough contour of macOS's own battery temperature warnings.
    private var temperatureColor: Color {
        let c = battery.temperatureCelsius
        switch c {
        case ..<BatteryViewSectionsConstants.temperatureWarmStart:
            return Color.manifoldAccent
        case BatteryViewSectionsConstants.temperatureWarmStart..<BatteryViewSectionsConstants.temperatureWarningStart:
            return Color.manifoldText
        case BatteryViewSectionsConstants.temperatureWarningStart..<BatteryViewSectionsConstants.temperatureCriticalStart:
            return Color.manifoldWarning
        default:
            return Color.manifoldCritical
        }
    }

    private func celsiusToFahrenheit(_ c: Double) -> Double {
        c * BatteryViewSectionsConstants.fahrenheitScale + BatteryViewSectionsConstants.fahrenheitOffset
    }
}

// MARK: - 4. Power & Electrical

struct PowerElectricalSection: View {
    let battery: BatteryInfo

    @State private var isInfoShown: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BatterySectionHeader(
                titleKey: "window.battery.section.power",
                infoTitleKey: "window.battery.info.power.title",
                infoBodyKey: "window.battery.info.power.body",
                isShown: $isInfoShown
            )
            BatteryDetailRow(
                labelKey: "window.battery.field.power",
                value: String(format: "%.2f W", battery.powerWatts)
            )
            BatteryDetailRow(
                labelKey: "window.battery.field.voltage",
                value: String(format: "%.2f V", battery.voltageVolts)
            )
            HStack(alignment: .firstTextBaseline) {
                Text("window.battery.field.current")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if battery.amperageMilliamps > 0 {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.manifoldAccent)
                } else if battery.amperageMilliamps < 0 {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(String(format: "%+d mA", battery.amperageMilliamps))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.manifoldText)
            }
        }
    }
}

// MARK: - 5. Capacity Details

struct CapacityDetailsSection: View {
    let battery: BatteryInfo

    @State private var isInfoShown: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BatterySectionHeader(
                titleKey: "window.battery.section.capacity",
                infoTitleKey: "window.battery.info.capacity.title",
                infoBodyKey: "window.battery.info.capacity.body",
                isShown: $isInfoShown
            )
            BatteryDetailRow(
                labelKey: "window.battery.field.remaining",
                value: String(format: "%d mAh", battery.currentCapacityMAh)
            )
            HStack(alignment: .firstTextBaseline) {
                Text("window.battery.field.fullCharge")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%d mAh (%d%%)", battery.nominalCapacityMAh, battery.healthPercent))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.manifoldText)
            }
            BatteryDetailRow(
                labelKey: "window.battery.field.design",
                value: String(format: "%d mAh", battery.designCapacityMAh)
            )
        }
    }
}

// MARK: - Shared section header

/// Section header with a title in caption smallcaps + an `(i)` info
/// button that opens a SwiftUI popover (per Q15 — NOT NSPopover; the
/// AppKit popover is reserved for the menu-bar slot).
struct BatterySectionHeader: View {
    let titleKey: LocalizedStringKey
    let infoTitleKey: LocalizedStringKey
    let infoBodyKey: LocalizedStringKey
    @Binding var isShown: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(titleKey)
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
            Button {
                isShown.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isShown) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(infoTitleKey)
                        .font(.headline)
                    Text(infoBodyKey)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(width: BatteryViewSectionsConstants.infoPopoverWidth)
                .padding()
            }
            Spacer()
        }
    }
}

// MARK: - Shared detail row

/// Standardized "label → value" row matching `PowerView.detailRow`'s
/// shape (caption-secondary label, monospaced value, tail truncation
/// with full-text help on hover).
struct BatteryDetailRow: View {
    let labelKey: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(labelKey)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Color.manifoldText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(value)
        }
    }
}

// MARK: - Constants

enum BatteryViewSectionsConstants {
    /// Number of segments in the capacity bar. 10 segments → each lit
    /// per 10% of charge.
    static let capacityBarSegments: Int = 10

    /// Per-segment fixed height in points. Sized to read as a chunky
    /// "battery icon" indicator at the tab's typical width.
    static let capacityBarHeight: CGFloat = 16

    /// 0...100 percent scale (Int) — used so the per-segment threshold
    /// math stays in integer arithmetic.
    static let percentScale: Int = 100

    /// `1 minute → 60 seconds` for `DateComponentsFormatter` round-trips.
    static let secondsPerMinute: Int = 60

    /// Color-grading thresholds for `TemperatureSection`. Below 30°C
    /// reads as healthy; 30–40 ordinary; 40–45 warning; ≥45 critical.
    /// Numbers reflect the rough contour of macOS's own battery
    /// temperature alerts (no public API; observed empirically).
    static let temperatureWarmStart: Double = 30
    static let temperatureWarningStart: Double = 40
    static let temperatureCriticalStart: Double = 45

    /// Celsius → Fahrenheit scale + offset.
    static let fahrenheitScale: Double = 1.8
    static let fahrenheitOffset: Double = 32

    /// Width of the SwiftUI info popovers attached to each section
    /// header. Matches the readable-line-length guideline (~60 ch) so
    /// the body copy doesn't read as a single long line.
    static let infoPopoverWidth: CGFloat = 320
}
