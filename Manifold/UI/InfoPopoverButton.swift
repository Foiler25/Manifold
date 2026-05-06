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
// ─────────────────────────────────────────────────────────────────────
// InfoPopoverButton.swift
//
// Shared "(i) info" affordance — a clickable circle that opens a
// SwiftUI popover with title + body. Matches the pattern
// `BatterySectionHeader` already uses on the Battery surfaces, so a
// user who learns the affordance on one tab finds it works the same
// way on the topology / popover device rows. The previous
// implementations on those device rows used `.help()` (hover-only
// tooltips) which were invisible to anyone navigating with keyboard
// or trackpad-tap and required a long enough hover for the system
// tooltip to fade in — clicking gives an immediate readable popover.
//
// Use:
//
//     InfoPopoverButton(
//         titleKey: "popover.device.power.unavailable.title",
//         bodyKey:  "popover.device.power.unavailable.tooltip",
//         accessibilityKey: "popover.device.power.unavailable.accessibility"
//     )
//
// `iconFont` defaults to `.caption` (matches the device-row context);
// pass `.subheadline` for the inspector pane where the surrounding
// text is larger.

import SwiftUI

struct InfoPopoverButton: View {

    /// Headline text inside the popover. Optional — when nil, the
    /// popover renders only the body, which keeps single-fact
    /// affordances visually light.
    let titleKey: LocalizedStringKey?

    /// Body text inside the popover. The full explanation lives here.
    let bodyKey: LocalizedStringKey

    /// VoiceOver label for the icon button. Required so the
    /// affordance is discoverable to screen-reader users — the
    /// SF-Symbol icon alone reads as "info" without context.
    let accessibilityKey: LocalizedStringKey

    /// Icon font. Defaults to `.caption` for device-row contexts;
    /// pass `.subheadline` for larger surfaces like the inspector
    /// pane so the icon doesn't read as undersized next to the
    /// surrounding subhead-weight text.
    var iconFont: Font = .caption

    @State private var isShown: Bool = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(iconFont)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityKey))
        .popover(isPresented: $isShown) {
            VStack(alignment: .leading, spacing: 8) {
                if let titleKey {
                    Text(titleKey)
                        .font(.headline)
                        .foregroundStyle(Color.manifoldText)
                }
                Text(bodyKey)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: InfoPopoverButtonConstants.popoverWidth, alignment: .leading)
            .padding()
        }
    }
}

// MARK: - Constants

enum InfoPopoverButtonConstants {
    /// Popover width. Wide enough that a 2–3 sentence explanation
    /// reads on 3–4 lines without wrapping mid-clause; narrow
    /// enough that the popover doesn't dominate small surfaces
    /// like the menu-bar popover.
    static let popoverWidth: CGFloat = 280
}
