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
// PowerTelemetryEngine.swift

import Foundation

@MainActor
protocol PowerTelemetrySource: AnyObject {
    var snapshots: AsyncStream<PowerMonitorSnapshot> { get }
    func start()
    func stop()
    func updatePorts(_ ports: [AppleHPMInterface])
    func resetResistanceBaseline()
}

@MainActor
protocol PortDiagnosticsSource: AnyObject {
    var snapshots: AsyncStream<PortDiagnosticsWatcher.PortDiagnosticsSnapshot> { get }
    func start()
    func stop()
}

extension PowerTelemetryWatcher: PowerTelemetrySource {}
extension PortDiagnosticsWatcher: PortDiagnosticsSource {}

@MainActor
@Observable
final class PowerTelemetryEngine {
    private(set) var snapshot: PowerMonitorSnapshot?
    private(set) var history: [PowerSample] = []
    private(set) var contracts: [String: PDContract] = [:]
    private(set) var isRunning = false

    private let telemetry: any PowerTelemetrySource
    private let diagnostics: any PortDiagnosticsSource
    private let historyLimit: Int
    private var telemetryTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?

    init(
        telemetry: any PowerTelemetrySource = PowerTelemetryWatcher(),
        diagnostics: any PortDiagnosticsSource = PortDiagnosticsWatcher(),
        historyLimit: Int = 60
    ) {
        self.telemetry = telemetry
        self.diagnostics = diagnostics
        self.historyLimit = max(1, historyLimit)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        telemetry.start()
        diagnostics.start()

        let telemetryStream = telemetry.snapshots
        telemetryTask = Task { [weak self] in
            for await value in telemetryStream {
                guard !Task.isCancelled, let self else { break }
                self.receive(value)
            }
        }

        let diagnosticsStream = diagnostics.snapshots
        diagnosticsTask = Task { [weak self] in
            for await value in diagnosticsStream {
                guard !Task.isCancelled, let self else { break }
                self.contracts = value.contracts
            }
        }
    }

    func stop() {
        telemetryTask?.cancel()
        telemetryTask = nil
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        telemetry.stop()
        diagnostics.stop()
        isRunning = false
    }

    func updatePorts(_ ports: [AppleHPMInterface]) {
        telemetry.updatePorts(ports)
    }

    func resetResistanceBaseline() {
        telemetry.resetResistanceBaseline()
        history.removeAll(keepingCapacity: true)
    }

    private func receive(_ value: PowerMonitorSnapshot) {
        snapshot = value
        let chartSample = value.onBattery
            ? PowerSample(
                timestamp: value.timestamp,
                systemVoltageIn: value.activeVoltageMV,
                systemCurrentIn: value.activeCurrentMA,
                systemPowerIn: value.activePowerMW
            )
            : value.systemSample
        history.append(chartSample)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }
}
