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
// CableHistoryRecorder.swift

import Foundation

struct CableHistoryLiveState {
    let fingerprint: String
    let verdict: SessionMonitor.Verdict
    let trust: CableTrust
    let connectionDiagnostic: ConnectionDiagnostic?
    let savedCable: SavedCable?
}

@MainActor
@Observable
final class CableHistoryRecorder {
    private(set) var portStates: [String: CableHistoryLiveState] = [:]

    private struct ActiveSession {
        let fingerprint: String
        let portKey: String
        let startedAt: Date
        let baseline: ConnectionCounters
        var latestCounters: ConnectionCounters
        var monitor: SessionMonitor
        var rowID: Int64?
        var negotiatedGbps: Double?
        var negotiatedWatts: Int?
        var savedCable: SavedCable?
    }

    private var repository: CableHistoryRepository?
    private var sessions: [String: ActiveSession] = [:]
    private var observationTask: Task<Void, Never>?
    private weak var cableEngine: CableEngine?
    private weak var powerEngine: PowerTelemetryEngine?
    private var visibleSurfaces: Set<String> = []

    init(repository: CableHistoryRepository?) {
        self.repository = repository
    }

    func attachRepository(_ repository: CableHistoryRepository) {
        self.repository = repository
    }

    func start(cableEngine: CableEngine, powerEngine: PowerTelemetryEngine) {
        guard observationTask == nil else { return }
        self.cableEngine = cableEngine
        self.powerEngine = powerEngine
        observationTask = Task { @MainActor [weak self, weak cableEngine, weak powerEngine] in
            while !Task.isCancelled {
                guard let self, let cableEngine, let powerEngine else { return }
                if !self.visibleSurfaces.isEmpty {
                    await self.process(
                        snapshot: cableEngine.snapshot,
                        powerSnapshot: powerEngine.snapshot
                    )
                }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = cableEngine.snapshot
                        _ = powerEngine.snapshot
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    func surfaceDidAppear(_ id: String) {
        visibleSurfaces.insert(id)
        guard let cableEngine, let powerEngine else { return }
        Task { @MainActor [weak self] in
            await self?.process(
                snapshot: cableEngine.snapshot,
                powerSnapshot: powerEngine.snapshot
            )
        }
    }

    func surfaceDidDisappear(_ id: String) {
        visibleSurfaces.remove(id)
        if visibleSurfaces.isEmpty {
            Task { @MainActor [weak self] in
                await self?.closeAll(at: .now)
            }
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        visibleSurfaces.removeAll()
        Task { @MainActor [weak self] in
            await self?.closeAll(at: .now)
        }
    }

    func saveCable(portKey: String, nickname: String) async throws {
        guard let repository,
              let state = portStates[portKey] else { return }
        try await repository.rename(id: state.fingerprint, nickname: nickname)
        let saved = try await repository.cable(id: state.fingerprint)
        guard let saved else { return }
        if var session = sessions[portKey] {
            session.savedCable = saved
            sessions[portKey] = session
        }
        portStates[portKey] = CableHistoryLiveState(
            fingerprint: state.fingerprint,
            verdict: state.verdict,
            trust: state.trust,
            connectionDiagnostic: state.connectionDiagnostic,
            savedCable: saved
        )
    }

    private func process(
        snapshot: CableSnapshot?,
        powerSnapshot: PowerMonitorSnapshot?
    ) async {
        guard let snapshot else { return }
        let activePorts = snapshot.ports.filter { $0.connectionActive == true }
        let activeKeys = Set(activePorts.compactMap(\.portKey))

        for key in sessions.keys where !activeKeys.contains(key) {
            await closeSession(portKey: key, endedAt: .now)
            portStates.removeValue(forKey: key)
        }

        let diagnostics = NegotiationDiagnosticsModel(snapshot: snapshot).diagnosticsByPortKey
        let resistancePort = powerSnapshot.map {
            SessionMonitor.resistanceAttributedPortKey(in: $0.portSamples)
        } ?? nil

        for port in activePorts {
            guard let portKey = port.portKey else { continue }
            let identities = snapshot.identities.filter { $0.canonicallyMatches(port: port) }
            guard let identity = identities.first(where: {
                $0.endpoint == .sopPrime || $0.endpoint == .sopDoublePrime
            }), let fingerprint = CableIdentity.key(for: identity) else {
                if sessions[portKey] != nil {
                    await closeSession(portKey: portKey, endedAt: .now)
                }
                portStates.removeValue(forKey: portKey)
                continue
            }

            if sessions[portKey]?.fingerprint != fingerprint {
                if sessions[portKey] != nil {
                    await closeSession(portKey: portKey, endedAt: .now)
                }
                sessions[portKey] = await openSession(
                    fingerprint: fingerprint,
                    identity: identity,
                    port: port
                )
            }
            guard var session = sessions[portKey] else { continue }

            let diagnostic = diagnostics[portKey]
            let dataDelivery = SessionMonitor.DataDelivery.from(
                diagnostic?.bottleneck,
                hasCableSpeedClaim: diagnostic?.facts.cableGbps != nil
            )
            let ratedFiveA = identity.cableVDO?.current == .fiveAmp
            let resistanceTier = resistancePort == portKey
                ? powerSnapshot?.resistanceEstimate?.tier(ratedFiveA: ratedFiveA)
                : nil
            session.monitor.record(.init(
                fingerprint: "\(portKey):\(fingerprint)",
                dataDelivery: dataDelivery,
                resistanceTier: resistanceTier,
                overcurrentCount: port.overcurrentCount
            ))
            session.latestCounters = ConnectionCounters(port: port)
            session.negotiatedGbps = diagnostic?.facts.activeGbps
            let sources = snapshot.powerSources.filter { $0.canonicallyMatches(port: port) }
            session.negotiatedWatts = PowerSource.preferredChargingSource(in: sources)?.winning.map {
                Int((Double($0.maxPowerMW) / 1000).rounded())
            }

            let delta = SessionDelta(
                baseline: session.baseline,
                current: session.latestCounters
            )
            let connectionDiagnostic = ConnectionDiagnostic(
                delta: delta,
                elapsedSeconds: Date.now.timeIntervalSince(session.startedAt)
            )
            let partner = identities.first(where: { $0.endpoint == .sop })
            let trust = CableTrust(
                report: CableTrustReport(identity: identity, partner: partner),
                vendorRegistered: CableDB.isUSBIFRegistered(identity.vendorID),
                dataLink: diagnostic,
                negotiatedWatts: session.negotiatedWatts,
                ratedWatts: identity.cableVDO?.maxWatts,
                sessionVerdict: session.monitor.verdict
            )
            sessions[portKey] = session
            portStates[portKey] = CableHistoryLiveState(
                fingerprint: fingerprint,
                verdict: session.monitor.verdict,
                trust: trust,
                connectionDiagnostic: connectionDiagnostic,
                savedCable: session.savedCable
            )
        }
    }

    private func openSession(
        fingerprint: String,
        identity: USBPDSOP,
        port: AppleHPMInterface
    ) async -> ActiveSession {
        let now = Date.now
        var rowID: Int64?
        var saved: SavedCable?
        if let repository, let portKey = port.portKey {
            do {
                let curated = CableDB.curatedCables(
                    vid: identity.vendorID,
                    pid: identity.productID
                ).first
                try await repository.upsertSavedCable(
                    id: fingerprint,
                    vendorID: identity.vendorID,
                    productID: identity.productID,
                    vendorName: CableDB.vendorName(vid: identity.vendorID),
                    curatedBrand: curated?.brand,
                    cableVDO: CableIdentity.cableVDORaw(for: identity),
                    seenAt: now
                )
                saved = try await repository.cable(id: fingerprint)
                rowID = try await repository.openSession(
                    cableID: fingerprint,
                    portKey: portKey,
                    startedAt: now
                )
            } catch {
                rowID = nil
            }
        }
        return ActiveSession(
            fingerprint: fingerprint,
            portKey: port.portKey ?? "unknown",
            startedAt: now,
            baseline: ConnectionCounters(port: port),
            latestCounters: ConnectionCounters(port: port),
            monitor: SessionMonitor(),
            rowID: rowID,
            negotiatedGbps: nil,
            negotiatedWatts: nil,
            savedCable: saved
        )
    }

    private func closeSession(portKey: String, endedAt: Date) async {
        guard let session = sessions.removeValue(forKey: portKey) else { return }
        guard let repository, let rowID = session.rowID else { return }
        let delta = SessionDelta(
            baseline: session.baseline,
            current: session.latestCounters
        )
        try? await repository.closeSession(
            id: rowID,
            endedAt: endedAt,
            verdict: session.monitor.verdict,
            negotiatedGbps: session.negotiatedGbps,
            negotiatedWatts: session.negotiatedWatts,
            observationCount: session.monitor.observationCount,
            overcurrentEvents: session.monitor.overcurrentEventCount,
            plugEvents: delta.plugEvents
        )
    }

    private func closeAll(at date: Date) async {
        for key in sessions.keys {
            await closeSession(portKey: key, endedAt: date)
        }
        portStates.removeAll()
    }
}
