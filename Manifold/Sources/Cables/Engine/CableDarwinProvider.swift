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
import os.log

/// macOS implementation of `CableSnapshotProvider`. Wraps the four IOKit
/// watcher classes and assembles their state into a `CableSnapshot`.
///
/// `snapshot()` starts the watchers once, refreshes the polling-driven ones
/// (the others fire IOKit match notifications during start), and reads.
/// `watch()` keeps them started and polls for changes on a 1s timer.
/// Polling is sufficient because `AppleHPMInterfaceWatcher` already requires it for
/// property-change events; the others share the same loop for simplicity.
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

        func ensureStarted() {
            guard !started else { return }
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

            // Lets powerWatcher.refresh() synthesize a per-port source when
            // macOS never publishes a real IOPortFeaturePowerSource node
            // (M1 Pro/Max/Ultra USB-C, issue #401).
            powerWatcher.synthesisContext = { [weak self] in
                guard let self else { return nil }
                return PowerSourceSynthesisContext(
                    ports: self.portWatcher.ports,
                    identities: self.pdWatcher.identities,
                    // hpmPortKeys() walks six IOKit service classes; wrapped
                    // in a closure so it only runs on the rare tick that
                    // reaches the actual synthesis call, not on every read().
                    positionalPortKeys: { PowerTelemetryWatcher.hpmPortKeys() }
                )
            }

            started = true
        }

        func read() -> CableSnapshot {
            // AppleHPMInterface property changes don't fire match notifications,
            // so refresh on every read. The others are notification-driven
            // but refresh is cheap and keeps reads consistent.
            portWatcher.refresh()
            // pdWatcher before powerWatcher: PowerSourceSynthesis's
            // partner-kind attribution rung (issue #401) needs this tick's
            // identities, not last tick's.
            pdWatcher.refresh()
            powerWatcher.refresh()
            tbWatcher.refresh()
            usb3Watcher.refresh()
            trmWatcher.refresh()
            phyWatcher.refresh()
            displayWatcher.refresh()
            liquidWatcher.refresh()
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
            CableDarwinProvider.logChargingSignals(snap)
            return snap
        }
    }

    @MainActor
    private static let state = State()

    @MainActor
    public func snapshot() async throws -> CableSnapshot {
        Self.state.ensureStarted()
        return Self.state.read()
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
            let task = Task { @MainActor in
                Self.state.ensureStarted()
                var last: CableSnapshot? = nil
                while !Task.isCancelled {
                    let snap = Self.state.read()
                    if last != snap {
                        continuation.yield(snap)
                        last = snap
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

/// Default backend on Darwin platforms. CLI / GUI call this rather than
/// naming `CableDarwinProvider` directly.
public func makeDefaultSnapshotProvider() -> any CableSnapshotProvider {
    CableDarwinProvider()
}
