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

    /// macOS 14+ SwiftUI action for showing the app's `Settings` scene.
    /// The legacy `NSApp.sendAction(Selector(("showSettingsWindow:")), …)`
    /// path returns `dispatched=true` but is silently swallowed when
    /// the click originates inside an `NSHostingController`-hosted
    /// `NSPopover` — its `_NSPopoverWindow` isn't key, so the
    /// responder-chain target the legacy selector relies on is the
    /// popover, not the app. `OpenSettingsAction` doesn't go through
    /// the responder chain; it asks SwiftUI to present the Settings
    /// scene directly.
    @Environment(\.openSettings) private var openSettingsAction

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header section
            if let host = graph.hosts.first {
                HostHeader(host: host, diagnosticCount: graph.diagnostics.count)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                if !host.physicalPorts.isEmpty {
                    PortOccupancyView(ports: host.physicalPorts)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            } else {
                emptyState
            }

            Divider()

            // Port tree section. Scrollable so a long device list
            // stays navigable inside the fixed-size popover. The
            // ScrollView is sized to fit the visible rows so the
            // popover hugs its content; once the visible-row cap kicks
            // in (>3 rows) the height holds and the rest scroll.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(graph.hosts.first?.ports ?? [], id: \.id) { port in
                        OutlineGroup(port, children: \.childrenForOutline) { node in
                            PortRow(
                                port: node,
                                history: graph.history(forPortID: node.id),
                                diagnostics: graph.diagnostics(forPortID: node.id)
                            )
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(height: scrollSectionHeight)

            Divider()

            // Bottom toolbar. `.buttonStyle(.plain)` plus a `Label`
            // only hit-tests where glyphs are drawn — clicks on the
            // surrounding padding silently no-op'd inside the
            // NSHostingController-hosted popover. `.borderless` gives
            // a proper text-button hit target without the tinted
            // chrome of `.bordered`, and `.contentShape(.rect)`
            // extends the icon-only gear button's hit area to the
            // full frame so a near-miss still registers.
            HStack(spacing: 12) {
                Button(action: onOpenWindow) {
                    Label("popover.toolbar.openWindow", systemImage: "macwindow")
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("popover.toolbar.openWindow.accessibility")

                Spacer()

                Button {
                    // Ask AppDelegate to activate the app first so the
                    // Settings window comes forward (the popover's
                    // _NSPopoverWindow loses key status as it dismisses).
                    onOpenSettings()
                    openSettingsAction()
                } label: {
                    Image(systemName: "gear")
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("popover.toolbar.openSettings.accessibility")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(
            width: AppConstants.popoverContentSize.width,
            alignment: .topLeading
        )
        .background(Color.manifoldSurface)
    }

    /// Visible row count, capped at the threshold above which the
    /// scroll view starts scrolling. Counts only top-level ports —
    /// nested children inside an `OutlineGroup` are reachable via
    /// the disclosure triangle and don't contribute to the cap.
    private var visibleRowCount: Int {
        let total = graph.hosts.first?.ports.count ?? 0
        return min(total, AppConstants.popoverScrollThreshold)
    }

    /// Height of the scrolling port-tree section. Matches the visible
    /// rows exactly when the count is at or below the cap; pins to
    /// the cap × per-row when there are more, so additional ports
    /// scroll inside that fixed window.
    private var scrollSectionHeight: CGFloat {
        // 8 pt padding above the LazyVStack + 8 pt below.
        let listPadding: CGFloat = 16
        let rowSpacing: CGFloat = 4
        let perRow = AppConstants.popoverPortRowHeight
        let count = max(visibleRowCount, 1)
        let rowsHeight = CGFloat(count) * perRow
        let spacingHeight = CGFloat(max(count - 1, 0)) * rowSpacing
        return listPadding + rowsHeight + spacingHeight
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
