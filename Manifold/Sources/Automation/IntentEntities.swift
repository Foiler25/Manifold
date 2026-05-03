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
// IntentEntities.swift
//
// Per SPEC §11.1. Three `AppEntity` types that the Phase 12 intents
// take + return: `DeviceEntity`, `DiagnosticEntity`, `HostEntity`.
// Each carries its model `Identifiable` ID + a `displayRepresentation`
// for the Shortcuts UI.
//
// `id` is `String` for every entity rather than the ManifoldKit
// wrapper type (`DeviceID` / `HostID` / `UUID`) — AppIntents requires
// `EntityIdentifierConvertible`, which `String` and `UUID` already
// conform to but `DeviceID`/`HostID` don't (and we don't want to
// pull AppIntents into ManifoldKit just for that). The wrapper
// types are recovered via `init(_ rawValue:)` at the consumer
// boundary — `entity.deviceID` returns the typed wrapper.
//
// `AppEntity.defaultQuery` exposes a `Query` that the Shortcuts
// editor uses to populate the picker for `@Parameter` slots — when
// the user opens GetPowerDrawIntent's "Filter by device" picker,
// `DeviceEntityQuery.entities(matching:)` runs to fill it. Queries
// hop through `IntentEnvironment.dataSource` for live data.

import Foundation
import AppIntents
import ManifoldKit

// MARK: - DeviceEntity

struct DeviceEntity: AppEntity, Identifiable {

    static let typeDisplayRepresentation: TypeDisplayRepresentation =
        TypeDisplayRepresentation(name: "Device")
    static let defaultQuery = DeviceEntityQuery()

    /// `String`-typed for AppIntents. `deviceID` recovers the typed
    /// wrapper for callers that need it.
    let id: String
    let name: String
    let vendorID: UInt16
    let productID: UInt16
    let kind: String
    let powerDrawWatts: Double?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "VID \(String(format: "%04x", vendorID)) PID \(String(format: "%04x", productID))"
        )
    }

    /// Typed accessor for non-Shortcuts consumers (mainly tests +
    /// the watcher-intent's matching logic).
    var deviceID: DeviceID { DeviceID(id) }

    /// Construct from a live `Device` + the port's `powerDraw`. The
    /// SPEC §11.1 sketch holds `powerDraw` on the entity directly;
    /// our model carries it on `Port`, so the caller sources the
    /// value at construction time.
    init(device: Device, powerDrawWatts: Double?) {
        self.id = device.id.rawValue
        self.name = device.name
        self.vendorID = device.vendorID
        self.productID = device.productID
        self.kind = device.kind.rawValue
        self.powerDrawWatts = powerDrawWatts
    }
}

// MARK: - DiagnosticEntity

struct DiagnosticEntity: AppEntity, Identifiable {

    static let typeDisplayRepresentation: TypeDisplayRepresentation =
        TypeDisplayRepresentation(name: "Diagnostic")
    static let defaultQuery = DiagnosticEntityQuery()

    let id: UUID
    let title: String
    let severity: String
    let detail: String
    let targetPortID: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(detail)")
    }

    init(diagnostic: Diagnostic) {
        self.id = diagnostic.id
        self.title = diagnostic.title
        self.severity = diagnostic.severity.rawValue
        self.detail = diagnostic.detail
        self.targetPortID = diagnostic.target.rawValue
    }
}

// MARK: - HostEntity

struct HostEntity: AppEntity, Identifiable {

    static let typeDisplayRepresentation: TypeDisplayRepresentation =
        TypeDisplayRepresentation(name: "Host")
    static let defaultQuery = HostEntityQuery()

    let id: String
    let name: String
    let model: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(model)")
    }

    /// Typed accessor.
    var hostID: HostID { HostID(id) }

    init(host: ManifoldKit.Host) {
        self.id = host.id.rawValue
        self.name = host.name
        self.model = host.model
    }
}

// MARK: - Queries

/// `DeviceEntityQuery` powers the Shortcuts editor's device picker.
/// Returns every connected device across every host.
struct DeviceEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [DeviceEntity] {
        let lookup = Set(identifiers)
        return Self.allDeviceEntities().filter { lookup.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [DeviceEntity] {
        Self.allDeviceEntities()
    }

    /// Walk `IntentEnvironment.dataSource.hosts` and project every
    /// connected device into a `DeviceEntity`. Returns empty when
    /// the data source isn't yet populated (cold launch).
    @MainActor
    static func allDeviceEntities() -> [DeviceEntity] {
        guard let source = IntentEnvironment.dataSource else { return [] }
        var out: [DeviceEntity] = []
        func walk(_ ports: [ManifoldKit.Port]) {
            for port in ports {
                if let device = port.connectedDevice {
                    out.append(DeviceEntity(device: device, powerDrawWatts: port.powerDraw?.value))
                }
                walk(port.children)
            }
        }
        for host in source.hosts { walk(host.ports) }
        return out
    }
}

/// `DiagnosticEntityQuery` projects the active diagnostics list.
struct DiagnosticEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [DiagnosticEntity] {
        let lookup = Set(identifiers)
        return Self.allDiagnosticEntities().filter { lookup.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [DiagnosticEntity] {
        Self.allDiagnosticEntities()
    }

    @MainActor
    static func allDiagnosticEntities() -> [DiagnosticEntity] {
        IntentEnvironment.dataSource?.diagnostics.map(DiagnosticEntity.init) ?? []
    }
}

/// `HostEntityQuery` returns every host in the live graph. Typical
/// Mac has one; future remote-host support per SPEC §4.6 may add more.
struct HostEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [HostEntity] {
        let lookup = Set(identifiers)
        return Self.allHostEntities().filter { lookup.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [HostEntity] {
        Self.allHostEntities()
    }

    @MainActor
    static func allHostEntities() -> [HostEntity] {
        IntentEnvironment.dataSource?.hosts.map(HostEntity.init) ?? []
    }
}
