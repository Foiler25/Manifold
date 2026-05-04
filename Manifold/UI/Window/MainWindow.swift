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
// `WindowGroup` content per SPEC.md §13.2 / §18 Phase 6, with a Phase
// "native polish" pass:
//
//   - Two-column `NavigationSplitView`:
//     * Sidebar (HostSidebar)
//     * Detail  (the active tab's content)
//   - Tabs live in the window toolbar as a segmented `Picker`.
//   - The DeviceInspector is presented via SwiftUI's `.inspector`
//     modifier (macOS 14+) so it gets native chrome and a toolbar
//     toggle, instead of being a third NavigationSplitView column.
//
// Window state persists across launches (selected tab, host, device
// IDs, inspector visibility via `@SceneStorage`; window size/position
// via `NSWindow.frameAutosaveName` set in AppDelegate's window
// bring-up).
//
// `onWindowAppear` / `onWindowDisappear` callbacks let AppDelegate
// hook `SamplerLifecycle.windowDid{Appear,Disappear}()`.

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

    /// Explicit column visibility, defaulting to `.all` so SwiftUI
    /// doesn't auto-collapse the content + detail columns when the
    /// restored window frame is narrower than expected. Without this
    /// the user could end up looking at sidebar-only chrome with no
    /// way back besides resizing the window.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

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
        NavigationSplitView(columnVisibility: $columnVisibility) {
            HostSidebar(graph: graph, selectedHostID: selectedHostID)
                .navigationSplitViewColumnWidth(
                    min: MainWindowConstants.sidebarMinWidth,
                    ideal: MainWindowConstants.sidebarIdealWidth,
                    max: MainWindowConstants.sidebarMaxWidth
                )
        } content: {
            VStack(spacing: 0) {
                tabPickerBar
                Divider()
                tabContent
            }
            .navigationTitle(navigationTitle)
            // `.navigationSplitViewColumnWidth(ideal:)` with no min/max
            // lets the content column flex freely as the user resizes
            // the window — it absorbs the slack between sidebar and
            // inspector mins instead of pinning to a fixed range.
            .navigationSplitViewColumnWidth(
                ideal: MainWindowConstants.contentIdealWidth
            )
        } detail: {
            DeviceInspector(
                graph: graph,
                selectedDeviceID: selectedDeviceID.wrappedValue
            )
            .navigationSplitViewColumnWidth(
                min: MainWindowConstants.inspectorMinWidth,
                ideal: MainWindowConstants.inspectorIdealWidth,
                max: MainWindowConstants.inspectorMaxWidth
            )
        }
        // `.balanced` keeps every column embedded in the window.
        // `.automatic` could pick `.prominentDetail` and float the
        // sidebar as a translucent overlay detached from the main
        // window — that was the "left panel half hidden" symptom.
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: MainWindowConstants.minimumWindowSize.width,
            minHeight: MainWindowConstants.minimumWindowSize.height
        )
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
        // ⌘1/⌘2/⌘3 menu commands route through a process-wide
        // notification (single-WindowGroup app, same pattern Phase
        // 11 used for File ▸ Export). The userInfo payload carries
        // the WindowTab.rawValue.
        .onReceive(NotificationCenter.default.publisher(for: .manifoldSelectTab)) { note in
            if let raw = note.userInfo?["tab"] as? String,
               let tab = WindowTab(rawValue: raw) {
                selectedTab.wrappedValue = tab
            }
        }
    }

    // MARK: - Toolbar

    /// Inline picker bar that sits at the top of the content pane.
    /// Living inside the content `VStack` (rather than as a
    /// `ToolbarItem`) keeps the segments visually inside the middle
    /// pane: a unified-toolbar `ToolbarItem(placement: .principal)`
    /// competed with the window title, and `.primaryAction` rendered
    /// past the inspector divider. The `.bar` material matches the
    /// title bar's translucency so the two read as one continuous
    /// chrome strip.
    private var tabPickerBar: some View {
        HStack {
            Picker(selection: selectedTab) {
                ForEach(WindowTab.allCases) { tab in
                    Label(LocalizedStringKey(tab.labelKey), systemImage: tab.systemImageName)
                        .accessibilityIdentifier("window.tab.\(tab.rawValue)")
                        .tag(tab)
                }
            } label: {
                Text("window.toolbar.tab.picker.label")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Tab content + helpers

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

    /// Window title text. Defaults to the selected host name so the
    /// title bar reads "temporary-max-pro.local" rather than the
    /// generic app name; falls back to the app name on cold launch
    /// before the first walk has populated the graph.
    private var navigationTitle: String {
        selectedHostObject()?.name
            ?? NSLocalizedString("window.title.fallback", comment: "")
    }

    /// Resolve the persisted host selection against the live graph.
    /// If the persisted ID isn't present (host unplugged between
    /// launches — not realistic for a Mac, but defensive), default to
    /// the first host so the content always has something to render.
    /// Returns nil only when the graph itself has no hosts (cold
    /// launch before first walk).
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
    /// commands so MainWindow updates `selectedTab`. `userInfo["tab"]`
    /// carries the WindowTab.rawValue. Same process-wide pattern
    /// Phase 11 used for the Export sheet.
    static let manifoldSelectTab = Notification.Name("com.Loofa.Manifold.selectTab")
}
