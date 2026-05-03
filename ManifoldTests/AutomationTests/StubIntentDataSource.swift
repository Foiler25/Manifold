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
// StubIntentDataSource.swift
//
// Test-only `IntentDataSource` impl: returns canned values from
// stored properties. Lets the per-intent perform() tests run
// without spinning up DatabaseManager / PortGraph / DiscoveryService.

import Foundation
import AppIntents
@testable import Manifold
import ManifoldKit

@MainActor
final class StubIntentDataSource: IntentDataSource {
    var hosts: [ManifoldKit.Host] = []
    var diagnostics: [Diagnostic] = []
    var stubbedRecentEvents: [StoredEvent] = []
    var recentEventsError: Error?

    func recentEvents(limit: Int) async throws -> [StoredEvent] {
        if let recentEventsError { throw recentEventsError }
        return Array(stubbedRecentEvents.prefix(limit))
    }
}

// MARK: - Fixture helpers

// MARK: - IntentResult value extractor

/// Pull the `value` out of an `IntentResult & ReturnsValue<T>` via
/// reflection. The framework's `value` accessor isn't stably part
/// of the public surface, but every conforming type stores the
/// returned value on a `value` keypath. Reflection keeps the test
/// portable across AppIntents revisions.
func intentValue<R>(of result: some IntentResult, as type: R.Type = R.self) throws -> R {
    let mirror = Mirror(reflecting: result)
    for child in mirror.children {
        if child.label == "value", let typed = child.value as? R {
            return typed
        }
    }
    // Try one level of nesting (the framework wraps the value
    // inside a `_resultParameter` or similar private struct in
    // some macOS revisions).
    for child in mirror.children {
        let inner = Mirror(reflecting: child.value)
        for nested in inner.children {
            if let typed = nested.value as? R {
                return typed
            }
        }
    }
    throw IntentResultExtractionError.valueNotFound
}

enum IntentResultExtractionError: Error {
    case valueNotFound
}

@MainActor
enum IntentTestFixtures {

    /// Single-host graph with the supplied ports under one host.
    static func host(id: String = "test-host", ports: [ManifoldKit.Port]) -> ManifoldKit.Host {
        ManifoldKit.Host(id: HostID(id), name: "Test Host", model: "Test", ports: ports)
    }

    static func port(
        id: String,
        position: Int = 1,
        kind: PortKind = .usbC,
        device: Device? = nil,
        powerDraw: Watts? = nil,
        children: [ManifoldKit.Port] = []
    ) -> ManifoldKit.Port {
        ManifoldKit.Port(
            id: PortID(id),
            position: position,
            kind: kind,
            parentID: nil,
            connectedDevice: device,
            negotiated: nil,
            powerDraw: powerDraw,
            children: children
        )
    }

    static func device(
        name: String,
        vendorID: UInt16 = 0x1234,
        productID: UInt16 = 0x5678,
        serial: String? = nil
    ) -> Device {
        let resolvedSerial = serial ?? name
        return Device(
            id: DeviceID.make(vendorID: vendorID, productID: productID, serial: resolvedSerial, registryPath: "/test/\(name)"),
            name: name,
            kind: .other,
            vendorID: vendorID,
            productID: productID,
            serial: resolvedSerial,
            usbVersion: .usb3_0,
            displayInfo: nil,
            firstSeen: Date(timeIntervalSince1970: 0),
            lastSeen: Date(timeIntervalSince1970: 0)
        )
    }
}
