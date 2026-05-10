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
    /// Active wall-power adapter, when one is connected. Surfaced as
    /// a small caption underneath the right-side time-remaining /
    /// "Topped off" text — was previously its own section in the
    /// (now-removed) Power tab; folded in here so input + battery
    /// state read as one unit.
    var inputAdapter: AdapterInfo? = nil

    /// Toggled by the (i) info button in the top-right corner.
    /// Drives a SwiftUI popover that explains how the time-remaining
    /// estimate is computed — instant calculation while macOS is
    /// calibrating, IOPS-smoothed value once it stabilizes.
    @State private var infoShown: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top row: percent on the left, "Until full / Until empty"
            // estimate on the right (or "∞" when fully charged).
            HStack(alignment: .firstTextBaseline) {
                Text("\(battery.chargePercent)%")
                    .font(.system(size: 48, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(BatteryViewSectionsConstants.levelTint(percent: battery.chargePercent))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer()
                untilLabel
            }

            // Charge-state pill stacked below the percent. Pill tint
            // tracks state + level — green charging/full, yellow on
            // battery, red when very low. Carries the state copy on
            // its own; the longer time-remaining caption sits on the
            // top row's right side, so we don't repeat either signal
            // as a subtitle below the pill.
            ChargeStatePill(state: battery.chargeState, percent: battery.chargePercent)

            // Solid proportional capacity bar — tinted by charge level
            // so a healthy battery reads green whether plugged in or
            // on battery. Drops to amber under 20% and red under 10%.
            CapacityBar(
                percent: battery.chargePercent,
                tint: BatteryViewSectionsConstants.levelTint(percent: battery.chargePercent)
            )
            .padding(.top, 4)
        }
        // Info button overlays the top-right corner (above the time
        // estimate) so the percent + time read as a single unit
        // without an icon wedged between them. The button itself is
        // small and the popover anchors off it.
        .overlay(alignment: .topTrailing) { infoButton }
    }

    /// Right-aligned time-left readout. The time value is the hero —
    /// rendered at title size, monospaced — with the "Until full" /
    /// "Until empty" caption sitting underneath in caption-smallcaps
    /// secondary. When fully charged the value is "∞" and the caption
    /// is "Until full" by convention. When a charger is connected,
    /// the adapter wattage + source ("65 W (MagSafe)") sits in a
    /// final caption line — folded in from the removed Power tab so
    /// input and battery state are visible together.
    @ViewBuilder
    private var untilLabel: some View {
        VStack(alignment: .trailing, spacing: 0) {
            switch battery.chargeState {
            case .charging:
                timeOrCalculating(minutes: battery.timeUntilFullMinutes)
                Text("window.battery.untilFull.label")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
            case .discharging:
                timeOrCalculating(minutes: battery.timeUntilEmptyMinutes)
                Text("window.battery.untilEmpty.label")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
            case .fullyCharged:
                // "∞ UNTIL FULL" reads as a unit-conversion glitch
                // when the battery is already full. Show a single
                // friendly line instead — same vertical real estate,
                // none of the infinity-time confusion.
                Text("window.battery.toppedOff")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.manifoldAccent)
            case .notCharging:
                // Plugged in but not actively gaining charge — PD
                // negotiating, or Optimized Battery Charging holding
                // the cell at the current level. The kernel
                // eventually publishes a time-to-full (it knows when
                // OBC will release the hold); until then the
                // "Calculating…" placeholder tells the user we're
                // aware and waiting on macOS.
                timeOrCalculating(minutes: battery.timeUntilFullMinutes)
                Text("window.battery.untilFull.label")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
            case .unknown:
                EmptyView()
            }
            adapterCaption
        }
    }

    /// `(i)` button overlaid in the top-right corner of the banner.
    /// Opens a SwiftUI popover with `infoTitleKey` / `infoBodyKey`
    /// describing how the time-remaining estimate is computed
    /// (instant fallback while macOS is calibrating, IOPS-smoothed
    /// value once it stabilizes).
    private var infoButton: some View {
        Button {
            infoShown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $infoShown) {
            VStack(alignment: .leading, spacing: 8) {
                Text("window.battery.timeEstimate.info.title")
                    .font(.headline)
                Text("window.battery.timeEstimate.info.body")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(width: BatteryViewSectionsConstants.infoPopoverWidth)
            .padding()
        }
    }

    /// "1h 24m" when the parser produced a time estimate. The
    /// `BatterySnapshotReader` falls back to an instant computation
    /// (live `InstantAmperage` or the adapter's rated current) so
    /// `minutes` is essentially always non-nil while plugged in or
    /// discharging. The fallback path here renders nothing — keeping
    /// the slot empty in the (now-rare) edge cases is preferable to
    /// an explicit "Calculating…" label that the user shouldn't see
    /// in normal use.
    @ViewBuilder
    private func timeOrCalculating(minutes: Int?) -> some View {
        if let m = minutes,
           let s = Self.shortFormatter.string(from: TimeInterval(m * 60)) {
            Text(s)
                .font(.title.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.manifoldText)
        }
    }

    /// Compact `1h 24m` formatter for the right-aligned banner caption.
    private static let shortFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .abbreviated
        return f
    }()

    /// Optional caption rendered below the time-remaining /
    /// "Topped off" line. Shows the active wall-power adapter's
    /// wattage and source ("65 W · MagSafe"). Hidden when no charger
    /// is connected — the absence is itself the signal.
    @ViewBuilder
    private var adapterCaption: some View {
        if let adapter = inputAdapter {
            HStack(spacing: 4) {
                Image(systemName: adapterIconName(for: adapter.source))
                    .font(.caption2)
                    .foregroundStyle(Color.manifoldAccent)
                Text(adapterCaptionString(for: adapter))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }

    /// "65 W · MagSafe". Source label drops away when the adapter's
    /// source is `.unknown` — printing "65 W · " with a trailing
    /// dangling separator would look broken.
    private func adapterCaptionString(for adapter: AdapterInfo) -> String {
        let watts = adapter.watts.formatted
        let source: String
        switch adapter.source {
        case .magsafe:  source = NSLocalizedString("host.adapter.source.magsafe",  comment: "")
        case .usbC:     source = NSLocalizedString("host.adapter.source.usbC",     comment: "")
        case .wireless: source = NSLocalizedString("host.adapter.source.wireless", comment: "")
        case .unknown:  source = ""
        }
        return source.isEmpty ? watts : "\(watts) · \(source)"
    }

    private func adapterIconName(for source: AdapterInfo.Source) -> String {
        switch source {
        case .magsafe:  return "bolt.batteryblock.fill"
        case .usbC:     return "bolt.fill"
        case .wireless: return "bolt.badge.checkmark.fill"
        case .unknown:  return "bolt.fill"
        }
    }
}

/// Charge-state pill — colored capsule matching the
/// `DiagnosticBadge` shape (per the SPEC §20 plan). Pill tint is
/// driven by the combined charge-state + level helper:
///   - charging / fullyCharged → green (manifoldAccent)
///   - discharging / notCharging → yellow (manifoldWarning) above
///     the critical-low threshold, red (manifoldCritical) at or
///     below it
///   - unknown → secondary gray
struct ChargeStatePill: View {
    let state: BatteryInfo.ChargeState
    let percent: Int

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
        BatteryViewSectionsConstants.chargeStateTint(state: state, percent: percent)
    }
}

/// Solid capacity bar — proportional rectangle fill. The fill color
/// is supplied by the caller (level-based green / amber / red) so the
/// gauge tracks the level rather than the charge state — a healthy
/// 95% on battery still reads green.
struct CapacityBar: View {
    let percent: Int
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Unfilled track. Uses a subtle white-on-dark tone
                // so the full-bar extent is visible against the
                // card background — `manifoldCard` (0x161616) sat
                // too close to `manifoldSurface` (0x0A0A0A) and
                // disappeared. The tone matches the `.secondary`
                // text colour weight, so the bar reads as a quiet
                // capacity scale rather than competing with the
                // tinted fill.
                RoundedRectangle(cornerRadius: BatteryViewSectionsConstants.capacityBarCornerRadius)
                    .fill(Color.manifoldText.opacity(BatteryViewSectionsConstants.capacityBarTrackOpacity))
                RoundedRectangle(cornerRadius: BatteryViewSectionsConstants.capacityBarCornerRadius)
                    .fill(tint)
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
            // the user reads the two ratios independently. Tinted by
            // the section's health-condition color (green / amber /
            // red) so the bar fill agrees with the condition pill.
            CapacityBar(percent: battery.healthPercent, tint: healthTint)
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

    /// Temperature band: <40 normal (green), 40–45 warm (amber),
    /// ≥45 hot (red). The previous middle "ordinary white" band
    /// mapped to `Color.manifoldText` which collided with the pill's
    /// white text and rendered the badge unreadable around 30–40°C
    /// (which is the steady-state operating temperature for most
    /// laptops). Collapsing the bottom two bands into one fixes that.
    private var temperatureColor: Color {
        let c = battery.temperatureCelsius
        switch c {
        case ..<BatteryViewSectionsConstants.temperatureWarningStart:
            return Color.manifoldAccent
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
        case ..<BatteryViewSectionsConstants.temperatureWarningStart:
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
                statusIcon: powerHeaderIcon,
                statusTint: BatteryViewSectionsConstants.chargeStateTint(
                    state: battery.chargeState,
                    percent: battery.chargePercent
                ),
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
                    .foregroundStyle(
                        BatteryViewSectionsConstants.chargeStateTint(
                            state: battery.chargeState,
                            percent: battery.chargePercent
                        )
                    )
                    Text("window.battery.voltageSubtitle.normal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Section-header glyph mirrors the inline status pill icon — bolt
    /// when charging, check when full, battery-icon when discharging,
    /// pause when stuck on AC, "?" when unknown.
    private var powerHeaderIcon: String {
        switch battery.chargeState {
        case .charging:      return "bolt.circle.fill"
        case .fullyCharged:  return "checkmark.circle.fill"
        case .discharging:   return "minus.circle.fill"
        case .notCharging:   return "pause.circle.fill"
        case .unknown:       return "questionmark.circle.fill"
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
    /// Capacity bar height in points. A thinner bar reads as a
    /// supporting gauge rather than a competing UI element — keeps
    /// the percent number and the section copy as the primary
    /// signal. Matches Juicy's lean health/charge bars.
    static let capacityBarHeight: CGFloat = 6

    /// Corner radius of the rounded rectangles used by the capacity
    /// bar (background track + foreground fill). Tracks
    /// `capacityBarHeight / 2` so the bar reads as a clean pill.
    static let capacityBarCornerRadius: CGFloat = 3

    /// Alpha applied to `manifoldText` (white) for the unfilled
    /// portion of `CapacityBar`. 0.18 = ~`#2E2E2E`-equivalent —
    /// distinguishable from the card background without competing
    /// with the tinted fill.
    static let capacityBarTrackOpacity: Double = 0.18

    /// 0...100 percent scale (Int) — used so the per-segment threshold
    /// math stays in integer arithmetic.
    static let percentScale: Int = 100

    /// `1 minute → 60 seconds` for `DateComponentsFormatter` round-trips.
    static let secondsPerMinute: Int = 60

    /// Color-grading thresholds for `TemperatureSection`. Below 40°C
    /// reads as healthy (typical operating range); 40–45°C warning;
    /// ≥45°C critical. Numbers reflect the rough contour of macOS's
    /// own battery temperature alerts (no public API; observed
    /// empirically).
    static let temperatureWarningStart: Double = 40
    static let temperatureCriticalStart: Double = 45

    /// Level-based percent / bar color. ≥21% healthy (green), 11–20%
    /// low (amber), ≤10% critical (red). Tracks the *level* of the
    /// battery, not the charge state — a healthy 95% on battery
    /// still reads green even though it's discharging.
    /// `levelLowThreshold` is the highest percent that still reads
    /// as low (inclusive); the warning range covers
    /// `(levelCriticalThreshold + 1) ... levelLowThreshold`.
    static let levelLowThreshold: Int = 20
    static let levelCriticalThreshold: Int = 10

    static func levelTint(percent: Int) -> Color {
        switch percent {
        case ...levelCriticalThreshold:                  return Color.manifoldCritical
        case (levelCriticalThreshold + 1)...levelLowThreshold: return Color.manifoldWarning
        default:                                          return Color.manifoldAccent
        }
    }

    /// Tint for charge-state-bearing UI (the top ChargeStatePill, the
    /// Power & Electrical section icon, the Power section's right-hand
    /// status badge). Combines charge state + battery level so the
    /// surface reads green when charging or full, yellow on battery,
    /// red when very low.
    static func chargeStateTint(state: BatteryInfo.ChargeState, percent: Int) -> Color {
        switch state {
        case .charging, .fullyCharged:
            return Color.manifoldAccent
        case .discharging, .notCharging:
            return percent <= levelCriticalThreshold
                ? Color.manifoldCritical
                : Color.manifoldWarning
        case .unknown:
            return .secondary
        }
    }

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
