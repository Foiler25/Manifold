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
// CableSummaryFixtures.swift
//
// Captured snapshots used by `CableEngineTests`. Two fixtures: an
// empty snapshot (Intel-Mac / no-ports state) and a populated one
// with a single connected USB-C port. We deliberately keep these
// minimal — the engine's job is moving snapshots through the actor
// boundary, not interpreting them. Per-port semantics are exercised
// by upstream's own tests.

import Foundation
@testable import Manifold

enum CableSummaryFixtures {

    static let empty = CableSnapshot(
        ports: [],
        powerSources: [],
        identities: [],
        usbDevices: [],
        adapter: nil,
        thunderboltSwitches: []
    )

    /// Single bare USB-C port. Realistic-enough that
    /// `Equatable` doesn't trivially equate it with `empty`.
    static let oneEmptyPort = CableSnapshot(
        ports: [
            AppleHPMInterface(
                id: 1,
                serviceName: "Port-USB-C@1",
                className: "AppleHPMInterfaceType10",
                portDescription: "Port-USB-C@1",
                portTypeDescription: "USB-C",
                portNumber: 1,
                connectionActive: false,
                activeCable: nil,
                opticalCable: nil,
                usbActive: nil,
                superSpeedActive: nil,
                usbModeType: nil,
                usbConnectString: nil,
                transportsSupported: ["CC"],
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
                busIndex: nil,
                rawProperties: [:]
            )
        ],
        powerSources: [],
        identities: [],
        usbDevices: [],
        adapter: nil,
        thunderboltSwitches: []
    )
}

/// Programmable provider used by the engine tests. Yields a
/// pre-canned sequence of snapshots and optionally an error.
struct StubCableProvider: CableSnapshotProvider {

    /// Snapshots to yield in order.
    let snapshots: [CableSnapshot]

    /// Optional error to throw after all snapshots are emitted.
    let trailingError: Error?

    func snapshot() async throws -> CableSnapshot {
        snapshots.first ?? CableSummaryFixtures.empty
    }

    func watch() -> AsyncThrowingStream<CableSnapshot, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for snap in snapshots {
                    continuation.yield(snap)
                    // Cooperative yield so the consumer task gets a
                    // chance to drain between emissions.
                    await Task.yield()
                }
                if let trailingError {
                    continuation.finish(throwing: trailingError)
                } else {
                    continuation.finish()
                }
            }
        }
    }
}

struct StubCableProviderError: Error, Equatable {
    let reason: String
}
