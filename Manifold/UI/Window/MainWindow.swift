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

    /// Phase 10: nil when persistence init failed, so the History
    /// tab can render an empty state instead of crashing.
    let eventRepository: EventRepository?

    /// Phase 11: passed through to ExportSheet for the telemetry-CSV
    /// export path. nil when persistence init failed.
    let sampleRepository: SampleRepository?

    let onWindowAppear: () -> Void
    let onWindowDisappear: () -> Void

    /// Phase 11: drives the File menu's "Export…" sheet. Toggled by
    /// the menu command and by the Cmd-E shortcut.
    @State private var isExportSheetPresented: Bool = false

    /// Phase 15: tab-bar focus tracking. SPEC §18 Phase 15 #8 +
    /// F18 close: the custom HStack-of-Buttons tabBar from Phase 6
    /// gets focus-ring rendering, arrow-key navigation between
    /// adjacent tabs, and ⌘1/⌘2/⌘3 jump bindings. SwiftUI's
    /// `@FocusState` drives the focus ring; the keyboard handlers
    /// move both the focus AND the selected-tab binding so VoiceOver
    /// reads the change consistently.
    @FocusState private var focusedTab: WindowTab?

    /// Phase 15 #7: first-launch onboarding. Default false →
    /// sheet presents on first MainWindow appearance; the sheet's
    /// Done button flips it to true and dismisses. Subsequent
    /// launches skip the sheet.
    @AppStorage(SettingsKeys.onboardingCompleted)
    private var onboardingCompleted: Bool = false

    @State private var isOnboardingPresented: Bool = false

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
        .sheet(isPresented: $isExportSheetPresented) {
            ExportSheet(
                graph: graph,
                eventRepository: eventRepository,
                sampleRepository: sampleRepository
            )
        }
        .sheet(isPresented: $isOnboardingPresented) {
            OnboardingSheet()
        }
        .onAppear {
            // Phase 15 #7: present the onboarding sheet on first
            // appearance if the user hasn't completed it. Wrapping
            // in `DispatchQueue.main.async` ensures the parent
            // window has rendered before the sheet animates in.
            if !onboardingCompleted {
                DispatchQueue.main.async {
                    isOnboardingPresented = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .manifoldShowExportSheet)) { _ in
            isExportSheetPresented = true
        }
        // Phase 15 #8 + F18: ⌘1/⌘2/⌘3 menu commands route through
        // a process-wide notification (single-WindowGroup app, same
        // pattern Phase 11 used for File ▸ Export). The userInfo
        // payload carries the WindowTab.rawValue.
        .onReceive(NotificationCenter.default.publisher(for: .manifoldSelectTab)) { note in
            if let raw = note.userInfo?["tab"] as? String,
               let tab = WindowTab(rawValue: raw) {
                selectedTab.wrappedValue = tab
                focusedTab = tab
            }
        }
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
        // Phase 15 #8 + F18: arrow-key navigation between tabs.
        // SwiftUI dispatches the keypress to the focused descendant
        // first; if no tab has focus we still respond here so the
        // user can hit Left/Right after Tabbing to the bar.
        .onKeyPress(.leftArrow, action: { advanceFocus(by: -1) })
        .onKeyPress(.rightArrow, action: { advanceFocus(by: 1) })
    }

    private func tabButton(for tab: WindowTab) -> some View {
        let active = selectedTab.wrappedValue == tab
        let position = (WindowTab.allCases.firstIndex(of: tab) ?? 0) + 1
        return Button {
            selectedTab.wrappedValue = tab
            focusedTab = tab
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
        // Phase 15 #8 + F18: focus ring rendering. The default
        // `.plain` button style + `@FocusState` produces a system
        // focus ring around the active button when it's the
        // keyboard focus target.
        .focused($focusedTab, equals: tab)
        // VoiceOver reads "Topology, tab, 1 of 3" style. Position
        // text is localized via the `accessibility.tab.position`
        // key with `%1$lld` of `%2$lld`.
        .accessibilityLabel(LocalizedStringKey(tab.labelKey))
        .accessibilityValue(
            String(
                format: NSLocalizedString("accessibility.tab.position", comment: ""),
                position,
                WindowTab.allCases.count
            )
        )
        .accessibilityAddTraits(active ? [.isSelected, .isHeader] : .isHeader)
        // Stable identifier for `WindowUITests` queries — must match
        // the values referenced by `WindowUITests.swift`. Format
        // `window.tab.<rawValue>` keeps the binding obvious without a
        // separate constants table.
        .accessibilityIdentifier("window.tab.\(tab.rawValue)")
    }

    /// F18 closure helper. `delta = +1` for Right-Arrow, `-1` for
    /// Left-Arrow. Wraps at the ends so the user doesn't get
    /// stuck on the first/last tab (matches NSTabView native
    /// behaviour). Updates BOTH `selectedTab` (so the content
    /// column re-renders) and `focusedTab` (so the focus ring
    /// follows).
    private func advanceFocus(by delta: Int) -> KeyPress.Result {
        let cases = WindowTab.allCases
        let current = focusedTab ?? selectedTab.wrappedValue
        guard let i = cases.firstIndex(of: current) else { return .ignored }
        let next = cases[(i + delta + cases.count) % cases.count]
        focusedTab = next
        selectedTab.wrappedValue = next
        return .handled
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
            HistoryView(eventRepository: eventRepository)
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
        eventRepository: nil,
        sampleRepository: nil,
        onWindowAppear: {},
        onWindowDisappear: {}
    )
    .frame(width: 920, height: 600)
}

#Preview("MainWindow — empty (cold launch state)") {
    MainWindow(
        graph: PortGraph(),
        eventRepository: nil,
        sampleRepository: nil,
        onWindowAppear: {},
        onWindowDisappear: {}
    )
    .frame(width: 920, height: 600)
}

// MARK: - Phase 11 menu signal

extension Notification.Name {
    /// Phase 11: posted by `ManifoldApp`'s File ▸ Export… `CommandGroup`
    /// so any open MainWindow opens its ExportSheet. The
    /// SwiftUI-`@FocusedValue` route would scope to the focused
    /// scene, but we have a single WindowGroup so a process-wide
    /// notification is simpler and doesn't require threading state
    /// through the menu commands.
    static let manifoldShowExportSheet = Notification.Name("com.Loofa.Manifold.showExportSheet")

    /// Phase 15 #8 + F18: posted by the View ▸ ⌘1/⌘2/⌘3 menu
    /// commands so MainWindow updates `selectedTab` + `focusedTab`.
    /// `userInfo["tab"]` carries the WindowTab.rawValue. Same
    /// process-wide pattern Phase 11 used for the Export sheet.
    static let manifoldSelectTab = Notification.Name("com.Loofa.Manifold.selectTab")
}
