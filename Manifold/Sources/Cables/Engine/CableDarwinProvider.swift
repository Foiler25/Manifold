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
// Portions of this file derive from WhatCable
// (https://github.com/darrylmorley/whatcable) by Darryl Morley,
// originally distributed under the MIT licence. See
// `Manifold/Sources/Cables/ATTRIBUTION.md` for the full original
// copyright + permission notice.
//
// ─────────────────────────────────────────────────────────────────────
public import Foundation
import Combine
import os.log

/// macOS implementation of `CableSnapshotProvider`. Wraps the four IOKit
/// watcher classes and assembles their state into a `CableSnapshot`.
///
/// The provider is event-driven for registry and property changes. A single
/// scoped 1 Hz maintenance tick remains while a stream is attached for three
/// values that do not have dependable notifications on all supported macOS
/// versions: in-place TRM state, liquid state, and the CoreGraphics live mode.
public final class CableDarwinProvider: CableSnapshotProvider, @unchecked Sendable {
    public init() {}

    private static let log = Logger(subsystem: "uk.whatcable.whatcable", category: "charging")

    @MainActor
    private final class State {
        let portWatcher = AppleHPMInterfaceWatcher()
        let powerWatcher = PowerSourceWatcher()
        let pdWatcher = USBPDSOPWatcher()
        let usbWatcher = USBWatcher()
        let tbWatcher = IOIOThunderboltSwitchWatcher()
        let usb3Watcher = USB3TransportWatcher()
        let trmWatcher = TRMTransportWatcher()
        let phyWatcher = AppleTypeCPhyWatcher()
        let displayWatcher = DisplayPortTransportWatcher()
        let liquidWatcher = LiquidDetectionWatcher()
        var started = false
        var streamToken: UUID?
        var continuation: AsyncThrowingStream<CableSnapshot, Error>.Continuation?
        var lastSnapshot: CableSnapshot?
        var cancellables = Set<AnyCancellable>()
        var coalesceTask: Task<Void, Never>?
        var maintenanceTask: Task<Void, Never>?
        var powerReconcileTask: Task<Void, Never>?

        var hasStream: Bool { streamToken != nil }

        func ensureStarted() {
            guard !started else { return }
            started = true

            // Install dependency context before start() drains matching
            // iterators, otherwise the first power-source synthesis pass can
            // miss an already-connected cable.
            powerWatcher.synthesisContext = { [weak self] in
                guard let self else { return nil }
                return PowerSourceSynthesisContext(
                    ports: self.portWatcher.ports,
                    identities: self.pdWatcher.identities,
                    positionalPortKeys: { PowerTelemetryWatcher.hpmPortKeys() }
                )
            }
            installEventSubscriptions()

            portWatcher.start()
            powerWatcher.start()
            pdWatcher.start()
            usbWatcher.start()
            tbWatcher.start()
            usb3Watcher.start()
            trmWatcher.start()
            phyWatcher.start()
            displayWatcher.start()
            liquidWatcher.start()
            refreshAllOnce()
        }

        private func refreshAllOnce() {
            portWatcher.refresh()
            pdWatcher.refresh()
            powerWatcher.refresh()
            tbWatcher.refresh()
            usb3Watcher.refresh()
            trmWatcher.refresh()
            phyWatcher.refresh()
            displayWatcher.refresh()
            liquidWatcher.refresh()
        }

        func read() -> CableSnapshot {
            let battery = AppleSmartBatteryReader.read()
            var liquidDetection: [String: LiquidDetectionStatus] = [:]
            for update in liquidWatcher.statuses {
                guard let port = portWatcher.ports.first(where: {
                    $0.portNumber == update.portIndex
                        && ($0.portTypeDescription == update.portType
                            || update.portType == "USB-C")
                }), let key = port.portKey else {
                    continue
                }
                liquidDetection[key] = update.status
            }
            let snap = CableSnapshot(
                ports: portWatcher.ports,
                powerSources: powerWatcher.sources,
                identities: pdWatcher.identities,
                usbDevices: usbWatcher.devices,
                adapter: SystemPower.currentAdapter(),
                thunderboltSwitches: tbWatcher.switches,
                isDesktopMac: battery.isDesktopMac,
                federatedIdentities: battery.federatedIdentities,
                usb3Transports: usb3Watcher.transports,
                trmTransports: trmWatcher.transports,
                cioCapabilities: trmWatcher.cioCapabilities,
                typeCPhys: phyWatcher.phys,
                // statuses are enriched with the live CoreGraphics mode at the
                // watcher source now (DAR-159), so no enrich is needed here.
                displayPorts: displayWatcher.statuses.map(\.status),
                liquidDetection: liquidDetection,
                batteryFullyCharged: battery.battery?.fullyCharged,
                batteryIsCharging: battery.battery?.isCharging
            )
            return snap
        }

        func attach(
            token: UUID,
            continuation: AsyncThrowingStream<CableSnapshot, Error>.Continuation
        ) {
            ensureStarted()
            streamToken = token
            self.continuation = continuation
            lastSnapshot = nil
            emitIfChanged()
            startMaintenance()
        }

        func detach(token: UUID) {
            guard streamToken == token else { return }
            stopAll()
        }

        func stopAll() {
            coalesceTask?.cancel()
            coalesceTask = nil
            maintenanceTask?.cancel()
            maintenanceTask = nil
            powerReconcileTask?.cancel()
            powerReconcileTask = nil
            cancellables.removeAll()
            continuation = nil
            streamToken = nil
            lastSnapshot = nil

            // Every watcher owns IOKit iterators, notification ports, and in
            // several cases per-service interest handles. All ten must stop
            // when the last CableEngine stream terminates.
            portWatcher.stop()
            powerWatcher.stop()
            pdWatcher.stop()
            usbWatcher.stop()
            tbWatcher.stop()
            usb3Watcher.stop()
            trmWatcher.stop()
            phyWatcher.stop()
            displayWatcher.stop()
            liquidWatcher.stop()
            powerWatcher.synthesisContext = nil
            started = false
        }

        private func installEventSubscriptions() {
            portWatcher.$ports.dropFirst().sink { [weak self] _ in
                self?.schedulePowerReconcile()
            }.store(in: &cancellables)
            pdWatcher.$identities.dropFirst().sink { [weak self] _ in
                self?.schedulePowerReconcile()
            }.store(in: &cancellables)

            powerWatcher.$sources.dropFirst().sink { [weak self] _ in
                self?.scheduleEmit()
            }.store(in: &cancellables)
            usbWatcher.$devices.dropFirst().sink { [weak self] _ in
                self?.scheduleEmit()
            }.store(in: &cancellables)
            tbWatcher.$switches.dropFirst().sink { [weak self] _ in
                self?.scheduleEmit()
            }.store(in: &cancellables)
            usb3Watcher.$transports.dropFirst().sink { [weak self] _ in
                self?.scheduleEmit()
            }.store(in: &cancellables)
            trmWatcher.$transports.dropFirst().sink { [weak self] _ in
                self?.scheduleEmit()
            }.store(in: &cancellables)
            trmWatcher.$cioCapabilities.dropFirst().sink { [weak self] _ in
                self?.scheduleEmit()
            }.store(in: &cancellables)
            phyWatcher.$phys.dropFirst().sink { [weak self] _ in
                self?.scheduleEmit()
            }.store(in: &cancellables)
            displayWatcher.$statuses.dropFirst().sink { [weak self] _ in
                self?.scheduleEmit()
            }.store(in: &cancellables)
            liquidWatcher.$statuses.dropFirst().sink { [weak self] _ in
                self?.scheduleEmit()
            }.store(in: &cancellables)
        }

        private func schedulePowerReconcile() {
            powerReconcileTask?.cancel()
            powerReconcileTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(75))
                guard !Task.isCancelled, let self else { return }
                self.powerWatcher.refresh()
                self.scheduleEmit()
            }
        }

        private func scheduleEmit() {
            guard continuation != nil else { return }
            coalesceTask?.cancel()
            coalesceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                self?.emitIfChanged()
            }
        }

        private func emitIfChanged() {
            guard let continuation else { return }
            let snapshot = read()
            guard snapshot != lastSnapshot else { return }
            lastSnapshot = snapshot
            CableDarwinProvider.logChargingSignals(snapshot)
            continuation.yield(snapshot)
        }

        private func startMaintenance() {
            maintenanceTask?.cancel()
            maintenanceTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) }
                    catch { break }
                    guard !Task.isCancelled, let self else { return }
                    // These services can mutate properties without matching a
                    // new registry node on some macOS generations. Restrict the
                    // fallback poll to those three watchers; the other seven
                    // remain wholly notification-driven. read() also refreshes
                    // the adapter/battery scalar fields without another walk.
                    self.trmWatcher.refresh()
                    self.displayWatcher.refresh()
                    self.liquidWatcher.refresh()
                    self.emitIfChanged()
                }
            }
        }
    }

    @MainActor
    private static let state = State()

    @MainActor
    public func snapshot() async throws -> CableSnapshot {
        Self.state.ensureStarted()
        let snapshot = Self.state.read()
        Self.logChargingSignals(snapshot)
        // A one-shot caller must not leave process-lifetime notification
        // registrations behind. CableEngine's parallel watch() attachment
        // keeps them alive when a surface is actually consuming updates.
        if !Self.state.hasStream { Self.state.stopAll() }
        return snapshot
    }

    private static func logChargingSignals(_ snap: CableSnapshot) {
        let activePorts = snap.ports.filter { $0.connectionActive == true }
        let adapterW = snap.adapter?.watts.map(String.init) ?? "none"
        log.debug(
            """
            charging signals: \(snap.ports.count) ports, \
            \(activePorts.count) active, \
            adapter \(adapterW)W
            """
        )
        for port in activePorts {
            guard let key = port.portKey else { continue }
            let sources = snap.powerSources.filter { $0.portKey == key }
            let names = sources.map { src -> String in
                let w = Int((Double(src.maxPowerMW) / 1000).rounded())
                return "\(src.name)(\(w)W)"
            }
            let label = port.portDescription ?? port.serviceName
            log.debug("  port \(label): sources=[\(names.joined(separator: ", "))]")
        }
    }

    public func watch() -> AsyncThrowingStream<CableSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let token = UUID()
            let attachTask = Task { @MainActor in
                guard !Task.isCancelled else { return }
                Self.state.attach(token: token, continuation: continuation)
            }
            continuation.onTermination = { _ in
                attachTask.cancel()
                Task { @MainActor in Self.state.detach(token: token) }
            }
        }
    }

    @MainActor
    static var watchersRunningForTesting: Bool { state.started }
}

/// Default backend on Darwin platforms. CLI / GUI call this rather than
/// naming `CableDarwinProvider` directly.
public func makeDefaultSnapshotProvider() -> any CableSnapshotProvider {
    CableDarwinProvider()
}
