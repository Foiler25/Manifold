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
// PowerTelemetryEngineTests.swift

import XCTest
@testable import Manifold

@MainActor
final class PowerTelemetryEngineTests: XCTestCase {
    func testConsumesSnapshotsAndKeepsBoundedHistory() async {
        let telemetry = StubPowerTelemetrySource()
        let diagnostics = StubPortDiagnosticsSource()
        let engine = PowerTelemetryEngine(
            telemetry: telemetry,
            diagnostics: diagnostics,
            historyLimit: 2
        )

        engine.start()
        telemetry.yield(snapshot(powerMW: 10_000, at: 1))
        telemetry.yield(snapshot(powerMW: 20_000, at: 2))
        telemetry.yield(snapshot(powerMW: 30_000, at: 3))
        await Task.yield()

        XCTAssertEqual(engine.snapshot?.activePowerMW, 30_000)
        XCTAssertEqual(engine.history.map(\.systemPowerIn), [20_000, 30_000])
        XCTAssertEqual(telemetry.startCount, 1)

        engine.start()
        XCTAssertEqual(telemetry.startCount, 1)
        engine.stop()
        XCTAssertEqual(telemetry.stopCount, 1)
    }

    func testOnBatteryHistoryUsesDischargePower() async {
        let telemetry = StubPowerTelemetrySource()
        let engine = PowerTelemetryEngine(
            telemetry: telemetry,
            diagnostics: StubPortDiagnosticsSource()
        )
        engine.start()

        telemetry.yield(PowerMonitorSnapshot(
            timestamp: Date(),
            systemSample: PowerSample(
                timestamp: Date(),
                systemVoltageIn: 0,
                systemCurrentIn: 0,
                systemPowerIn: 0
            ),
            portSamples: [],
            resistanceEstimate: nil,
            externalConnected: false,
            batteryInstalled: true,
            batteryVoltageMV: 12_000,
            batteryCurrentMA: 2_000,
            batteryPowerMW: 24_000
        ))
        await Task.yield()

        XCTAssertEqual(engine.history.last?.systemPowerIn, 24_000)
    }

    func testForwardsPortsAndContracts() async {
        let telemetry = StubPowerTelemetrySource()
        let diagnostics = StubPortDiagnosticsSource()
        let engine = PowerTelemetryEngine(telemetry: telemetry, diagnostics: diagnostics)
        let port = makePort()

        engine.updatePorts([port])
        engine.start()
        let contract = PDContract(
            activeRdo: 1 << 28,
            pdoList: [.fixed(voltage: 20_000, maxCurrent: 5_000)],
            pdoCount: 1,
            maxPower: 100_000,
            capMismatch: false,
            srcTypes: 0
        )
        diagnostics.yield(.init(
            timestamp: Date(),
            healthCounters: [:],
            contracts: ["2/1": contract],
            eventTraces: [:]
        ))
        await Task.yield()

        XCTAssertEqual(telemetry.updatedPorts.first?.portKey, "2/1")
        XCTAssertEqual(engine.contracts["2/1"], contract)
    }

    func testLifecycleReferenceCountsDistinctSurfaces() {
        let telemetry = StubPowerTelemetrySource()
        let engine = PowerTelemetryEngine(
            telemetry: telemetry,
            diagnostics: StubPortDiagnosticsSource()
        )
        let lifecycle = PowerTelemetryLifecycle()
        lifecycle.attach(engine)

        lifecycle.surfaceDidAppear("main")
        lifecycle.surfaceDidAppear("detached")
        lifecycle.surfaceDidAppear("detached")
        XCTAssertEqual(telemetry.startCount, 1)

        lifecycle.surfaceDidDisappear("main")
        XCTAssertTrue(engine.isRunning)
        lifecycle.surfaceDidDisappear("detached")
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(telemetry.stopCount, 1)
    }

    private func snapshot(powerMW: Int, at seconds: TimeInterval) -> PowerMonitorSnapshot {
        let date = Date(timeIntervalSince1970: seconds)
        return PowerMonitorSnapshot(
            timestamp: date,
            systemSample: PowerSample(
                timestamp: date,
                systemVoltageIn: 20_000,
                systemCurrentIn: powerMW / 20,
                systemPowerIn: powerMW
            ),
            portSamples: [],
            resistanceEstimate: nil
        )
    }

    private func makePort() -> AppleHPMInterface {
        AppleHPMInterface(
            id: 1,
            serviceName: "Port-USB-C@1",
            className: "AppleHPMInterfaceType10",
            portDescription: "Left USB-C",
            portTypeDescription: "USB-C",
            portNumber: 1,
            connectionActive: true,
            activeCable: nil,
            opticalCable: nil,
            usbActive: nil,
            superSpeedActive: nil,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: [],
            transportsActive: [],
            transportsProvisioned: [],
            plugOrientation: nil,
            plugEventCount: nil,
            connectionCount: nil,
            overcurrentCount: nil,
            pinConfiguration: [:],
            powerCurrentLimits: [],
            firmwareVersion: nil,
            bootFlagsHex: nil,
            rawProperties: [:]
        )
    }
}

@MainActor
private final class StubPowerTelemetrySource: PowerTelemetrySource {
    let snapshots: AsyncStream<PowerMonitorSnapshot>
    private let continuation: AsyncStream<PowerMonitorSnapshot>.Continuation
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var updatedPorts: [AppleHPMInterface] = []

    init() {
        let pair = AsyncStream<PowerMonitorSnapshot>.makeStream()
        snapshots = pair.stream
        continuation = pair.continuation
    }

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func updatePorts(_ ports: [AppleHPMInterface]) { updatedPorts = ports }
    func resetResistanceBaseline() {}
    func yield(_ snapshot: PowerMonitorSnapshot) { continuation.yield(snapshot) }
}

@MainActor
private final class StubPortDiagnosticsSource: PortDiagnosticsSource {
    let snapshots: AsyncStream<PortDiagnosticsWatcher.PortDiagnosticsSnapshot>
    private let continuation: AsyncStream<PortDiagnosticsWatcher.PortDiagnosticsSnapshot>.Continuation

    init() {
        let pair = AsyncStream<PortDiagnosticsWatcher.PortDiagnosticsSnapshot>.makeStream()
        snapshots = pair.stream
        continuation = pair.continuation
    }

    func start() {}
    func stop() {}
    func yield(_ snapshot: PortDiagnosticsWatcher.PortDiagnosticsSnapshot) {
        continuation.yield(snapshot)
    }
}
