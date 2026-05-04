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
                        ChargeBannerSection(battery: battery)
                            .padding(BatteryPopoverRootConstants.cardPadding)
                            .background(
                                RoundedRectangle(cornerRadius: BatteryPopoverRootConstants.cardCornerRadius)
                                    .fill(Color.manifoldCard)
                            )

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

            // Bottom toolbar — single "Open Manifold" button per
            // SPEC §20.6.
            HStack {
                Button(action: onOpenWindow) {
                    Label("popover.toolbar.openWindow", systemImage: "macwindow")
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("popover.toolbar.openWindow.accessibility")
                Spacer()
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
    return BatteryPopoverRoot(graph: graph, onOpenWindow: {})
}

#Preview("BatteryPopoverRoot — empty") {
    BatteryPopoverRoot(graph: PortGraph(), onOpenWindow: {})
}
