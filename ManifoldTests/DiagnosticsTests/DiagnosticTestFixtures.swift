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
// DiagnosticTestFixtures.swift
//
// Shared graph-construction helpers for the Phase 8 diagnostic-rule
// tests. Each rule test lives in its own file (per SPEC §9: "Each
// rule has a sibling test file"); the helpers here are the common
// scaffold so each test reads as predicate-first ("given a port like
// this, expect rule emission like this") rather than buried in
// boilerplate.

import Foundation
@testable import Manifold
import ManifoldKit

enum DiagnosticTestFixtures {

    /// Build a single-host graph with the supplied ports as
    /// host-rooted entries. Use the `port(...)` builder below to
    /// construct the entries.
    static func host(ports: [ManifoldKit.Port]) -> [ManifoldKit.Host] {
        [ManifoldKit.Host(id: HostID("test-host"), name: "Test", model: "Test", ports: ports)]
    }

    /// Construct one Port with sensible test defaults. Override only
    /// the fields the test actually exercises; everything else gets a
    /// neutral value that won't accidentally fire any other rule.
    static func port(
        id: String = "/test/port",
        position: Int = 1,
        kind: PortKind = .usbC,
        device: Device? = device(),
        protocolName: String = "USB 3.0",
        powerDrawWatts: Double? = 0.5,
        availablePowerWatts: Double? = nil,
        children: [ManifoldKit.Port] = []
    ) -> ManifoldKit.Port {
        ManifoldKit.Port(
            id: PortID(id),
            position: position,
            kind: kind,
            parentID: nil,
            connectedDevice: device,
            negotiated: LinkSpeed(
                protocolName: protocolName,
                bitrate: Bitrate(bitsPerSecond: 5_000_000_000)
            ),
            powerDraw: powerDrawWatts.map(Watts.init),
            availablePower: availablePowerWatts.map(Watts.init),
            children: children
        )
    }

    /// Construct a Device with a nameable USB version. Default is
    /// `.usb3_0` so positive-trigger rules don't have to spell it
    /// out.
    static func device(
        name: String = "Test Device",
        usbVersion: USBVersion? = .usb3_0,
        kind: DeviceKind = .other
    ) -> Device {
        Device(
            id: DeviceID("0000:0000:\(name)"),
            name: name,
            kind: kind,
            vendorID: 0,
            productID: 0,
            serial: name,
            usbVersion: usbVersion,
            displayInfo: nil,
            firstSeen: Date(timeIntervalSince1970: 0),
            lastSeen: Date(timeIntervalSince1970: 0)
        )
    }
}
