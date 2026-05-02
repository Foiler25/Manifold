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
// USB2OnUSB3DeviceRuleTests.swift
//
// Per SPEC.md §9: positive trigger, negative similar-but-not, edge
// case. The rule fires when a USB3-capable device is currently
// linked at USB 2.0.

import XCTest
@testable import Manifold
import ManifoldKit

final class USB2OnUSB3DeviceRuleTests: XCTestCase {

    private let rule = USB2OnUSB3DeviceRule()

    /// Positive: USB 3.0 device on a USB 2.0 link → one diagnostic
    /// pointing at the port.
    func test_positive_usb3DeviceOnUSB2Link_emitsDiagnostic() {
        let port = DiagnosticTestFixtures.port(
            id: "/usb3-on-usb2",
            device: DiagnosticTestFixtures.device(usbVersion: .usb3_0),
            protocolName: "USB 2.0"
        )
        let diagnostics = rule.evaluate(against: DiagnosticTestFixtures.host(ports: [port]))

        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.target, port.id)
        XCTAssertEqual(diagnostics.first?.ruleIdentifier, "running-at-usb-2")
        XCTAssertEqual(diagnostics.first?.severity, .warning)
    }

    /// Negative: a USB 2.0 device on a USB 2.0 link is normal, not a
    /// diagnostic. Verifies the version check (not just the link
    /// check) is firing.
    func test_negative_usb2DeviceOnUSB2Link_isClean() {
        let port = DiagnosticTestFixtures.port(
            device: DiagnosticTestFixtures.device(usbVersion: .usb2_0),
            protocolName: "USB 2.0"
        )
        XCTAssertTrue(rule.evaluate(against: DiagnosticTestFixtures.host(ports: [port])).isEmpty)
    }

    /// Edge: nil `usbVersion` on the device (TB-native, displays).
    /// The rule must skip; an "unknown version" device on USB 2.0
    /// shouldn't produce a misleading "your device should be faster"
    /// alert when we can't actually tell.
    func test_edge_nilUSBVersion_isClean() {
        let port = DiagnosticTestFixtures.port(
            device: DiagnosticTestFixtures.device(usbVersion: nil),
            protocolName: "USB 2.0"
        )
        XCTAssertTrue(rule.evaluate(against: DiagnosticTestFixtures.host(ports: [port])).isEmpty)
    }

    /// Edge: USB 4 device on USB 2.0 should also fire (the rule
    /// targets "USB3 or later", not just "USB 3.0 exactly"). Pins
    /// the `isUSB3Capable` membership check.
    func test_edge_usb4DeviceOnUSB2Link_emitsDiagnostic() {
        let port = DiagnosticTestFixtures.port(
            device: DiagnosticTestFixtures.device(usbVersion: .usb4),
            protocolName: "USB 2.0"
        )
        XCTAssertEqual(rule.evaluate(against: DiagnosticTestFixtures.host(ports: [port])).count, 1)
    }
}
