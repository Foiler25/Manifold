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
// CableHistoryRecorderTests.swift

import XCTest
import GRDB
@testable import Manifold

@MainActor
final class CableHistoryRecorderTests: XCTestCase {
    func testIdenticalSnapshotCadenceAdvancesSustainedFaultThreshold() async throws {
        let snapshot = Self.snapshot(identity: Self.identity(productID: 0x1001))
        let cableEngine = CableEngine(provider: StubCableProvider(
            snapshots: [snapshot], trailingError: nil
        ))
        let power = Self.powerEngine()
        let recorder = CableHistoryRecorder(
            repository: nil,
            observationInterval: .milliseconds(15),
            dataDeliveryOverride: .belowClaim
        )

        cableEngine.start()
        try await waitUntil { cableEngine.snapshot != nil }
        recorder.start(cableEngine: cableEngine, powerEngine: power.engine)
        recorder.surfaceDidAppear("test")

        try await waitUntil {
            recorder.portStates["2/1"]?.verdict == .notPerforming
        }

        XCTAssertEqual(recorder.portStates["2/1"]?.verdict, .notPerforming)
        recorder.stopForTermination()
        cableEngine.stop()
    }

    func testFingerprintChangeResetsResistanceBaselineExactlyOnce() async throws {
        let first = Self.snapshot(identity: Self.identity(productID: 0x1001))
        let second = Self.snapshot(identity: Self.identity(productID: 0x1002))
        let provider = DelayedCableProvider(first: first, second: second)
        let cableEngine = CableEngine(provider: provider)
        let power = Self.powerEngine()
        let recorder = CableHistoryRecorder(
            repository: nil,
            observationInterval: .milliseconds(10)
        )

        cableEngine.start()
        recorder.start(cableEngine: cableEngine, powerEngine: power.engine)
        recorder.surfaceDidAppear("test")

        try await waitUntil { power.telemetry.resetCount == 1 }
        XCTAssertEqual(power.telemetry.resetCount, 1)
        XCTAssertTrue(recorder.portStates["2/1"]?.fingerprint.contains("1002") == true)

        recorder.stopForTermination()
        cableEngine.stop()
    }

    func testMultipleSurfacesCannotDoubleOpenOnePortSession() async throws {
        let storage = try StorageFixture()
        defer { storage.remove() }
        let cableEngine = CableEngine(provider: StubCableProvider(
            snapshots: [Self.snapshot(identity: Self.identity())], trailingError: nil
        ))
        let power = Self.powerEngine()
        let recorder = CableHistoryRecorder(
            repository: storage.repository,
            observationInterval: .milliseconds(10)
        )

        cableEngine.start()
        try await waitUntil { cableEngine.snapshot != nil }
        recorder.start(cableEngine: cableEngine, powerEngine: power.engine)
        recorder.surfaceDidAppear("main")
        recorder.surfaceDidAppear("detached")
        try await waitUntil { recorder.activeSessionCount == 1 }

        let fingerprint = try XCTUnwrap(recorder.portStates["2/1"]?.fingerprint)
        let sessions = try await storage.repository.sessions(cableID: fingerprint)
        XCTAssertEqual(sessions.count, 1)

        recorder.stopForTermination()
        cableEngine.stop()
    }

    func testImmediateCloseReopenKeepsOneLiveSession() async throws {
        let storage = try StorageFixture()
        defer { storage.remove() }
        let cableEngine = CableEngine(provider: StubCableProvider(
            snapshots: [Self.snapshot(identity: Self.identity())], trailingError: nil
        ))
        let power = Self.powerEngine()
        let recorder = CableHistoryRecorder(
            repository: storage.repository,
            observationInterval: .milliseconds(10)
        )

        cableEngine.start()
        try await waitUntil { cableEngine.snapshot != nil }
        recorder.start(cableEngine: cableEngine, powerEngine: power.engine)
        recorder.surfaceDidAppear("main")
        try await waitUntil { recorder.activeSessionCount == 1 }

        recorder.surfaceDidDisappear("main")
        recorder.surfaceDidAppear("detached")
        try await Task.sleep(for: .milliseconds(80))

        let fingerprint = try XCTUnwrap(recorder.portStates["2/1"]?.fingerprint)
        let sessions = try await storage.repository.sessions(cableID: fingerprint)
        XCTAssertEqual(recorder.activeSessionCount, 1)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertNil(sessions.first?.endedAt)

        recorder.stopForTermination()
        cableEngine.stop()
    }

    func testCloseFailureKeepsSessionForRetryAndSurfacesError() async throws {
        let storage = try StorageFixture()
        defer { storage.remove() }
        let cableEngine = CableEngine(provider: StubCableProvider(
            snapshots: [Self.snapshot(identity: Self.identity())], trailingError: nil
        ))
        let power = Self.powerEngine()
        let recorder = CableHistoryRecorder(
            repository: storage.repository,
            observationInterval: .milliseconds(10)
        )

        cableEngine.start()
        try await waitUntil { cableEngine.snapshot != nil }
        recorder.start(cableEngine: cableEngine, powerEngine: power.engine)
        recorder.surfaceDidAppear("test")
        try await waitUntil { recorder.activeSessionCount == 1 }
        try storage.manager.dbPool.close()

        recorder.surfaceDidDisappear("test")
        try await waitUntil { recorder.lastError != nil }

        XCTAssertEqual(recorder.activeSessionCount, 1)
        XCTAssertNotNil(recorder.lastError)
        cableEngine.stop()
    }

    func testTerminationClosesRowsBeforeReturning() async throws {
        let storage = try StorageFixture()
        defer { storage.remove() }
        let cableEngine = CableEngine(provider: StubCableProvider(
            snapshots: [Self.snapshot(identity: Self.identity())], trailingError: nil
        ))
        let power = Self.powerEngine()
        let recorder = CableHistoryRecorder(
            repository: storage.repository,
            observationInterval: .milliseconds(10)
        )

        cableEngine.start()
        try await waitUntil { cableEngine.snapshot != nil }
        recorder.start(cableEngine: cableEngine, powerEngine: power.engine)
        recorder.surfaceDidAppear("test")
        try await waitUntil { recorder.activeSessionCount == 1 }
        let fingerprint = try XCTUnwrap(recorder.portStates["2/1"]?.fingerprint)
        let end = Date(timeIntervalSince1970: 1_234)

        recorder.stopForTermination(at: end)

        let sessions = try await storage.repository.sessions(cableID: fingerprint)
        XCTAssertEqual(sessions.first?.endedAt, end)
        XCTAssertEqual(recorder.activeSessionCount, 0)
        cableEngine.stop()
    }

    private static func snapshot(identity: USBPDSOP) -> CableSnapshot {
        CableSnapshot(
            ports: [port()], powerSources: [], identities: [identity],
            usbDevices: [], adapter: nil
        )
    }

    private static func port() -> AppleHPMInterface {
        AppleHPMInterface(
            id: 1, serviceName: "Port-USB-C@1", className: "AppleHPMInterfaceType10",
            portDescription: "Left", portTypeDescription: "USB-C", portNumber: 1,
            connectionActive: true, activeCable: true, opticalCable: false,
            usbActive: true, superSpeedActive: true, usbModeType: nil,
            usbConnectString: nil, transportsSupported: ["USB3"],
            transportsActive: ["USB3"], transportsProvisioned: ["USB3"],
            plugOrientation: 1, plugEventCount: 1, connectionCount: 1,
            overcurrentCount: 0, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil, rawProperties: [:]
        )
    }

    private static func identity(productID: Int = 0x1001) -> USBPDSOP {
        USBPDSOP(
            id: UInt64(productID), endpoint: .sopPrime,
            parentPortType: 2, parentPortNumber: 1,
            vendorID: 0x1234, productID: productID, bcdDevice: 0x0100,
            vdos: [0, 0xAABB_CCDD, 0, 0x1122_3344], specRevision: 3
        )
    }

    private static func powerEngine() -> (
        engine: PowerTelemetryEngine,
        telemetry: RecorderPowerTelemetrySource
    ) {
        let telemetry = RecorderPowerTelemetrySource()
        return (
            PowerTelemetryEngine(
                telemetry: telemetry,
                diagnostics: RecorderPortDiagnosticsSource()
            ),
            telemetry
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while !condition() {
            if ContinuousClock.now - start >= timeout {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct DelayedCableProvider: CableSnapshotProvider {
    let first: CableSnapshot
    let second: CableSnapshot

    func snapshot() async throws -> CableSnapshot { first }

    func watch() -> AsyncThrowingStream<CableSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(first)
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                continuation.yield(second)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
private final class RecorderPowerTelemetrySource: PowerTelemetrySource {
    let snapshots = AsyncStream<PowerMonitorSnapshot> { _ in }
    private(set) var resetCount = 0

    func start() {}
    func stop() {}
    func updatePorts(_ ports: [AppleHPMInterface]) {}
    func resetResistanceBaseline() { resetCount += 1 }
}

@MainActor
private final class RecorderPortDiagnosticsSource: PortDiagnosticsSource {
    let snapshots = AsyncStream<PortDiagnosticsWatcher.PortDiagnosticsSnapshot> { _ in }
    func start() {}
    func stop() {}
}

@MainActor
private final class StorageFixture {
    let directory: URL
    let manager: DatabaseManager
    let repository: CableHistoryRepository

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("manifold-recorder-\(UUID().uuidString)")
        manager = try DatabaseManager(directory: directory)
        repository = CableHistoryRepository(dbPool: manager.dbPool)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
