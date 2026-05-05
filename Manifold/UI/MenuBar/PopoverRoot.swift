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
                let rootPorts = graph.hosts.first.map(PortGraph.displayableRootPorts(for:)) ?? []
                let anyExpandable = PortOutline.anyExpandable(in: rootPorts)
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(rootPorts, id: \.id) { port in
                        PortOutline(
                            port: port,
                            depth: 0,
                            anyExpandable: anyExpandable,
                            graph: graph
                        )
                    }
                }
                // Leading inset so the disclosure chevron doesn't
                // read as crowded against the popover's left edge.
                // Skipped when no hubs exist anywhere — the rows
                // flush left without the chevron gutter.
                .padding(
                    .leading,
                    anyExpandable ? PopoverRootConstants.outlineLeadingInset : 0
                )
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
    /// Includes the synthetic empty chassis rows so the popover
    /// height stays right when nothing is plugged in.
    private var visibleRowCount: Int {
        let total = graph.hosts.first.map(PortGraph.displayableRootPorts(for:))?.count ?? 0
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

// MARK: - Constants

enum PopoverRootConstants {
    /// Width of the dedicated chevron column. Always reserved on
    /// every row — `chevron.right` for expandable rows, empty for
    /// leaves — so the plug icon and the trailing power/info icon
    /// both land at consistent x's regardless of depth or
    /// expandability. Tuned by inspection.
    static let chevronColumnWidth: CGFloat = 18.0

    /// Per-depth indent for nested children. Each level shifts the
    /// row's content this many points to the right.
    static let outlineIndentPerLevel: CGFloat = 16.0

    /// Leading inset on the entire outline container so the
    /// disclosure chevron has breathing room from the popover's
    /// left edge instead of being jammed against it.
    static let outlineLeadingInset: CGFloat = 10.0
}

// MARK: - PortOutline

/// Custom recursive replacement for `OutlineGroup`. SwiftUI's
/// `OutlineGroup` was producing rows whose intrinsic width fought
/// every `.frame(maxWidth: .infinity)` we added — leaf rows ended
/// up narrower than expandable rows because the auto-rendered
/// chevron took variable width, and the trailing power / info
/// icons sat at different x's across the list.
///
/// `PortOutline` controls every column directly: a fixed-width
/// chevron gutter (filled with `chevron.down/right` for hubs,
/// `Color.clear` for leaves) plus a `PortRow` that fills the
/// remaining width with `.frame(maxWidth: .infinity, alignment:
/// .leading)`. Nested children are rendered recursively at
/// `depth + 1` with a left indent.
///
/// Disclosure state is `@State` (per-instance, in-memory) — opens
/// and closes survive scrolling but reset when the popover is
/// dismissed. That matches the popover's transient role; the
/// stand-alone window can graduate to `@SceneStorage` later if a
/// user wants the tree-state to persist across reopens.
struct PortOutline: View {
    let port: ManifoldKit.Port
    let depth: Int
    /// Set to `true` when any port in the host tree has children
    /// (i.e. there's at least one hub somewhere). When `false`, the
    /// chevron column AND the per-depth indent collapse to zero
    /// width — there's no disclosure UX to surface, so the rows
    /// flush against the leading inset instead of carrying an
    /// always-empty gutter. Computed once at the root scope and
    /// threaded down so siblings agree.
    let anyExpandable: Bool
    @Bindable var graph: PortGraph
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                if anyExpandable, depth > 0 {
                    Color.clear
                        .frame(
                            width: CGFloat(depth) * PopoverRootConstants.outlineIndentPerLevel
                        )
                }
                chevronColumn
                PortRow(
                    port: port,
                    history: graph.history(forPortID: port.id),
                    diagnostics: graph.diagnostics(forPortID: port.id)
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)

            if isExpanded, !port.children.isEmpty {
                ForEach(port.children, id: \.id) { child in
                    PortOutline(
                        port: child,
                        depth: depth + 1,
                        anyExpandable: anyExpandable,
                        graph: graph
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var chevronColumn: some View {
        if !anyExpandable {
            EmptyView()
        } else if !port.children.isEmpty {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(
                        width: PopoverRootConstants.chevronColumnWidth,
                        alignment: .center
                    )
            }
            .buttonStyle(.plain)
        } else {
            Color.clear
                .frame(width: PopoverRootConstants.chevronColumnWidth)
        }
    }

    /// Recursive check — `true` when this port or any of its
    /// descendants has children. Used at the root scope to compute
    /// the `anyExpandable` flag once for the whole tree.
    static func anyExpandable(in ports: [ManifoldKit.Port]) -> Bool {
        ports.contains { port in
            !port.children.isEmpty || PortOutline.anyExpandable(in: port.children)
        }
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
