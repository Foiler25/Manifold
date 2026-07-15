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
// ProScreenWindow.swift

import AppKit
import SwiftUI

enum ProScreen: String, Codable, Hashable {
    case power
    case negotiation
    case display

    var title: String {
        switch self {
        case .power: String(localized: "Power Monitor")
        case .negotiation: String(localized: "Negotiation Diagnostics")
        case .display: String(localized: "Display Diagnostics")
        }
    }

    var frameAutosaveName: String {
        switch self {
        case .power: "ManifoldPowerMonitorWindow"
        case .negotiation: "ManifoldNegotiationWindow"
        case .display: "ManifoldDisplayDiagnosticsWindow"
        }
    }
}

struct DetachToolbarButton: ToolbarContent {
    @Environment(\.openWindow) private var openWindow
    let screen: ProScreen

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                openWindow(id: "manifold.proScreen", value: screen)
            } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
            .help("Open \(screen.title) in a new window")
            .accessibilityIdentifier("proScreen.detach.\(screen.rawValue)")
        }
    }
}

struct ProScreenCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Divider()
            ForEach(
                [ProScreen.power, .negotiation, .display],
                id: \.self
            ) { screen in
                Button("Open \(screen.title) in New Window") {
                    openWindow(id: "manifold.proScreen", value: screen)
                }
            }
        }
    }
}

struct ProScreenWindow: View {
    let screen: ProScreen
    @Bindable var cableEngine: CableEngine
    @Bindable var powerEngine: PowerTelemetryEngine
    let onCableAppear: (String) -> Void
    let onCableDisappear: (String) -> Void
    let onPowerAppear: (String) -> Void
    let onPowerDisappear: (String) -> Void

    private var surfaceID: String { "proScreen.\(screen.rawValue)" }

    var body: some View {
        Group {
            switch screen {
            case .power:
                PowerMonitorView(
                    engine: powerEngine,
                    cableEngine: cableEngine,
                    onAppear: { onPowerAppear(surfaceID) },
                    onDisappear: { onPowerDisappear(surfaceID) }
                )
            case .negotiation:
                NegotiationDiagnosticsView(
                    engine: cableEngine,
                    powerEngine: powerEngine,
                    onAppear: { onPowerAppear(surfaceID) },
                    onDisappear: { onPowerDisappear(surfaceID) }
                )
            case .display:
                DisplayDiagnosticsView(engine: cableEngine)
            }
        }
        .frame(minWidth: 620, minHeight: 440)
        .navigationTitle(screen.title)
        .background(
            WindowFrameAutosaveInstaller(
                identifier: "ManifoldProWindow.\(screen.rawValue)",
                autosaveName: screen.frameAutosaveName
            )
        )
        .onAppear { onCableAppear(surfaceID) }
        .onDisappear { onCableDisappear(surfaceID) }
        .accessibilityIdentifier("proScreen.window.\(screen.rawValue)")
    }
}

struct WindowFrameAutosaveInstaller: NSViewRepresentable {
    let identifier: String
    let autosaveName: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWindow(for: nsView)
    }

    private func configureWindow(for view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.identifier = NSUserInterfaceItemIdentifier(identifier)
            if window.frameAutosaveName != autosaveName {
                window.setFrameAutosaveName(autosaveName)
            }
        }
    }
}
