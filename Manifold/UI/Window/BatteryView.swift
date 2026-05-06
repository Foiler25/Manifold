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
// ─────────────────────────────────────────────────────────────────────
// BatteryView.swift
//
// Battery tab — merged surface for input (active charger),
// output (USB power draw), and battery state. Replaces the
// previous split between the Battery and Power tabs after the
// Power tab's standalone "input source" header was prone to
// misreporting "On battery" when an adapter was connected but
// macOS hadn't published `inputAdapter` yet. The merged tab uses
// the battery's own `chargeState` for the charging signal (the
// pill in the banner) and only surfaces the wall-adapter wattage
// as a small caption when one is reported.
//
// Layout (top-down):
//   - USB Power Draw (Total / Connected / per-device) — always
//     shown; useful even on desktop Macs that have no battery.
//   - Charge banner (only when battery present) — percent +
//     time-remaining + "Topped off" + adapter wattage caption.
//   - Battery health / Temperature / Power & Electrical /
//     Capacity Details — only when battery present.
//
// On desktop hardware (no battery) the banner and battery cards
// are skipped; the USB Power Draw card becomes the only content
// and the desktop empty-state hint sits beneath it.

import SwiftUI
import ManifoldKit

struct BatteryView: View {

    @Bindable var graph: PortGraph

    /// Current host. Drives the USB power-draw card + the input
    /// adapter caption inside the charge banner. nil during cold
    /// launch (rare) — the USB card is hidden in that case.
    let host: ManifoldKit.Host?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let battery = graph.battery {
                    // Charge banner is the hero — large percent +
                    // time-remaining + adapter wattage caption.
                    card {
                        ChargeBannerSection(
                            battery: battery,
                            inputAdapter: host?.inputAdapter
                        )
                    }
                    // USB Power Draw sits directly under the banner so
                    // input (adapter) and output (USB devices) are
                    // visually paired beneath the headline figure.
                    if let host {
                        card { USBPowerDrawSection(host: host) }
                    }
                    card { BatteryHealthSection(battery: battery) }
                    card { TemperatureSection(battery: battery) }
                    card { PowerElectricalSection(battery: battery) }
                    card { CapacityDetailsSection(battery: battery) }
                } else if let host {
                    // Desktop Mac path: USB Power Draw is the only
                    // meaningful card; show a small reminder underneath
                    // that the battery surfaces are unavailable.
                    card { USBPowerDrawSection(host: host) }
                    desktopBatteryHint
                } else {
                    // Cold launch: no host yet, no battery — fall back
                    // to the generic empty state.
                    emptyState
                }
            }
            .padding(20)
        }
        .accessibilityIdentifier("window.tab.battery.populated")
    }

    // MARK: - Card wrapper

    /// Common card chrome (padded + rounded-corner background).
    /// Extracted so each subview's call site reads as a flat list,
    /// not a deeply nested view tree.
    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(BatteryViewConstants.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: BatteryViewConstants.cardCornerRadius)
                    .fill(Color.manifoldCard)
            )
    }

    // MARK: - Desktop / empty paths

    /// Inline hint shown beneath the USB draw card on desktop Macs.
    /// Smaller than the legacy full-pane empty state because the
    /// USB card already filled the surface above it — the hint just
    /// explains the absence of battery info, no need for a giant
    /// glyph + headline.
    private var desktopBatteryHint: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bolt.batteryblock.slash")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("window.battery.empty.title")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.manifoldText)
                    .accessibilityIdentifier("window.tab.battery.empty.title")
                Text("window.battery.empty.subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
        }
        .padding(BatteryViewConstants.cardPadding)
    }

    /// Cold-launch empty state — no host yet and no battery. The
    /// USB walker hasn't returned any data; show the same "no host"
    /// placeholder the rest of the window uses.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.batteryblock.slash")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("window.battery.empty.title")
                .font(.headline)
                .foregroundStyle(Color.manifoldText)
                .accessibilityIdentifier("window.tab.battery.empty.title")
            Text("window.battery.empty.subtitle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Constants

    private enum BatteryViewConstants {
        /// Padding inside each tab card — slightly more generous than
        /// the popover so the larger window's airier baseline reads
        /// as native.
        static let cardPadding: CGFloat = 16

        /// Corner radius of each tab card. Matches the popover's
        /// card radius so the two surfaces feel visually unified.
        static let cardCornerRadius: CGFloat = 12
    }
}

#Preview("BatteryView — populated") {
    let graph = PortGraph()
    graph.replace(hosts: [PreviewData.macBook])
    graph.applyBattery(BatteryViewPreviewData.healthy)
    return BatteryView(graph: graph, host: PreviewData.macBook)
        .frame(width: 540, height: 720)
        .background(Color.manifoldSurface)
}

#Preview("BatteryView — desktop Mac (no battery)") {
    let graph = PortGraph()
    graph.replace(hosts: [PreviewData.macBook])
    return BatteryView(graph: graph, host: PreviewData.macBook)
        .frame(width: 540, height: 600)
        .background(Color.manifoldSurface)
}

// MARK: - Preview data

/// Battery preview helper. Lives next to BatteryView (rather than in
/// `ManifoldKit/Sources/Previews/PreviewData.swift`) because
/// `BatteryInfo` is in ManifoldKit but PreviewData is shared across
/// targets — keeping the battery seed local to the Battery tab module
/// avoids cross-cutting changes for one preview.
enum BatteryViewPreviewData {

    /// Healthy MacBook Pro 14" battery, charging at 84%, ~24 min to
    /// full, 47 cycles, 32.4°C, 12.45 V × +1234 mA.
    static let healthy = BatteryInfo(
        chargePercent: 84,
        chargeState: .charging,
        healthPercent: 96,
        cycleCount: 47,
        temperatureCelsius: 32.4,
        voltageVolts: 12.45,
        amperageMilliamps: 1234,
        powerWatts: 12.45 * 1.234,
        designCapacityMAh: 4380,
        nominalCapacityMAh: 4205,
        currentCapacityMAh: 3680,
        timeUntilFullMinutes: 24,
        timeUntilEmptyMinutes: nil,
        isExternalConnected: true,
        isFullyCharged: false,
        sampledAt: Date(timeIntervalSince1970: 1_735_689_600)
    )

    /// Aged battery on battery power, 38% charge, 3h 15m remaining,
    /// 1240 cycles, health 71% (Fair).
    static let agedDischarging = BatteryInfo(
        chargePercent: 38,
        chargeState: .discharging,
        healthPercent: 71,
        cycleCount: 1240,
        temperatureCelsius: 28.7,
        voltageVolts: 11.32,
        amperageMilliamps: -2150,
        powerWatts: 11.32 * 2.150,
        designCapacityMAh: 4380,
        nominalCapacityMAh: 3110,
        currentCapacityMAh: 1180,
        timeUntilFullMinutes: nil,
        timeUntilEmptyMinutes: 195,
        isExternalConnected: false,
        isFullyCharged: false,
        sampledAt: Date(timeIntervalSince1970: 1_735_689_600)
    )
}
