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
// PopoverRoot.swift
//
// SwiftUI root for the popover. Per SPEC.md §13.1:
//   - Fixed width 360pt.
//   - Top: host header (model name, total draw, diagnostic count).
//   - Middle: OutlineGroup over Host.ports rendering PortRow and
//     recursive DeviceRow.
//   - Bottom toolbar: open main window button, settings button.
//
// Phase 4 ships the layout; Phase 5 adds sparklines inside DeviceRow,
// Phase 7 fills out hub trees (OutlineGroup recurses into them
// automatically via `Port.children`).
//
// `OutlineGroup` keys on each port's `Identifiable.id` (which is
// `PortID`, derived from registry path per DECISIONS.md D9). That's
// what gives us the SPEC §18 Phase 4 stable-ID acceptance: replug
// produces an event with the same PortID, the existing row updates
// in place rather than animating remove + add.

import SwiftUI
import ManifoldKit

struct PopoverRoot: View {

    /// Single source of truth, per SPEC §4.6. `@Bindable` exposes the
    /// `@Observable` PortGraph so reads of `graph.hosts` etc. inside
    /// `body` are tracked by SwiftUI.
    @Bindable var graph: PortGraph

    /// Closure dispatched when the user clicks "Open Manifold". Owned
    /// by the caller (AppDelegate / StatusItemController) so the
    /// popover doesn't depend on AppKit globals directly.
    let onOpenWindow: () -> Void

    /// Closure for the settings button.
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header section
            if let host = graph.hosts.first {
                HostHeader(host: host, diagnosticCount: graph.diagnostics.count)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
            } else {
                emptyState
            }

            Divider()

            // Port tree section. Scrollable so a long device list
            // stays navigable inside the fixed-size popover.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(graph.hosts.first?.ports ?? [], id: \.id) { port in
                        OutlineGroup(port, children: \.childrenForOutline) { node in
                            PortRow(port: node, history: graph.history(forPortID: node.id))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxHeight: .infinity)

            Divider()

            // Bottom toolbar.
            HStack(spacing: 12) {
                Button(action: onOpenWindow) {
                    Label("popover.toolbar.openWindow", systemImage: "macwindow")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("popover.toolbar.openWindow.accessibility")

                Spacer()

                Button(action: onOpenSettings) {
                    Image(systemName: "gear")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("popover.toolbar.openSettings.accessibility")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(
            width: AppConstants.popoverContentSize.width,
            height: AppConstants.popoverContentSize.height,
            alignment: .topLeading
        )
        .background(Color.manifoldSurface)
    }

    /// "No hosts discovered" state. Phase 2's `DiscoveryService.walk()`
    /// always returns at least one host on a real Mac; this state is
    /// reachable only momentarily on cold launch before the first walk
    /// completes, or if the IOKit registry walk fails completely.
    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "rays")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("popover.empty.title")
                .font(.headline)
                .foregroundStyle(Color.manifoldText)
            Text("popover.empty.subtitle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
    }
}

// MARK: - OutlineGroup children helper

private extension ManifoldKit.Port {
    /// `OutlineGroup` requires `children: KeyPath<Port, [Port]?>` (the
    /// optional signals "leaf" — nil means no disclosure triangle).
    /// `Port.children` is non-optional `[Port]`, so this computed
    /// property maps empty arrays to nil so leaf rows don't render
    /// the disclosure indicator.
    var childrenForOutline: [ManifoldKit.Port]? {
        children.isEmpty ? nil : children
    }
}

#Preview("PopoverRoot — populated") {
    let graph = PortGraph()
    graph.replace(hosts: [PreviewData.macBook], diagnostics: [PreviewData.runningAtUSB2Warning])
    return PopoverRoot(
        graph: graph,
        onOpenWindow: { },
        onOpenSettings: { }
    )
}

#Preview("PopoverRoot — empty graph") {
    let graph = PortGraph()
    return PopoverRoot(
        graph: graph,
        onOpenWindow: { },
        onOpenSettings: { }
    )
}
