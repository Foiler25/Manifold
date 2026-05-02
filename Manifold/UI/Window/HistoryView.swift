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
// HistoryView.swift
//
// **History** tab content per SPEC §13.2 + §18 Phase 6 acceptance #3.
// Phase 6 ships only the placeholder per the SPEC bullet "(placeholder
// for Phase 10)". Phase 10 introduces GRDB persistence + the event /
// sample chart that lives here.

import SwiftUI

struct HistoryView: View {

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("window.tab.history.placeholder.title")
                .font(.title2)
                .foregroundStyle(Color.manifoldText)
                .accessibilityIdentifier("window.tab.history.placeholder.title")
            Text("window.tab.history.placeholder.subtitle")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("window.tab.history.placeholder.accessibility")
    }
}

#Preview("HistoryView placeholder") {
    HistoryView()
        .frame(width: 480, height: 400)
        .background(Color.manifoldSurface)
}
