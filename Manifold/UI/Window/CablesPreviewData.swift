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
// ─────────────────────────────────────────────────────────────────────
// CablesPreviewData.swift
//
// Phase 21 — preview-only seeds for CablesView / CablePortCard /
// CablesEmptyState. Lives next to the views (rather than in a shared
// preview-data module) because the absorbed `CableSnapshot` /
// `USBCPort` types live in the main app target — keeping the seeds
// here avoids introducing a cross-target dependency just for previews.
//
// `PreviewCableProvider` is a tiny `CableSnapshotProvider` that emits
// a fixed list of snapshots when `watch()` is consumed. Used by the
// `CableEngine` previews.

#if DEBUG

import Foundation

/// Seed `CableSnapshot` values for the previews. Mirrors the shape of
/// `BatteryViewPreviewData` (next-to-the-view DEBUG-only seeds).
extension CableSnapshot {

    /// Snapshot with zero ports — drives the "Apple-Silicon-only"
    /// empty state.
    static let empty = CableSnapshot(
        ports: [],
        powerSources: [],
        identities: [],
        usbDevices: [],
        adapter: nil,
        thunderboltSwitches: []
    )

    /// One disconnected USB-C port — drives `CablePortCard`'s empty
    /// state and `CablesView`'s "no cables plugged in" hint.
    static let previewEmptyPort = CableSnapshot(
        ports: [
            USBCPort(
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

/// Programmable provider used only by SwiftUI previews. Yields the
/// pre-canned snapshots when `watch()` is consumed. The production
/// path uses `CableDarwinProvider`.
struct PreviewCableProvider: CableSnapshotProvider {

    let snapshots: [CableSnapshot]

    func snapshot() async throws -> CableSnapshot {
        snapshots.first ?? .empty
    }

    func watch() -> AsyncThrowingStream<CableSnapshot, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for snap in snapshots {
                    continuation.yield(snap)
                    await Task.yield()
                }
                continuation.finish()
            }
        }
    }
}

#endif
