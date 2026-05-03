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
// NotificationContentBuilderTests.swift
//
// Pin the per-event-type behaviour of the builder + the toggle
// gating per SPEC §18 Phase 9 #2 + #4. The UN delivery itself is
// not testable (process-singleton with no DI), but every decision
// the builder makes is.

import XCTest
import UserNotifications
@testable import Manifold
import ManifoldKit

final class NotificationContentBuilderTests: XCTestCase {

    // MARK: - Per-event-type happy path

    /// `.attached` → content with the connect title + device name as
    /// subtitle + port summary as body. Pins the Phase 9 layout.
    func test_attached_buildsContent_withDeviceNameAndPortSummary() {
        let device = makeDevice(name: "Logitech MX Master 3")
        let port = makePort(id: "/host/port-1", position: 1, kind: .usbC, device: device)
        let host = makeHost(ports: [port])

        let content = NotificationContentBuilder.makeContent(
            for: .attached(device, at: port.id),
            hosts: [host],
            preferences: makePreferences(connect: true)
        )

        XCTAssertNotNil(content)
        XCTAssertEqual(content?.subtitle, "Logitech MX Master 3")
        XCTAssertTrue(content?.body.contains("USB-C Port") ?? false)
        XCTAssertTrue(content?.body.contains("1") ?? false)
        XCTAssertEqual(content?.threadIdentifier, port.id.rawValue)
    }

    /// `.detached` resolves the device name from the pre-apply
    /// graph (the device is still present in `hosts`). Pins the
    /// "ordering matters" contract: AppDelegate calls notify
    /// BEFORE portGraph.apply.
    func test_detached_resolvesDeviceNameFromPreApplyGraph() {
        let device = makeDevice(name: "SanDisk Extreme")
        let port = makePort(id: "/host/port-2", position: 2, kind: .usbC, device: device)
        let host = makeHost(ports: [port])

        let content = NotificationContentBuilder.makeContent(
            for: .detached(deviceID: device.id, from: port.id),
            hosts: [host],
            preferences: makePreferences(disconnect: true)
        )

        XCTAssertNotNil(content)
        XCTAssertEqual(content?.subtitle, "SanDisk Extreme")
    }

    /// `.detached` falls back to "Unknown device" when the device is
    /// no longer in the graph (e.g., a stale event arriving after a
    /// rebuild). Notification still fires; the user just sees a
    /// generic label.
    func test_detached_unknownDevice_fallsBackToGenericLabel() {
        let port = makePort(id: "/host/port-3", position: 3, kind: .usbA, device: nil)
        let host = makeHost(ports: [port])

        let content = NotificationContentBuilder.makeContent(
            for: .detached(deviceID: DeviceID("0000:0000:gone"), from: port.id),
            hosts: [host],
            preferences: makePreferences(disconnect: true)
        )

        XCTAssertNotNil(content)
        // The fallback string starts with "Unknown" in en — assert
        // by case-insensitive contains so a future copy edit keeps
        // the test green.
        XCTAssertTrue(content?.subtitle.range(of: "Unknown", options: .caseInsensitive) != nil)
    }

    /// `.diagnostic` carries the rule's title + detail directly into
    /// the notification. Pins the "diagnostic title is the
    /// notification headline" contract.
    func test_diagnostic_usesRuleTitleAndDetailVerbatim() {
        let port = makePort(id: "/host/port-4", position: 4, kind: .thunderbolt, device: nil)
        let host = makeHost(ports: [port])
        let diag = Diagnostic(
            target: port.id,
            severity: .warning,
            ruleIdentifier: "running-at-usb-2",
            title: "Running @ USB 2.0",
            detail: "SSD supports USB 3.0 but is on a USB 2.0 link."
        )

        let content = NotificationContentBuilder.makeContent(
            for: .diagnostic(diag),
            hosts: [host],
            preferences: makePreferences(diagnostic: true)
        )

        XCTAssertEqual(content?.title, "Running @ USB 2.0")
        XCTAssertEqual(content?.body, "SSD supports USB 3.0 but is on a USB 2.0 link.")
    }

    // MARK: - Toggle gating

    /// connect=false suppresses `.attached` notifications.
    func test_attached_connectDisabled_returnsNil() {
        let device = makeDevice(name: "Mouse")
        let port = makePort(id: "/p", position: 1, kind: .usbC, device: device)
        let content = NotificationContentBuilder.makeContent(
            for: .attached(device, at: port.id),
            hosts: [makeHost(ports: [port])],
            preferences: makePreferences(connect: false)
        )
        XCTAssertNil(content)
    }

    /// disconnect=false suppresses `.detached` notifications.
    func test_detached_disconnectDisabled_returnsNil() {
        let device = makeDevice(name: "Mouse")
        let port = makePort(id: "/p", position: 1, kind: .usbC, device: device)
        let content = NotificationContentBuilder.makeContent(
            for: .detached(deviceID: device.id, from: port.id),
            hosts: [makeHost(ports: [port])],
            preferences: makePreferences(disconnect: false)
        )
        XCTAssertNil(content)
    }

    /// diagnostic=false suppresses `.diagnostic` notifications.
    func test_diagnostic_disabled_returnsNil() {
        let diag = Diagnostic(
            target: PortID("/p"),
            severity: .warning,
            ruleIdentifier: "x",
            title: "X",
            detail: "Y"
        )
        let content = NotificationContentBuilder.makeContent(
            for: .diagnostic(diag),
            hosts: [],
            preferences: makePreferences(diagnostic: false)
        )
        XCTAssertNil(content)
    }

    // MARK: - Always-suppressed events

    /// `.telemetry` never fires a notification regardless of toggle
    /// state — it would be far too noisy (1 Hz × N devices).
    func test_telemetry_alwaysReturnsNil() {
        let content = NotificationContentBuilder.makeContent(
            for: .telemetry(PortID("/p"), TelemetrySample(timestamp: Date(), watts: nil, bitrate: nil)),
            hosts: [],
            preferences: makePreferences(connect: true, disconnect: true, diagnostic: true)
        )
        XCTAssertNil(content)
    }

    /// `.fullRefresh` is an internal coordination signal, never
    /// user-facing. No notification regardless of state.
    func test_fullRefresh_alwaysReturnsNil() {
        let content = NotificationContentBuilder.makeContent(
            for: .fullRefresh,
            hosts: [],
            preferences: makePreferences(connect: true, disconnect: true, diagnostic: true)
        )
        XCTAssertNil(content)
    }

    // MARK: - Helpers

    /// Build a `NotificationPreferences` over an isolated UserDefaults
    /// suite so this test class never touches the real defaults.
    private func makePreferences(
        connect: Bool = true,
        disconnect: Bool = true,
        diagnostic: Bool = true
    ) -> NotificationPreferences {
        let suite = "manifold-tests-notif-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        var prefs = NotificationPreferences(defaults: defaults)
        prefs.connectEnabled = connect
        prefs.disconnectEnabled = disconnect
        prefs.diagnosticEnabled = diagnostic
        return prefs
    }

    private func makeHost(ports: [ManifoldKit.Port]) -> ManifoldKit.Host {
        ManifoldKit.Host(id: HostID("test-host"), name: "Test", model: "Test", ports: ports)
    }

    private func makePort(
        id: String,
        position: Int,
        kind: PortKind,
        device: Device?
    ) -> ManifoldKit.Port {
        ManifoldKit.Port(
            id: PortID(id),
            position: position,
            kind: kind,
            parentID: nil,
            connectedDevice: device,
            negotiated: nil,
            powerDraw: nil,
            children: []
        )
    }

    private func makeDevice(name: String) -> Device {
        Device(
            id: DeviceID("0000:0000:\(name)"),
            name: name,
            kind: .other,
            vendorID: 0,
            productID: 0,
            serial: name,
            usbVersion: nil,
            displayInfo: nil,
            firstSeen: Date(timeIntervalSince1970: 0),
            lastSeen: Date(timeIntervalSince1970: 0)
        )
    }
}
