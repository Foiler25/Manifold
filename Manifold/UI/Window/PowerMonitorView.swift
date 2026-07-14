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
// PowerMonitorView.swift

import Charts
import SwiftUI

struct PowerMonitorView: View {
    @Bindable var engine: PowerTelemetryEngine
    @Bindable var cableEngine: CableEngine
    let onAppear: () -> Void
    let onDisappear: () -> Void

    var body: some View {
        Group {
            if let snapshot = engine.snapshot {
                content(snapshot)
            } else if engine.isRunning {
                ContentUnavailableView(
                    "Reading power telemetry…",
                    systemImage: "bolt.badge.clock"
                )
            } else {
                ContentUnavailableView(
                    "Power metering isn't available on this Mac",
                    systemImage: "bolt.slash",
                    description: Text("Manifold will retry whenever this screen is visible.")
                )
            }
        }
        .accessibilityIdentifier("window.tab.power.root")
        .onAppear(perform: onAppear)
        .onDisappear(perform: onDisappear)
        .toolbar { DetachToolbarButton(screen: .power) }
    }

    private func content(_ snapshot: PowerMonitorSnapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                powerChart(snapshot)
                systemCard(snapshot)

                if snapshot.portSamples.isEmpty {
                    Text(snapshot.perPortMeteringSupported
                         ? "No ports are currently drawing power."
                         : "Live per-port metering isn't available on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                } else {
                    ForEach(snapshot.portSamples, id: \.portKey) { sample in
                        portCard(sample, snapshot: snapshot)
                    }
                }

                if let adapter = cableEngine.snapshot?.adapter, !adapter.hvcMenu.isEmpty {
                    hvcCard(adapter)
                }
            }
            .padding(20)
        }
    }

    private func powerChart(_ snapshot: PowerMonitorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(snapshot.onBattery ? "System discharge" : "System power input")
                    .font(.headline)
                Spacer()
                Text(watts(snapshot.activePowerMW))
                    .font(.title2.monospacedDigit().weight(.semibold))
            }
            Chart(Array(engine.history.enumerated()), id: \.offset) { index, sample in
                AreaMark(
                    x: .value("Sample", index),
                    y: .value("Watts", Double(sample.systemPowerIn) / 1000)
                )
                .foregroundStyle(chartColor.opacity(0.18))
                LineMark(
                    x: .value("Sample", index),
                    y: .value("Watts", Double(sample.systemPowerIn) / 1000)
                )
                .foregroundStyle(chartColor)
                .interpolationMethod(.catmullRom)
            }
            .chartYAxisLabel("W")
            .frame(height: 150)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func systemCard(_ snapshot: PowerMonitorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(snapshot.onBattery ? "Battery" : "System Power", systemImage: "bolt.fill")
                    .font(.headline)
                Spacer()
                resistanceChip(snapshot.resistanceEstimate)
            }
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 6) {
                metricRow("Voltage", value: volts(snapshot.activeVoltageMV))
                metricRow("Current", value: amps(snapshot.activeCurrentMA))
                metricRow("Power", value: watts(snapshot.activePowerMW))
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func portCard(_ sample: PortPowerSample, snapshot: PowerMonitorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(portName(sample.portKey), systemImage: "cable.connector")
                    .font(.headline)
                Spacer()
                Text(sample.isContractedFallback ? "Contracted max" : watts(sample.watts * 10))
                    .font(.headline.monospacedDigit())
            }
            if sample.isContractedFallback {
                Text("Live metering isn't available; this is the negotiated contract ceiling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Configured \(volts(sample.configuredVoltage)) × \(amps(sample.configuredCurrent))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if sample.vconnPower > 0 || sample.vconnCurrent > 0 {
                    Text("VConn \(watts(sample.vconnPower)) · \(amps(sample.vconnCurrent))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let contract = engine.contracts[sample.portKey] {
                PDContractInspector(contract: contract)
            } else if let source = cableEngine.snapshot?.powerSources.first(where: {
                $0.portKey == sample.portKey && !$0.options.isEmpty
            }) {
                PDPowerSourceInspector(source: source)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("power.port.card")
    }

    private func hvcCard(_ adapter: CableAdapterInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(adapter.name ?? "Charger profiles", systemImage: "powerplug")
                .font(.headline)
            ForEach(Array(adapter.hvcMenu.enumerated()), id: \.offset) { index, entry in
                HStack {
                    Image(systemName: index == adapter.hvcActiveIndex ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(index == adapter.hvcActiveIndex ? Color.accentColor : Color.secondary)
                    Text("\(entry.label) · \(entry.wattsInt)W")
                        .font(.caption.monospacedDigit())
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func resistanceChip(_ estimate: CableResistanceEstimate?) -> some View {
        if let estimate, let tier = estimate.tier(ratedFiveA: false) {
            Text("\(tier.rawValue.capitalized) · \(Int(estimate.milliohms.rounded())) mΩ")
                .font(.caption.weight(.medium))
                .foregroundStyle(tier == .high ? .red : tier == .marginal ? .orange : .green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
        } else {
            Text("Resistance measuring…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var chartColor: Color {
        engine.snapshot?.externalConnected == true ? .accentColor : .secondary
    }

    private func portName(_ key: String) -> String {
        guard let port = cableEngine.snapshot?.ports.first(where: { $0.portKey == key }) else {
            return "Port \(key)"
        }
        return port.portDescription ?? port.serviceName
    }

    private func watts(_ milliwatts: Int) -> String {
        PowerUnitFormatter.watts(milliwatts)
    }

    private func volts(_ millivolts: Int) -> String {
        String(format: "%.2f V", Double(millivolts) / 1000)
    }

    private func amps(_ milliamps: Int) -> String {
        String(format: "%.2f A", Double(milliamps) / 1000)
    }

    @ViewBuilder
    private func metricRow(_ name: String, value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}
