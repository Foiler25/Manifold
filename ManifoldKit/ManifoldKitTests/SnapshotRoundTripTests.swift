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
// SnapshotRoundTripTests.swift
//
// Per SPEC.md §18 Phase 2: every Codable type round-trips through
// JSONEncoder + JSONDecoder. Catches:
//   - Coding-key drift (a renamed field that breaks the wire format).
//   - Optional handling regressions (nil <-> missing field).
//   - Custom Codable bugs in the ID + Units single-value encoders.
//
// `JSONEncoder.OutputFormatting.sortedKeys` makes the encoded payload
// deterministic so the assertion can compare the encoded bytes too,
// not just the decoded value — useful when debugging coding-key
// regressions because the failure shows the actual JSON.

import XCTest
@testable import ManifoldKit
import Foundation
import CoreGraphics

final class SnapshotRoundTripTests: XCTestCase {

    // MARK: - Helpers

    /// Encode + decode + assert equality. Returns the encoded JSON
    /// string for any test that wants to make additional structural
    /// assertions on the wire format.
    @discardableResult
    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(T.self, from: data)

        XCTAssertEqual(value, restored, "Round-trip mismatch for \(T.self)", file: file, line: line)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Identifiers (single-value Codable)

    func test_hostID_roundTrip_encodesAsBareString() throws {
        let id = HostID("00000000-0000-0000-0000-AABBCCDDEEFF")
        let json = try roundTrip(id)
        XCTAssertEqual(json, "\"00000000-0000-0000-0000-AABBCCDDEEFF\"")
    }

    func test_portID_roundTrip_encodesAsBareString() throws {
        let id = PortID("IOService:/AppleARMPE/arm-io@10F00000/USB@01100000")
        let json = try roundTrip(id)
        XCTAssertTrue(json.hasPrefix("\""))
        XCTAssertTrue(json.contains("AppleARMPE"))
    }

    func test_deviceID_roundTrip_encodesAsBareString() throws {
        let id = DeviceID.make(
            vendorID: 0x05AC,
            productID: 0x1234,
            serial: "SN12345",
            registryPath: "irrelevant-when-serial-present"
        )
        let json = try roundTrip(id)
        XCTAssertEqual(json, "\"05ac:1234:SN12345\"")
    }

    // MARK: - Units (single-value Codable)

    func test_watts_roundTrip_encodesAsBareNumber() throws {
        let json = try roundTrip(Watts(2.5))
        XCTAssertEqual(json, "2.5")
    }

    func test_bitrate_roundTrip_encodesAsBareNumber() throws {
        let json = try roundTrip(Bitrate(bitsPerSecond: 10_000_000_000))
        XCTAssertEqual(json, "10000000000")
    }

    // MARK: - Core entities

    func test_linkSpeed_roundTrip() throws {
        try roundTrip(LinkSpeed(protocolName: "USB 3.2", bitrate: Bitrate(bitsPerSecond: 10_000_000_000)))
    }

    func test_displayInfo_roundTrip() throws {
        try roundTrip(DisplayInfo(
            resolution: CGSize(width: 5120, height: 2880),
            refreshHz: 60,
            panelType: "Retina 5K",
            isMain: true,
            isBuiltIn: false,
            supportsHDR: true
        ))
    }

    func test_device_roundTrip_withAllOptionalsPopulated() throws {
        try roundTrip(makeStudioDisplayDevice())
    }

    func test_device_roundTrip_withOptionalsNil() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        try roundTrip(Device(
            id: DeviceID("0781:55a2:nil-test"),
            name: "Bare device",
            kind: .other,
            vendorID: 0x0781,
            productID: 0x55A2,
            serial: nil,
            usbVersion: nil,
            displayInfo: nil,
            firstSeen: now,
            lastSeen: now
        ))
    }

    func test_port_roundTrip_emptyPortNoDevice() throws {
        try roundTrip(makeEmptyPort())
    }

    func test_port_roundTrip_hubWithChildren() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let childDevice = Device(
            id: DeviceID("046d:c52b:nil-test"),
            name: "Logitech mouse",
            kind: .input,
            vendorID: 0x046D,
            productID: 0xC52B,
            serial: nil,
            usbVersion: .usb2_0,
            displayInfo: nil,
            firstSeen: now,
            lastSeen: now
        )
        let child = ManifoldKit.Port(
            id: PortID("IOService:/.../child"),
            position: 1,
            kind: .usbA,
            parentID: PortID("IOService:/.../parent"),
            connectedDevice: childDevice,
            negotiated: LinkSpeed(protocolName: "USB 2.0", bitrate: Bitrate(bitsPerSecond: 480_000_000)),
            powerDraw: Watts(0.5),
            children: []
        )
        let parent = ManifoldKit.Port(
            id: PortID("IOService:/.../parent"),
            position: 1,
            kind: .usbC,
            parentID: nil,
            connectedDevice: nil,
            negotiated: nil,
            powerDraw: nil,
            children: [child]
        )
        try roundTrip(parent)
    }

    func test_host_roundTrip() throws {
        let host = Host(
            id: HostID("MACHINE-UUID"),
            name: "MacBook Pro",
            model: "Mac15,9",
            ports: [makeEmptyPort()]
        )
        try roundTrip(host)
    }

    // MARK: - Diagnostic + PortEvent

    func test_diagnostic_roundTrip() throws {
        try roundTrip(Diagnostic(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            target: PortID("IOService:/.../target"),
            severity: .warning,
            ruleIdentifier: "running-at-usb-2",
            title: "Running @ USB 2.0",
            detail: "Device supports USB 3.0 but is on a USB 2.0 link.",
            triggeredAt: Date(timeIntervalSince1970: 1_750_000_000)
        ))
    }

    func test_telemetrySample_roundTrip_withOptionalsPopulated() throws {
        try roundTrip(TelemetrySample(
            timestamp: Date(timeIntervalSince1970: 1_750_000_000),
            watts: Watts(1.2),
            bitrate: Bitrate(bitsPerSecond: 5_000_000_000)
        ))
    }

    func test_telemetrySample_roundTrip_withOptionalsNil() throws {
        try roundTrip(TelemetrySample(
            timestamp: Date(timeIntervalSince1970: 1_750_000_000),
            watts: nil,
            bitrate: nil
        ))
    }

    func test_portEvent_attached_roundTrip() throws {
        try roundTrip(PortEvent.attached(makeStudioDisplayDevice(), at: PortID("IOService:/.../target")))
    }

    func test_portEvent_detached_roundTrip() throws {
        try roundTrip(PortEvent.detached(deviceID: DeviceID("05ac:1234:SN"), from: PortID("IOService:/.../target")))
    }

    func test_portEvent_telemetry_roundTrip() throws {
        try roundTrip(PortEvent.telemetry(
            PortID("IOService:/.../target"),
            TelemetrySample(timestamp: Date(timeIntervalSince1970: 0), watts: Watts(0.1), bitrate: nil)
        ))
    }

    func test_portEvent_diagnostic_roundTrip() throws {
        let diag = Diagnostic(
            target: PortID("IOService:/.../target"),
            severity: .info,
            ruleIdentifier: "rule-x",
            title: "X",
            detail: "Y",
            triggeredAt: Date(timeIntervalSince1970: 0)
        )
        try roundTrip(PortEvent.diagnostic(diag))
    }

    func test_portEvent_fullRefresh_roundTrip() throws {
        try roundTrip(PortEvent.fullRefresh)
    }

    // MARK: - Fixtures

    private func makeStudioDisplayDevice() -> Device {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        return Device(
            id: DeviceID.make(vendorID: 0x05AC, productID: 0x1234, serial: "SD-SN", registryPath: "irrelevant"),
            name: "Studio Display",
            kind: .display,
            vendorID: 0x05AC,
            productID: 0x1234,
            serial: "SD-SN",
            usbVersion: .usb3_2,
            displayInfo: DisplayInfo(
                resolution: CGSize(width: 5120, height: 2880),
                refreshHz: 60,
                panelType: "Retina 5K",
                isMain: false,
                isBuiltIn: false,
                supportsHDR: false
            ),
            firstSeen: now,
            lastSeen: now
        )
    }

    private func makeEmptyPort() -> ManifoldKit.Port {
        ManifoldKit.Port(
            id: PortID("IOService:/.../empty"),
            position: 1,
            kind: .usbC,
            parentID: nil,
            connectedDevice: nil,
            negotiated: nil,
            powerDraw: nil,
            children: []
        )
    }
}
