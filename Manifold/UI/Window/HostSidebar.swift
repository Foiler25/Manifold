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
// HostSidebar.swift
//
// Sidebar column of the main window's `NavigationSplitView` per
// SPEC §13.2. Lists every host the discovery layer has produced
// (Phase 6: always exactly one — the local Mac); the user picks one
// and the content column re-renders against `selectedHost`.
//
// Design note: the selection binding is `HostID?` so deselection
// renders cleanly. `nil` is also the cold-launch state before the
// first walk completes; in that case the content column shows its
// own empty state rather than us auto-selecting.

import SwiftUI
import ManifoldKit

struct HostSidebar: View {

    @Bindable var graph: PortGraph

    /// Two-way binding to the parent's `@SceneStorage` selection.
    /// Persists across launches so the user returns to the host they
    /// were last looking at.
    @Binding var selectedHostID: HostID?

    var body: some View {
        // No Section wrapper — the macOS sidebar style applies a leading
        // inset to section headers that, at the smallest sidebar widths,
        // pushed the "HOSTS" caption off the leading edge so it rendered
        // as "STS". A single-host (always the local Mac per SPEC §4) app
        // doesn't need a visible section header to disambiguate anyway.
        List(graph.hosts, selection: $selectedHostID) { host in
            HostSidebarRow(host: host)
                .tag(Optional(host.id))
        }
        .listStyle(.sidebar)
        .navigationTitle("window.sidebar.title")
    }
}

/// One row inside the sidebar list. Pulled out so we can preview it
/// in isolation and so VoiceOver labelling sits in one place.
private struct HostSidebarRow: View {

    let host: ManifoldKit.Host

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "laptopcomputer")
                .foregroundStyle(Color.manifoldAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayName)
                    .font(.body)
                    .foregroundStyle(Color.manifoldText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Show bonjour hostname under the friendly name; if no
                // friendly name is set, fall back to the model identifier.
                Text(host.friendlyName != nil ? host.name : host.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Without explicit minLength, Spacer is willing to collapse
            // to 0 pt when the host name claims the row's natural
            // width — the host name then truncates inside the VStack
            // instead of pushing the power figure past the trailing
            // edge of the sidebar.
            Spacer(minLength: 4)
            Text(host.totalPowerDraw.formatted)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// VoiceOver: "MacBook Pro, Mac15,9, 7.5 W total".
    private var accessibilityLabel: String {
        String(
            format: NSLocalizedString(
                "window.sidebar.host.accessibility",
                comment: "VoiceOver label for one host row in the sidebar."
            ),
            host.displayName,
            host.model,
            host.totalPowerDraw.formatted
        )
    }
}

#Preview("HostSidebar — populated") {
    let graph = PortGraph()
    graph.replace(hosts: [PreviewData.macBook])
    return HostSidebar(graph: graph, selectedHostID: .constant(PreviewData.macBook.id))
        .frame(width: 220, height: 300)
}

#Preview("HostSidebar — empty") {
    HostSidebar(graph: PortGraph(), selectedHostID: .constant(nil))
        .frame(width: 220, height: 300)
}
