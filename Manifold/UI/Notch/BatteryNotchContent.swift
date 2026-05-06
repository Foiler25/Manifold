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
// BatteryNotchContent.swift
//
// Phase 19 — the SwiftUI content view rendered inside the notch
// dropdown for each battery-alert kind. Layout: a leading SF Symbol
// glyph (color-tinted by alert kind) + title + subtitle, all in a
// 340-point-wide box.
//
// Per SPEC §21 the view is purely presentational — the
// `BatteryAlertEngine` constructs a `BatteryNotchContent` value with
// the right kind + title + subtitle for each fire path, hands it to
// `NotchPanelController.show(content:for:)`, and that's the whole
// pipeline. There is no IOKit here.

import SwiftUI

/// One alert's worth of notch content. Initialized by the engine; the
/// engine selects the icon + title + subtitle copy keys based on the
/// fire path (SPEC §21.5 — low / charged / plug / unplug).
struct BatteryNotchContent: View {

    /// Discriminator for the SF Symbol glyph + tint. Each fire path
    /// in `BatteryAlertEngine` selects one of these.
    enum Kind {
        case lowBattery
        case charged
        case pluggedIn
        case unplugged
    }

    /// Which battery event triggered this alert. Drives the leading
    /// glyph + tint via `BatteryNotchContentConstants.icon(for:)` /
    /// `tint(for:)`.
    let kind: Kind

    /// Localized title — e.g., "Battery low" / "Charged to 80%" /
    /// "Plugged in" / "Unplugged".
    let title: LocalizedStringKey

    /// Localized subtitle — e.g., "5% remaining" / "Now at 80%" /
    /// "Manifold 65W USB-C" / "Running on battery".
    let subtitle: LocalizedStringKey

    /// Optional time-remaining caption — e.g., "1h 23m until full" /
    /// "4h 5m until empty". Rendered below the subtitle in caption-
    /// secondary so it reads as supplementary metadata. Nil for
    /// alerts where no useful estimate exists (charged-threshold
    /// alerts, fully-charged plug events, fresh-unplug before the
    /// firmware has a discharge estimate).
    let timeRemaining: String?

    /// Optional charge percentage rendered large on the right of
    /// the row. Tinted by `BatteryNotchContentConstants.tint(for:)`
    /// — green for charging / charged, amber for discharging
    /// (unplug), red for critical-low — so a glance at the right
    /// side conveys both the level and the state at once. Nil
    /// hides the column cleanly.
    let percent: Int?

    init(
        kind: Kind,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        timeRemaining: String? = nil,
        percent: Int? = nil
    ) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.timeRemaining = timeRemaining
        self.percent = percent
    }

    var body: some View {
        HStack(alignment: .center, spacing: BatteryNotchContentConstants.iconTitleSpacing) {
            Image(systemName: BatteryNotchContentConstants.icon(for: kind))
                .font(.system(size: BatteryNotchContentConstants.iconSize, weight: .semibold))
                .foregroundStyle(BatteryNotchContentConstants.tint(for: kind))
                .frame(width: BatteryNotchContentConstants.iconColumnWidth, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: BatteryNotchContentConstants.titleSubtitleSpacing) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.manifoldText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let timeRemaining {
                    Text(timeRemaining)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .monospacedDigit()
                }
            }

            Spacer(minLength: BatteryNotchContentConstants.minPercentSpacing)

            if let percent {
                Text("\(percent)%")
                    .font(
                        .system(
                            size: BatteryNotchContentConstants.percentFontSize,
                            weight: .semibold,
                            design: .rounded
                        )
                        .monospacedDigit()
                    )
                    .foregroundStyle(
                        BatteryNotchContentConstants.percentTint(
                            for: kind,
                            percent: percent
                        )
                    )
                    .lineLimit(1)
                    .padding(.trailing, BatteryNotchContentConstants.percentTrailingInset)
                    .accessibilityLabel(Text("\(percent) percent"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Constants

enum BatteryNotchContentConstants {
    /// Total content width in points. 340 matches Juicy's reference
    /// width — wide enough to fit "Manifold 65W USB-C" subtitle on
    /// one line without wrap, narrow enough to read as a notification
    /// rather than a window.
    static let contentWidth: CGFloat = 340

    /// SF Symbol point size for the leading glyph.
    static let iconSize: CGFloat = 24

    /// Width allocated for the glyph column. Wider than the symbol
    /// itself so the text starts at a fixed x regardless of the
    /// glyph's natural width.
    static let iconColumnWidth: CGFloat = 36

    /// Gap between the icon column and the text stack.
    static let iconTitleSpacing: CGFloat = 12

    /// Gap between title and subtitle.
    static let titleSubtitleSpacing: CGFloat = 2

    /// Minimum gap between the text stack and the trailing percent
    /// label. Used as the `Spacer(minLength:)` so the spacer
    /// guarantees breathing room even on tight canvases.
    static let minPercentSpacing: CGFloat = 12

    /// Font size for the trailing percent label. Sized so a 3-digit
    /// "100%" reads clearly without crowding the title stack — at
    /// 24pt rounded-semibold "100%" is ~62pt wide, leaving comfortable
    /// room in the canvas for the title / subtitle / time captions
    /// to sit on a single line each.
    static let percentFontSize: CGFloat = 24

    /// Extra trailing inset on the percent label so its visual
    /// right edge mirrors the icon's visual left edge — the icon
    /// glyph (24pt) is centered in a 36pt column, yielding ~6pt of
    /// air between the body's left padding and the visible glyph;
    /// this inset adds the same air on the right.
    static let percentTrailingInset: CGFloat = 6

    /// SF Symbol name for each alert kind.
    static func icon(for kind: BatteryNotchContent.Kind) -> String {
        switch kind {
        case .lowBattery: return "battery.25.exclamationmark"
        case .charged:    return "battery.100.bolt"
        case .pluggedIn:  return "powerplug.portrait.fill"
        case .unplugged:  return "powerplug.portrait"
        }
    }

    /// Tint for each alert kind's *icon glyph*. Distinct from the
    /// percent-badge tint (`percentTint(for:percent:)`) — the icon
    /// signals the alert category (low / charged / plug / unplug),
    /// while the percent badge signals the actual battery level.
    /// Drawn from `Color.manifold*` tokens so a palette refresh
    /// hooks in if/when Phase 15-style theming changes the values.
    static func tint(for kind: BatteryNotchContent.Kind) -> Color {
        switch kind {
        case .lowBattery: return Color.manifoldCritical
        case .charged:    return Color.manifoldAccent
        case .pluggedIn:  return Color.manifoldAccent
        case .unplugged:  return Color.manifoldWarning
        }
    }

    /// Tint for the trailing percent badge. The badge reflects the
    /// **current battery level**, not the alert category, so a
    /// low-battery alert at 18% reads yellow but at 5% reads red —
    /// matching the popover's level-based palette. Reuses
    /// `BatteryViewSectionsConstants.levelTint(percent:)` so the
    /// thresholds stay coherent across surfaces. For non-level
    /// alerts (charged / plug / unplug) the badge falls back to
    /// the alert's icon tint so the row reads as a single color
    /// signal.
    static func percentTint(for kind: BatteryNotchContent.Kind, percent: Int) -> Color {
        switch kind {
        case .lowBattery, .unplugged:
            return BatteryViewSectionsConstants.levelTint(percent: percent)
        case .charged, .pluggedIn:
            return tint(for: kind)
        }
    }
}

// MARK: - Preview

#Preview("BatteryNotchContent — variants") {
    VStack(spacing: 12) {
        BatteryNotchContent(
            kind: .lowBattery,
            title: "notch.battery.alert.low.title",
            subtitle: "notch.battery.alert.low.subtitle"
        )
        BatteryNotchContent(
            kind: .charged,
            title: "notch.battery.alert.charged.title",
            subtitle: "notch.battery.alert.charged.subtitle"
        )
        BatteryNotchContent(
            kind: .pluggedIn,
            title: "notch.battery.alert.pluggedIn.title",
            subtitle: "notch.battery.alert.pluggedIn.subtitle"
        )
        BatteryNotchContent(
            kind: .unplugged,
            title: "notch.battery.alert.unplugged.title",
            subtitle: "notch.battery.alert.unplugged.subtitle"
        )
    }
    .padding()
    .background(Color.manifoldSurface)
}
