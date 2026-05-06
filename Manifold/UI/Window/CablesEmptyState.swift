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
// CablesEmptyState.swift
//
// Phase 21 — three flavours of empty state for the Cables tab:
//
//   .loading           — snapshot is nil (cold-launch race window).
//   .unsupportedHost   — snapshot delivered but ports[] is empty,
//                        which on Apple Silicon means the host has no
//                        AppleHPMInterfaceType registry entries (Intel
//                        TB3 hardware, or running under Rosetta).
//   .noCablesPluggedIn — ports present but none are `connectionActive`.
//                        Sits beneath the per-port card list as a small
//                        hint, mirroring `BatteryView.desktopBatteryHint`.

import SwiftUI

struct CablesEmptyState: View {

    enum Kind {
        case loading
        case unsupportedHost
        case noCablesPluggedIn
    }

    let kind: Kind

    var body: some View {
        switch kind {
        case .loading:
            inlineLayout(
                icon: "cable.connector.horizontal",
                title: "cables.loading.title",
                detail: "cables.loading.detail"
            )
        case .unsupportedHost:
            heroLayout(
                icon: "cable.connector.slash",
                title: "cables.intel.title",
                detail: "cables.intel.detail"
            )
        case .noCablesPluggedIn:
            inlineLayout(
                icon: "cable.connector",
                title: "cables.empty.title",
                detail: "cables.empty.detail"
            )
        }
    }

    /// Hero layout: large glyph + headline, intended to fill the
    /// entire tab body. Used for `.unsupportedHost` and similar
    /// terminal states.
    private func heroLayout(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.manifoldText)
                .accessibilityIdentifier("cables.emptyState.title")
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    /// Inline layout: smaller glyph next to body copy. Used as a
    /// hint beneath existing content, never as the only thing on
    /// screen.
    private func inlineLayout(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.manifoldText)
                    .accessibilityIdentifier("cables.emptyState.title")
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(CablesViewConstants.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: CablesViewConstants.cardCornerRadius)
                .fill(Color.manifoldCard.opacity(0.5))
        )
    }
}

#Preview("CablesEmptyState — unsupported host") {
    CablesEmptyState(kind: .unsupportedHost)
        .frame(width: 520, height: 300)
        .background(Color.manifoldSurface)
}

#Preview("CablesEmptyState — no cables plugged in") {
    CablesEmptyState(kind: .noCablesPluggedIn)
        .padding()
        .frame(width: 520)
        .background(Color.manifoldSurface)
}
