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
// MainWindow.swift
//
// `WindowGroup` content per SPEC.md §13.2 / §18 Phase 6:
//
//   - `NavigationSplitView` with three columns:
//     * Sidebar  (HostSidebar)
//     * Content  (TabView: Topology / History / Diagnostics)
//     * Detail   (DeviceInspector)
//
//   - Top tabs above the content column.
//   - Window state persists across launches (selected tab, host,
//     device IDs via `@SceneStorage`; window size/position via
//     `NSWindow.frameAutosaveName` set in AppDelegate's window
//     bring-up — handled by SwiftUI's WindowGroup automatically when
//     `.windowResizability` is set).
//
// `onWindowAppear` / `onWindowDisappear` callbacks let AppDelegate
// hook `SamplerLifecycle.windowDid{Appear,Disappear}()`. Phase 5
// declared the lifecycle hooks; Phase 6 wires them.

import SwiftUI
import ManifoldKit

struct MainWindow: View {

    @Bindable var graph: PortGraph

    let onWindowAppear: () -> Void
    let onWindowDisappear: () -> Void

    // MARK: - Persisted scene state

    @SceneStorage(MainWindowConstants.sceneStorageSelectedTabKey)
    private var selectedTabRaw: String = WindowTab.topology.rawValue

    @SceneStorage(MainWindowConstants.sceneStorageSelectedHostKey)
    private var selectedHostRaw: String = ""

    @SceneStorage(MainWindowConstants.sceneStorageSelectedDeviceKey)
    private var selectedDeviceRaw: String = ""

    /// Computed binding from the raw `String` `@SceneStorage` to the
    /// typed `WindowTab`. Falling back to `.topology` for any
    /// unexpected raw value (a future tab removal would otherwise
    /// strand users on a defunct selection).
    private var selectedTab: Binding<WindowTab> {
        Binding(
            get: { WindowTab(rawValue: selectedTabRaw) ?? .topology },
            set: { selectedTabRaw = $0.rawValue }
        )
    }

    /// nil-or-empty rawValue → nil HostID; serialized as empty string
    /// because `@SceneStorage` doesn't support optionals natively.
    private var selectedHostID: Binding<HostID?> {
        Binding(
            get: { selectedHostRaw.isEmpty ? nil : HostID(selectedHostRaw) },
            set: { selectedHostRaw = $0?.rawValue ?? "" }
        )
    }

    private var selectedDeviceID: Binding<DeviceID?> {
        Binding(
            get: { selectedDeviceRaw.isEmpty ? nil : DeviceID(selectedDeviceRaw) },
            set: { selectedDeviceRaw = $0?.rawValue ?? "" }
        )
    }

    // MARK: - Body

    var body: some View {
        NavigationSplitView {
            HostSidebar(graph: graph, selectedHostID: selectedHostID)
                .navigationSplitViewColumnWidth(
                    min: MainWindowConstants.sidebarMinWidth,
                    ideal: MainWindowConstants.sidebarIdealWidth,
                    max: MainWindowConstants.sidebarMaxWidth
                )
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(
                    min: MainWindowConstants.detailMinWidth + 40,
                    ideal: MainWindowConstants.defaultWindowSize.width
                        - MainWindowConstants.sidebarIdealWidth
                        - MainWindowConstants.detailIdealWidth
                )
        } detail: {
            DeviceInspector(graph: graph, selectedDeviceID: selectedDeviceID.wrappedValue)
                .navigationSplitViewColumnWidth(
                    min: MainWindowConstants.detailMinWidth,
                    ideal: MainWindowConstants.detailIdealWidth
                )
        }
        .frame(
            minWidth: MainWindowConstants.minimumWindowSize.width,
            minHeight: MainWindowConstants.minimumWindowSize.height
        )
        .background(Color.manifoldSurface)
        .onAppear { onWindowAppear() }
        .onDisappear { onWindowDisappear() }
    }

    // MARK: - Content column with tabs

    private var contentColumn: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            tabContent
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(WindowTab.allCases) { tab in
                tabButton(for: tab)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.manifoldCard)
    }

    private func tabButton(for tab: WindowTab) -> some View {
        let active = selectedTab.wrappedValue == tab
        return Button {
            selectedTab.wrappedValue = tab
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.systemImageName)
                Text(LocalizedStringKey(tab.labelKey))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(active ? Color.manifoldAccent.opacity(0.18) : Color.clear)
            .foregroundStyle(active ? Color.manifoldAccent : Color.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LocalizedStringKey(tab.labelKey))
        .accessibilityAddTraits(active ? .isSelected : [])
        // Stable identifier for `WindowUITests` queries — must match
        // the values referenced by `WindowUITests.swift`. Format
        // `window.tab.<rawValue>` keeps the binding obvious without a
        // separate constants table.
        .accessibilityIdentifier("window.tab.\(tab.rawValue)")
    }

    @ViewBuilder
    private var tabContent: some View {
        let host = selectedHostObject()
        switch selectedTab.wrappedValue {
        case .topology:
            TopologyCanvas(
                graph: graph,
                host: host,
                selectedDeviceID: selectedDeviceID
            )
        case .history:
            HistoryView()
        case .diagnostics:
            DiagnosticsBanner(graph: graph)
        }
    }

    /// Resolve the persisted host selection against the live graph.
    /// If the persisted ID isn't present (host unplugged between
    /// launches — not realistic for a Mac, but defensive), default to
    /// the first host so the content column always has something to
    /// render. Returns nil only when the graph itself has no hosts
    /// (cold launch before first walk).
    private func selectedHostObject() -> ManifoldKit.Host? {
        if let id = selectedHostID.wrappedValue,
           let match = graph.hosts.first(where: { $0.id == id }) {
            return match
        }
        return graph.hosts.first
    }
}

#Preview("MainWindow — populated") {
    let graph = PortGraph()
    graph.replace(hosts: [PreviewData.macBook])
    return MainWindow(
        graph: graph,
        onWindowAppear: {},
        onWindowDisappear: {}
    )
    .frame(width: 920, height: 600)
}

#Preview("MainWindow — empty (cold launch state)") {
    MainWindow(
        graph: PortGraph(),
        onWindowAppear: {},
        onWindowDisappear: {}
    )
    .frame(width: 920, height: 600)
}
