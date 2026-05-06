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
// BatteryPopoverRoot.swift
//
// Phase 18 — SwiftUI root for the battery popover (the secondary
// menu-bar item). Per SPEC §20.6 / Plan §18d: a condensed
// `BatteryView` with a single "Open Manifold" toolbar button — no
// Settings shortcut, since the primary popover already exposes it.
//
// 2026-05-04 UX revision: reaches Juicy parity. The charge banner
// stays at the top (always visible). Below it, a "Battery Information"
// `DisclosureGroup` wraps the four detail sections (Health,
// Temperature, Power & Electrical, Capacity Details) so the user can
// collapse the deep stats and keep the popover lean when they only
// want the percent.
//
// Reuses the same `*Section` views as the Battery tab so a styling
// change in either surface flows to both at once.

import SwiftUI
import ManifoldKit

struct BatteryPopoverRoot: View {

    @Bindable var graph: PortGraph

    /// Closure dispatched when the user clicks "Open Manifold". Owned
    /// by the caller (BatteryStatusItemController / AppDelegate) so
    /// the popover doesn't depend on AppKit globals directly.
    let onOpenWindow: () -> Void

    /// Closure dispatched when the user clicks the settings gear.
    /// AppDelegate writes `SettingsTabID.menubar.rawValue` into
    /// `SettingsKeys.selectedSettingsPaneId` before activating the
    /// app + opening Settings, so the window lands on the Menu Bar
    /// pane rather than wherever it was last.
    let onOpenSettings: () -> Void

    /// Bridges this view to SwiftUI's Settings-window opener. Shared
    /// shape with `PopoverRoot` — the AppKit closure activates the
    /// app, this environment action triggers the SwiftUI Settings
    /// scene to materialize / order-front.
    @Environment(\.openSettings) private var openSettingsAction

    /// Persists the disclosure-group state across popover open / close
    /// cycles. Default expanded — the user opened the popover to see
    /// the data, so the first impression should show it.
    @AppStorage(BatteryPopoverRootConstants.infoExpandedKey)
    private var isInfoExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let battery = graph.battery {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Pass the active host's `inputAdapter` so the
                        // charge banner can render its wattage caption
                        // (e.g. "65 W · MagSafe") under the time-
                        // remaining line — same as the merged Battery
                        // tab in the main window.
                        ChargeBannerSection(
                            battery: battery,
                            inputAdapter: graph.hosts.first?.inputAdapter
                        )
                            .padding(BatteryPopoverRootConstants.cardPadding)
                            .background(
                                RoundedRectangle(cornerRadius: BatteryPopoverRootConstants.cardCornerRadius)
                                    .fill(Color.manifoldCard)
                            )

                        // USB Power Draw card — same spot under the
                        // charge banner as the main window's Battery
                        // tab, so the popover and the larger surface
                        // read with the same vertical structure.
                        if let host = graph.hosts.first {
                            USBPowerDrawSection(host: host)
                                .padding(BatteryPopoverRootConstants.cardPadding)
                                .background(
                                    RoundedRectangle(cornerRadius: BatteryPopoverRootConstants.cardCornerRadius)
                                        .fill(Color.manifoldCard)
                                )
                        }

                        DisclosureGroup(
                            isExpanded: $isInfoExpanded
                        ) {
                            VStack(alignment: .leading, spacing: 14) {
                                BatteryHealthSection(battery: battery)
                                Divider()
                                TemperatureSection(battery: battery)
                                Divider()
                                PowerElectricalSection(battery: battery)
                                Divider()
                                CapacityDetailsSection(battery: battery)
                            }
                            .padding(.top, 12)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.manifoldAccent)
                                Text("window.battery.info.section.title")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.manifoldText)
                            }
                        }
                        .tint(.secondary)
                        .padding(BatteryPopoverRootConstants.cardPadding)
                        .background(
                            RoundedRectangle(cornerRadius: BatteryPopoverRootConstants.cardCornerRadius)
                                .fill(Color.manifoldCard)
                        )
                    }
                    .padding(16)
                }
            } else {
                emptyState
            }

            Divider()

            // Bottom toolbar — "Open Manifold" on the left, settings
            // gear on the right. Mirrors the primary popover's
            // toolbar shape so the two surfaces feel native together.
            // The gear deep-links into Settings → Menu Bar by
            // writing `SettingsTabID.menubar.rawValue` into the
            // selected-pane AppStorage key before openSettings fires.
            HStack(spacing: 12) {
                Button(action: onOpenWindow) {
                    Label("popover.toolbar.openWindow", systemImage: "macwindow")
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("popover.toolbar.openWindow.accessibility")

                Spacer()

                Button {
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
            width: AppConstants.batteryPopoverContentSize.width,
            alignment: .topLeading
        )
        .background(Color.manifoldSurface)
        .accessibilityIdentifier("menubar.battery.popover.root")
    }

    /// Empty-state — only reachable transiently (the controller
    /// install-gate ensures this popover is never created on hardware
    /// where `currentSnapshot()` returned nil at app start). Shown for
    /// the brief window before the first sampler tick lands.
    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "bolt.batteryblock")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("window.battery.empty.title")
                .font(.headline)
                .foregroundStyle(Color.manifoldText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
    }
}

// MARK: - Constants

enum BatteryPopoverRootConstants {
    /// `@AppStorage` key for the "Battery Information" disclosure-
    /// group state. Stored under `settings.menubar.battery.*` so it
    /// joins the existing Battery / Menu Bar settings family.
    static let infoExpandedKey: String = "settings.menubar.battery.popoverInfoExpanded"

    /// Padding inside each "card" container (Charge banner card +
    /// Battery Information card). Sized to leave breathing room
    /// around the section content without crowding the popover edges.
    static let cardPadding: CGFloat = 14

    /// Corner radius of each "card" container in the popover. Larger
    /// than the capacity-bar radius so the cards read as elevated
    /// surfaces, not as part of the bar grid.
    static let cardCornerRadius: CGFloat = 12
}

#Preview("BatteryPopoverRoot — populated") {
    let graph = PortGraph()
    graph.applyBattery(BatteryViewPreviewData.healthy)
    return BatteryPopoverRoot(graph: graph, onOpenWindow: {}, onOpenSettings: {})
}

#Preview("BatteryPopoverRoot — empty") {
    BatteryPopoverRoot(graph: PortGraph(), onOpenWindow: {}, onOpenSettings: {})
}
