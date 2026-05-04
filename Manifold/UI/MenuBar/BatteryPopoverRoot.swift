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
// `BatteryView` without the info-popover `(i)` buttons and with a
// single "Open Manifold" toolbar button — no Settings shortcut, since
// the primary popover already exposes it.
//
// Reuses the existing `ChargeBannerSection` / `BatteryDetailRow`
// shapes from `BatteryViewSections.swift` so the two surfaces stay
// visually synchronized — when one renames a row label or the
// charge-state pill changes color, the other follows automatically.

import SwiftUI
import ManifoldKit

struct BatteryPopoverRoot: View {

    @Bindable var graph: PortGraph

    /// Closure dispatched when the user clicks "Open Manifold". Owned
    /// by the caller (BatteryStatusItemController / AppDelegate) so
    /// the popover doesn't depend on AppKit globals directly.
    let onOpenWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let battery = graph.battery {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ChargeBannerSection(battery: battery)

                        Divider()

                        // Health snapshot — % + cycle count, no info
                        // popover button (per the popover-content
                        // contract).
                        VStack(alignment: .leading, spacing: 8) {
                            Text("window.battery.section.health")
                                .font(.caption.smallCaps())
                                .foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(battery.healthPercent)%")
                                    .font(.title3.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(Color.manifoldText)
                                ConditionBadge(condition: battery.healthCondition)
                            }
                            BatteryDetailRow(
                                labelKey: "window.battery.field.cycleCount",
                                value: String(battery.cycleCount)
                            )
                        }

                        Divider()

                        // Power snapshot — W + signed mA. Kept compact.
                        VStack(alignment: .leading, spacing: 8) {
                            Text("window.battery.section.power")
                                .font(.caption.smallCaps())
                                .foregroundStyle(.secondary)
                            BatteryDetailRow(
                                labelKey: "window.battery.field.power",
                                value: String(format: "%.2f W", battery.powerWatts)
                            )
                            BatteryDetailRow(
                                labelKey: "window.battery.field.current",
                                value: String(format: "%+d mA", battery.amperageMilliamps)
                            )
                        }
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

#Preview("BatteryPopoverRoot — populated") {
    let graph = PortGraph()
    graph.applyBattery(BatteryViewPreviewData.healthy)
    return BatteryPopoverRoot(graph: graph, onOpenWindow: {})
}

#Preview("BatteryPopoverRoot — empty") {
    BatteryPopoverRoot(graph: PortGraph(), onOpenWindow: {})
}
