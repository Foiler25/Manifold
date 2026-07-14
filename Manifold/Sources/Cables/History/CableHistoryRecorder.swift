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

enum CableHistoryRecorderError: LocalizedError {
    case persistenceUnavailable
    case portNotActive
    case savedCableMissing

    var errorDescription: String? {
        switch self {
        case .persistenceUnavailable:
            "Cable history storage is unavailable."
        case .portNotActive:
            "The cable is no longer connected to that port."
        case .savedCableMissing:
            "The cable was saved, but its record could not be reloaded."
        }
    }
}

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
    private(set) var lastError: Error?
    var activeSessionCount: Int { sessions.count }

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
    private var cadenceTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private weak var cableEngine: CableEngine?
    private weak var powerEngine: PowerTelemetryEngine?
    private var visibleSurfaces: Set<String> = []
    private let observationInterval: Duration
    private let dataDeliveryOverride: SessionMonitor.DataDelivery?

    init(
        repository: CableHistoryRepository?,
        observationInterval: Duration = .seconds(1),
        dataDeliveryOverride: SessionMonitor.DataDelivery? = nil
    ) {
        self.repository = repository
        self.observationInterval = observationInterval
        self.dataDeliveryOverride = dataDeliveryOverride
    }

    func attachRepository(_ repository: CableHistoryRepository) {
        self.repository = repository
    }

    func start(cableEngine: CableEngine, powerEngine: PowerTelemetryEngine) {
        self.cableEngine = cableEngine
        self.powerEngine = powerEngine
        if !visibleSurfaces.isEmpty { startCadenceIfNeeded() }
    }

    func surfaceDidAppear(_ id: String) {
        closeTask?.cancel()
        closeTask = nil
        visibleSurfaces.insert(id)
        startCadenceIfNeeded()
    }

    func surfaceDidDisappear(_ id: String) {
        visibleSurfaces.remove(id)
        if visibleSurfaces.isEmpty {
            cadenceTask?.cancel()
            cadenceTask = nil
            closeTask = Task { @MainActor [weak self] in
                // Coalesce a close/reopen in the same UI transition. The
                // visibility recheck is load-bearing for detached windows.
                await Task.yield()
                guard let self, self.visibleSurfaces.isEmpty else { return }
                await self.closeAll(at: .now, whileHidden: true)
            }
        }
    }

    func stop() {
        cadenceTask?.cancel()
        cadenceTask = nil
        closeTask?.cancel()
        visibleSurfaces.removeAll()
        closeTask = Task { @MainActor [weak self] in
            await self?.closeAll(at: .now, whileHidden: false)
        }
    }

    /// NSApplication termination is synchronous. Finish all database writes
    /// before returning so the process cannot strand open session rows.
    func stopForTermination(at endedAt: Date = .now) {
        cadenceTask?.cancel()
        cadenceTask = nil
        closeTask?.cancel()
        closeTask = nil
        visibleSurfaces.removeAll()

        let closures = sessions.values.compactMap { closure(for: $0, endedAt: endedAt) }
        do {
            try repository?.closeSessionsSynchronously(closures)
            sessions.removeAll()
            portStates.removeAll()
            lastError = nil
        } catch {
            // Preserve the active state for diagnostics and for a retry if the
            // lifecycle invokes termination cleanup again.
            lastError = error
        }
    }

    func saveCable(portKey: String, nickname: String) async throws {
        guard let repository else {
            throw CableHistoryRecorderError.persistenceUnavailable
        }
        guard let state = portStates[portKey] else {
            throw CableHistoryRecorderError.portNotActive
        }
        try await repository.rename(id: state.fingerprint, nickname: nickname)
        let saved = try await repository.cable(id: state.fingerprint)
        guard let saved else { throw CableHistoryRecorderError.savedCableMissing }
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
        lastError = nil
    }

    private func startCadenceIfNeeded() {
        guard cadenceTask == nil,
              !visibleSurfaces.isEmpty,
              let cableEngine,
              let powerEngine else { return }
        cadenceTask = Task { @MainActor [weak self, weak cableEngine, weak powerEngine] in
            while !Task.isCancelled {
                guard let self, let cableEngine, let powerEngine,
                      !self.visibleSurfaces.isEmpty else { break }
                await self.process(
                    snapshot: cableEngine.snapshot,
                    powerSnapshot: powerEngine.snapshot
                )
                do {
                    try await Task.sleep(for: self.observationInterval)
                } catch {
                    break
                }
            }
            self?.cadenceTask = nil
        }
    }

    private func process(
        snapshot: CableSnapshot?,
        powerSnapshot: PowerMonitorSnapshot?
    ) async {
        guard let snapshot else { return }
        let activePorts = snapshot.ports.filter { $0.connectionActive == true }
        let activeKeys = Set(activePorts.compactMap(\.portKey))

        for key in Array(sessions.keys) where !activeKeys.contains(key) {
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

            let priorFingerprint = sessions[portKey]?.fingerprint
            if priorFingerprint != fingerprint {
                if priorFingerprint != nil {
                    let closed = await closeSession(portKey: portKey, endedAt: .now)
                    guard closed else { continue }
                    // RegressionAccumulator groups by PD contract. A new cable
                    // on the same charger must not inherit the old cable's
                    // resistance samples merely because the contract matches.
                    powerEngine?.resetResistanceBaseline()
                }
                do {
                    sessions[portKey] = try await openSession(
                        fingerprint: fingerprint,
                        identity: identity,
                        port: port
                    )
                    lastError = nil
                } catch {
                    lastError = error
                    continue
                }
            }
            guard var session = sessions[portKey] else { continue }

            let diagnostic = diagnostics[portKey]
            let dataDelivery = dataDeliveryOverride
                ?? SessionMonitor.DataDelivery.from(
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
    ) async throws -> ActiveSession {
        let now = Date.now
        var rowID: Int64?
        var saved: SavedCable?
        if let repository, let portKey = port.portKey {
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

    @discardableResult
    private func closeSession(portKey: String, endedAt: Date) async -> Bool {
        guard let session = sessions[portKey] else { return true }
        guard let repository, let rowID = session.rowID else {
            sessions.removeValue(forKey: portKey)
            return true
        }
        do {
            guard let closure = closure(for: session, endedAt: endedAt, rowID: rowID) else {
                return false
            }
            try await repository.closeSession(
                id: closure.id,
                endedAt: closure.endedAt,
                verdict: closure.verdict,
                negotiatedGbps: closure.negotiatedGbps,
                negotiatedWatts: closure.negotiatedWatts,
                observationCount: closure.observationCount,
                overcurrentEvents: closure.overcurrentEvents,
                plugEvents: closure.plugEvents
            )
            sessions.removeValue(forKey: portKey)
            lastError = nil
            return true
        } catch {
            // Keep the session and row ID so the next cadence/disconnect or
            // termination cleanup can retry the exact same close.
            lastError = error
            return false
        }
    }

    private func closeAll(at date: Date, whileHidden: Bool) async {
        for key in Array(sessions.keys) {
            if whileHidden, !visibleSurfaces.isEmpty { return }
            await closeSession(portKey: key, endedAt: date)
        }
        portStates.removeAll()
    }

    private func closure(
        for session: ActiveSession,
        endedAt: Date,
        rowID: Int64? = nil
    ) -> CableSessionClosure? {
        guard let id = rowID ?? session.rowID else { return nil }
        let delta = SessionDelta(
            baseline: session.baseline,
            current: session.latestCounters
        )
        return CableSessionClosure(
            id: id,
            endedAt: endedAt,
            verdict: session.monitor.verdict,
            negotiatedGbps: session.negotiatedGbps,
            negotiatedWatts: session.negotiatedWatts,
            observationCount: session.monitor.observationCount,
            overcurrentEvents: session.monitor.overcurrentEventCount,
            plugEvents: delta.plugEvents
        )
    }
}
