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
// BatteryView.swift
//
// Phase 18 — root content for the Battery tab (5th tab, last in
// `WindowTab.allCases`). Mirrors `PowerView`'s shell (ScrollView +
// VStack of theme-card sections) so the tab feels native against the
// rest of the window.
//
// Empty-state path: when `graph.battery == nil` we render the
// "no battery detected" desktop-Mac copy (per §20.10). The empty-state
// title carries `accessibilityIdentifier("window.tab.battery.empty.title")`
// so the §18.0 `BATTERY-EMPTY-STATE-DESKTOP` Reviewer-deferred procedure
// can locate it programmatically when desktop hardware is available.

import SwiftUI
import ManifoldKit

struct BatteryView: View {

    @Bindable var graph: PortGraph

    var body: some View {
        if let battery = graph.battery {
            populated(battery: battery)
        } else {
            emptyState
        }
    }

    // MARK: - Populated

    private func populated(battery: BatteryInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ChargeBannerSection(battery: battery)
                Divider()
                BatteryHealthSection(battery: battery)
                Divider()
                TemperatureSection(battery: battery)
                Divider()
                PowerElectricalSection(battery: battery)
                Divider()
                CapacityDetailsSection(battery: battery)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("window.tab.battery.populated")
    }

    // MARK: - Empty state (desktop Mac path, §20.10)

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
}

#Preview("BatteryView — populated") {
    let graph = PortGraph()
    graph.applyBattery(BatteryViewPreviewData.healthy)
    return BatteryView(graph: graph)
        .frame(width: 540, height: 720)
        .background(Color.manifoldSurface)
}

#Preview("BatteryView — empty (desktop Mac)") {
    BatteryView(graph: PortGraph())
        .frame(width: 540, height: 600)
        .background(Color.manifoldSurface)
}

// MARK: - Preview data

/// Phase 18 preview helper. Lives next to BatteryView (rather than in
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
