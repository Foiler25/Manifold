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
// DiagnosticsBanner.swift
//
// **Diagnostics** tab content per SPEC §13.2 + §18 Phase 6 acceptance
// #3 ("placeholder for Phase 8"). Phase 8 introduces the diagnostics
// engine + 5 initial rules that populate `PortGraph.diagnostics`;
// this view will render the active warnings list there.
//
// Phase 6 ships an empty-state body that already reads from
// `graph.diagnostics` so a future user can SEE Phase 8's diagnostics
// land without a new tab being added — they just appear here. The
// "banner" naming inherited from SPEC §3 file tree; the Phase 6
// placement is the full tab body, the Phase 8 work may also extract
// a thin top-of-window banner for severe diagnostics.

import SwiftUI
import ManifoldKit

struct DiagnosticsBanner: View {

    @Bindable var graph: PortGraph

    var body: some View {
        Group {
            if graph.diagnostics.isEmpty {
                emptyState
            } else {
                populated
            }
        }
        .accessibilityIdentifier("window.tab.diagnostics.root")
    }

    /// Empty-state for Phase 6 (no diagnostics engine yet) AND for
    /// future "all clear" runtime states.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 48))
                .foregroundStyle(Color.manifoldAccent)
            Text("window.tab.diagnostics.empty.title")
                .font(.title2)
                .foregroundStyle(Color.manifoldText)
                .accessibilityIdentifier("window.tab.diagnostics.empty.title")
            Text("window.tab.diagnostics.empty.subtitle")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Populated list — used by Phase 8's diagnostics output. Each
    /// row colour-codes by severity via `Color.manifoldSeverity(_:)`.
    private var populated: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(graph.diagnostics) { diag in
                    DiagnosticListRow(diagnostic: diag)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }
            }
            .padding(.vertical, 12)
        }
    }
}

private struct DiagnosticListRow: View {

    let diagnostic: Diagnostic

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: severityIcon)
                .font(.body)
                .foregroundStyle(Color.manifoldSeverity(diagnostic.severity))
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(diagnostic.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.manifoldText)
                Text(diagnostic.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var severityIcon: String {
        switch diagnostic.severity {
        case .info:     return "info.circle"
        case .warning:  return "exclamationmark.triangle"
        case .critical: return "xmark.octagon"
        }
    }
}

#Preview("DiagnosticsBanner — empty (Phase 6 default)") {
    DiagnosticsBanner(graph: PortGraph())
        .frame(width: 480, height: 400)
        .background(Color.manifoldSurface)
}

#Preview("DiagnosticsBanner — populated (Phase 8 future state)") {
    let graph = PortGraph()
    graph.replace(
        hosts: [PreviewData.macBook],
        diagnostics: [PreviewData.runningAtUSB2Warning]
    )
    return DiagnosticsBanner(graph: graph)
        .frame(width: 480, height: 400)
        .background(Color.manifoldSurface)
}
