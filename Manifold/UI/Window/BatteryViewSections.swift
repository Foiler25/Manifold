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
//   1. ChargeBannerSection (large %, until-full/empty estimate,
//      charge-state pill, solid capacity bar)
//   2. BatteryHealthSection (health %, cycle count "X/1000", condition
//      badge, info popover button — leading colored status icon)
//   3. TemperatureSection (°C primary + °F secondary, thermometer
//      glyph, condition pill with subtitle, info popover button)
//   4. PowerElectricalSection (W, V, signed mA + charging arrow,
//      "Charging / Normal voltage" mini-status, info popover button)
//   5. CapacityDetailsSection (Remaining / Full charge / Design mAh,
//      thousands-separator formatting, color-coded by row, refresh
//      footnote, info popover button)
//
// All section headers carry a leading colored icon (green check for
// healthy, amber for warning, red for critical) so the user can scan
// per-section condition at a glance — matches the Juicy parity goal
// from the 2026-05-04 UX feedback. Every visible string is in
// `Localizable.xcstrings`; every color is a `Color.manifold*` token
// (no hardcoded values, per Reviewer rules).

import SwiftUI
import ManifoldKit

// MARK: - 1. Charge Banner

struct ChargeBannerSection: View {
    let battery: BatteryInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top row: percent on the left, "Until full / Until empty"
            // estimate on the right (or "∞" when fully charged).
            HStack(alignment: .firstTextBaseline) {
                Text("\(battery.chargePercent)%")
                    .font(.system(size: 48, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(percentTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer()
                untilLabel
            }

            // Charge-state pill stacked below the percent.
            ChargeStatePill(state: battery.chargeState)

            // Subtitle: time-until-full / time-until-empty / static
            // fallback. Decorated with a leading bolt when fully
            // charged so the dual signal (pill + caption) reads as
            // intentional rather than redundant.
            HStack(spacing: 6) {
                if battery.chargeState == .fullyCharged {
                    Image(systemName: "bolt.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.manifoldWarning)
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Solid proportional capacity bar. Charging or fully-
            // charged tints accent green; otherwise the default text
            // color so it doesn't fight the pill for attention.
            CapacityBar(percent: battery.chargePercent,
                        isAccentTinted: battery.chargeState == .charging
                                     || battery.chargeState == .fullyCharged)
                .padding(.top, 4)
        }
    }

    /// Percent color: green when charging or fully charged, default
    /// text color otherwise. Mirrors the capacity-bar tint so the
    /// hero number and the bar agree on the live signal.
    private var percentTint: Color {
        switch battery.chargeState {
        case .charging, .fullyCharged: return Color.manifoldAccent
        case .discharging:             return Color.manifoldText
        case .notCharging:             return Color.manifoldWarning
        case .unknown:                 return Color.manifoldText
        }
    }

    /// Right-aligned "UNTIL FULL / UNTIL EMPTY / ∞" caption. Pure
    /// caption-smallcaps — sized to read as supplementary metadata,
    /// not a competing headline.
    @ViewBuilder
    private var untilLabel: some View {
        VStack(alignment: .trailing, spacing: 2) {
            switch battery.chargeState {
            case .charging:
                Text("window.battery.untilFull.label")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                if let m = battery.timeUntilFullMinutes,
                   let s = Self.shortFormatter.string(from: TimeInterval(m * 60)) {
                    Text(s)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Color.manifoldText)
                }
            case .discharging:
                Text("window.battery.untilEmpty.label")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                if let m = battery.timeUntilEmptyMinutes,
                   let s = Self.shortFormatter.string(from: TimeInterval(m * 60)) {
                    Text(s)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Color.manifoldText)
                }
            case .fullyCharged:
                Text("window.battery.untilFull.label")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                Text("∞")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            case .notCharging, .unknown:
                EmptyView()
            }
        }
    }

    /// Compact `1h 24m` formatter for the right-aligned banner caption.
    /// Different from the long-form formatter `subtitle` uses (which
    /// favors localization completeness over compactness).
    private static let shortFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .abbreviated
        return f
    }()

    /// Long-form subtitle — unchanged shape from the prior
    /// implementation, just lifted into its own computed for clarity.
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

/// Solid capacity bar — proportional rectangle fill. When charging or
/// fully charged the bar tints accent green; otherwise the default
/// text color so it doesn't fight the charge-state pill for attention.
struct CapacityBar: View {
    let percent: Int
    let isAccentTinted: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: BatteryViewSectionsConstants.capacityBarCornerRadius)
                    .fill(Color.manifoldCard)
                RoundedRectangle(cornerRadius: BatteryViewSectionsConstants.capacityBarCornerRadius)
                    .fill(isAccentTinted ? Color.manifoldAccent : Color.manifoldText)
                    .frame(
                        width: max(
                            0,
                            geo.size.width
                                * CGFloat(min(percent, BatteryViewSectionsConstants.percentScale))
                                / CGFloat(BatteryViewSectionsConstants.percentScale)
                        )
                    )
            }
        }
        .frame(height: BatteryViewSectionsConstants.capacityBarHeight)
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
                statusIcon: healthIcon,
                statusTint: healthTint,
                infoTitleKey: "window.battery.info.health.title",
                infoBodyKey: "window.battery.info.health.body",
                isShown: $isInfoShown
            )
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(battery.healthPercent)%")
                    .font(.title.monospacedDigit().weight(.semibold))
                    .foregroundStyle(healthTint)
                ConditionBadge(condition: battery.healthCondition)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(battery.cycleCount)/\(BatteryViewSectionsConstants.ratedMaxCycles)")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.manifoldText)
                    Text("window.battery.field.cycleCount")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // Health bar — separate from the charge-capacity bar so
            // the user reads the two ratios independently.
            CapacityBar(percent: battery.healthPercent, isAccentTinted: true)
        }
    }

    /// Health icon matches the condition band — green check when the
    /// battery is in the safe zone, amber/red otherwise.
    private var healthIcon: String {
        switch battery.healthCondition {
        case .excellent, .good: return "checkmark.circle.fill"
        case .fair:             return "exclamationmark.triangle.fill"
        case .poor, .veryPoor:  return "wrench.and.screwdriver.fill"
        }
    }

    private var healthTint: Color {
        switch battery.healthCondition {
        case .excellent, .good: return Color.manifoldAccent
        case .fair:             return Color.manifoldWarning
        case .poor, .veryPoor:  return Color.manifoldCritical
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
                statusIcon: temperatureIcon,
                statusTint: temperatureColor,
                infoTitleKey: "window.battery.info.temperature.title",
                infoBodyKey: "window.battery.info.temperature.body",
                isShown: $isInfoShown
            )
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "thermometer.medium")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(temperatureColor)
                        Text(String(format: "%.1f°C", battery.temperatureCelsius))
                            .font(.title2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(temperatureColor)
                    }
                    Text(String(format: "%.1f°F", celsiusToFahrenheit(battery.temperatureCelsius)))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: temperatureIcon)
                            .font(.caption2.weight(.semibold))
                        Text(LocalizedStringKey(temperatureBandKey))
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(temperatureColor, in: Capsule())
                    Text(LocalizedStringKey(temperatureSubtitleKey))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Temperature band: <30 healthy, 30–40 ordinary, 40–45 warm,
    /// ≥45 hot. Matches macOS's own thermal signaling contour.
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

    private var temperatureIcon: String {
        let c = battery.temperatureCelsius
        switch c {
        case ..<BatteryViewSectionsConstants.temperatureWarningStart:
            return "checkmark.circle.fill"
        case BatteryViewSectionsConstants.temperatureWarningStart..<BatteryViewSectionsConstants.temperatureCriticalStart:
            return "exclamationmark.triangle.fill"
        default:
            return "flame.fill"
        }
    }

    private var temperatureBandKey: String {
        let c = battery.temperatureCelsius
        switch c {
        case ..<BatteryViewSectionsConstants.temperatureWarmStart:    return "window.battery.temperatureBand.normal"
        case BatteryViewSectionsConstants.temperatureWarmStart..<BatteryViewSectionsConstants.temperatureWarningStart:
            return "window.battery.temperatureBand.normal"
        case BatteryViewSectionsConstants.temperatureWarningStart..<BatteryViewSectionsConstants.temperatureCriticalStart:
            return "window.battery.temperatureBand.warm"
        default:
            return "window.battery.temperatureBand.hot"
        }
    }

    private var temperatureSubtitleKey: String {
        let c = battery.temperatureCelsius
        switch c {
        case ..<BatteryViewSectionsConstants.temperatureWarningStart:
            return "window.battery.temperatureSubtitle.normal"
        case BatteryViewSectionsConstants.temperatureWarningStart..<BatteryViewSectionsConstants.temperatureCriticalStart:
            return "window.battery.temperatureSubtitle.warm"
        default:
            return "window.battery.temperatureSubtitle.hot"
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
                statusIcon: "bolt.circle.fill",
                statusTint: Color.manifoldAccent,
                infoTitleKey: "window.battery.info.power.title",
                infoBodyKey: "window.battery.info.power.body",
                isShown: $isInfoShown
            )
            // Two-column grid: Power / Voltage on top row, Current /
            // mini-status on bottom row. Mirrors the Juicy layout for
            // at-a-glance pickup.
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("window.battery.field.power")
                        .font(.caption.smallCaps())
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.2f W", battery.powerWatts))
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.manifoldText)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("window.battery.field.voltage")
                        .font(.caption.smallCaps())
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.2f V", battery.voltageVolts))
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.manifoldText)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("window.battery.field.current")
                        .font(.caption.smallCaps())
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text(String(format: "%+d mA", battery.amperageMilliamps))
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Color.manifoldText)
                        currentArrow
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: powerStatusIcon)
                            .font(.caption2.weight(.semibold))
                        Text(LocalizedStringKey(powerStatusKey))
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(Color.manifoldAccent)
                    Text("window.battery.voltageSubtitle.normal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Direction arrow next to the signed mA value: up = charging,
    /// down = discharging, hidden when the current is zero (idle).
    @ViewBuilder
    private var currentArrow: some View {
        if battery.amperageMilliamps > 0 {
            Image(systemName: "arrow.up.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.manifoldAccent)
        } else if battery.amperageMilliamps < 0 {
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.manifoldWarning)
        }
    }

    private var powerStatusIcon: String {
        switch battery.chargeState {
        case .charging:      return "bolt.fill"
        case .fullyCharged:  return "checkmark.circle.fill"
        case .discharging:   return "battery.50"
        case .notCharging:   return "pause.fill"
        case .unknown:       return "questionmark"
        }
    }

    private var powerStatusKey: String {
        switch battery.chargeState {
        case .charging:      return "host.battery.chargeState.charging"
        case .fullyCharged:  return "host.battery.chargeState.fullyCharged"
        case .discharging:   return "host.battery.chargeState.discharging"
        case .notCharging:   return "host.battery.chargeState.notCharging"
        case .unknown:       return "host.battery.chargeState.unknown"
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
                statusIcon: "battery.100",
                statusTint: Color.manifoldAccent,
                infoTitleKey: "window.battery.info.capacity.title",
                infoBodyKey: "window.battery.info.capacity.body",
                isShown: $isInfoShown
            )
            BatteryCapacityRow(
                labelKey: "window.battery.field.remaining",
                valueMilliampHours: battery.currentCapacityMAh,
                tint: Color.manifoldAccent
            )
            BatteryCapacityRow(
                labelKey: "window.battery.field.fullCharge",
                valueMilliampHours: battery.nominalCapacityMAh,
                tint: Color.manifoldAccent.opacity(0.85),
                trailingCaption: String(format: "%d%%", battery.healthPercent)
            )
            BatteryCapacityRow(
                labelKey: "window.battery.field.design",
                valueMilliampHours: battery.designCapacityMAh,
                tint: .secondary
            )
            Text("window.battery.capacity.refresh.note")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Single "label → value mAh" row used by `CapacityDetailsSection`.
/// Formats the value with thousands separators (5,073 mAh) and tints
/// the value per `tint` so the three rows read as a small bar chart
/// of "remaining (live) / current full / design".
struct BatteryCapacityRow: View {
    let labelKey: LocalizedStringKey
    let valueMilliampHours: Int
    let tint: Color
    let trailingCaption: String?

    init(
        labelKey: LocalizedStringKey,
        valueMilliampHours: Int,
        tint: Color,
        trailingCaption: String? = nil
    ) {
        self.labelKey = labelKey
        self.valueMilliampHours = valueMilliampHours
        self.tint = tint
        self.trailingCaption = trailingCaption
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(labelKey)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 6) {
                Text(formattedValue)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
                Text("window.battery.unit.mAh")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                if let trailingCaption {
                    Text("(\(trailingCaption))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var formattedValue: String {
        Self.numberFormatter.string(from: NSNumber(value: valueMilliampHours))
            ?? String(valueMilliampHours)
    }

    /// Thousands-separator formatter shared across rows. `decimal`
    /// style with 0 fraction digits → "5,073". Cached as a static so
    /// each row update is allocation-free.
    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()
}

// MARK: - Shared section header

/// Section header with an optional leading colored status icon, a
/// title in caption smallcaps, and an `(i)` info button that opens a
/// SwiftUI popover (per Q15 — NOT NSPopover; the AppKit popover is
/// reserved for the menu-bar slot).
struct BatterySectionHeader: View {
    let titleKey: LocalizedStringKey
    let statusIcon: String?
    let statusTint: Color
    let infoTitleKey: LocalizedStringKey
    let infoBodyKey: LocalizedStringKey
    @Binding var isShown: Bool

    init(
        titleKey: LocalizedStringKey,
        statusIcon: String? = nil,
        statusTint: Color = Color.manifoldAccent,
        infoTitleKey: LocalizedStringKey,
        infoBodyKey: LocalizedStringKey,
        isShown: Binding<Bool>
    ) {
        self.titleKey = titleKey
        self.statusIcon = statusIcon
        self.statusTint = statusTint
        self.infoTitleKey = infoTitleKey
        self.infoBodyKey = infoBodyKey
        self._isShown = isShown
    }

    var body: some View {
        HStack(spacing: 8) {
            if let statusIcon {
                Image(systemName: statusIcon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(statusTint)
            }
            Text(titleKey)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.manifoldText)
            Spacer()
            Button {
                isShown.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.subheadline)
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
    /// Capacity bar height in points. Sized to read as a chunky
    /// "battery level" gauge at the tab's typical width.
    static let capacityBarHeight: CGFloat = 16

    /// Corner radius of the rounded rectangles used by the capacity
    /// bar (background track + foreground fill). Matches the rest of
    /// the Battery section card radii.
    static let capacityBarCornerRadius: CGFloat = 4

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

    /// Manufacturer-rated maximum charge cycles for modern Apple
    /// silicon Macs (and Intel Macs from 2016+). Used as the
    /// denominator in the `BatteryHealthSection` "X / Y" cycle-count
    /// readout. Older Intel Macs (≤2015) were rated lower (300 / 500),
    /// but they predate the `MACOSX_DEPLOYMENT_TARGET = 26.0` gate
    /// and aren't a concern.
    static let ratedMaxCycles: Int = 1000
}
