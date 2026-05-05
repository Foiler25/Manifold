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
            }

            Spacer(minLength: 0)
        }
        .frame(width: BatteryNotchContentConstants.contentWidth)
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

    /// SF Symbol name for each alert kind.
    static func icon(for kind: BatteryNotchContent.Kind) -> String {
        switch kind {
        case .lowBattery: return "battery.25.exclamationmark"
        case .charged:    return "battery.100.bolt"
        case .pluggedIn:  return "powerplug.portrait.fill"
        case .unplugged:  return "powerplug.portrait"
        }
    }

    /// Tint for each alert kind. Drawn from `Color.manifold*` tokens
    /// so the palette refresh hooks in if/when Phase 15-style theming
    /// changes the values.
    static func tint(for kind: BatteryNotchContent.Kind) -> Color {
        switch kind {
        case .lowBattery: return Color.manifoldCritical
        case .charged:    return Color.manifoldAccent
        case .pluggedIn:  return Color.manifoldAccent
        case .unplugged:  return Color.manifoldWarning
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
