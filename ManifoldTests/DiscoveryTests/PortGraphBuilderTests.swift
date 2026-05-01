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
// PortGraphBuilderTests.swift
//
// Per SPEC.md §18 Phase 2: "PortGraphBuilder produces a valid [Host]
// from a captured ioreg fixture." Drives the builder against the
// existing 3-device fixture (USBWalkerTests already validated the
// fixture parses; these tests validate it composes into the right
// [Host] graph).
//
// Tests are written against the live fixture file rather than
// hand-constructed snapshots so a future fixture edit is exercised
// end-to-end.

import XCTest
@testable import Manifold
import ManifoldKit

final class PortGraphBuilderTests: XCTestCase {

    // MARK: - Fixture

    private static let fixtureName = "ioreg-mbp-m3-2usb-1tb"
    private static let timestamp = Date(timeIntervalSince1970: 1_750_000_000)

    private func fixtureURL() throws -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: Self.fixtureName, withExtension: "json") else {
            throw FixtureLookupError.notFound(name: Self.fixtureName)
        }
        return url
    }

    private enum FixtureLookupError: Error {
        case notFound(name: String)
    }

    private func snapshotsFromFixture() throws -> [USBDeviceSnapshot] {
        let url = try fixtureURL()
        return try FixtureUSBSource(fixtureURL: url).enumerate()
    }

    private func metadata() -> HostMetadata {
        HostMetadata(
            id: HostID("TEST-MACHINE-UUID"),
            name: "Test Mac",
            model: "MacTest1,1"
        )
    }

    // MARK: - Build → Host

    /// Validates the headline contract: snapshots in, valid `Host`
    /// out, every device represented as a port + connected device.
    func test_buildHost_fromCanonicalFixture_producesOneHostWithThreePorts() throws {
        let builder = PortGraphBuilder()
        let snapshots = try snapshotsFromFixture()

        let host = builder.buildHost(
            metadata: metadata(),
            usbDevices: snapshots,
            timestamp: Self.timestamp
        )

        XCTAssertEqual(host.id, HostID("TEST-MACHINE-UUID"))
        XCTAssertEqual(host.name, "Test Mac")
        XCTAssertEqual(host.model, "MacTest1,1")
        XCTAssertEqual(host.ports.count, 3, "Three devices in fixture → three host-rooted ports.")
    }

    /// Each port has its connected device populated with the right
    /// VID/PID and a derived USB version.
    func test_buildHost_eachPortHasDeviceWithCorrectVidPidAndUsbVersion() throws {
        let host = try buildFromFixture()

        // Sanity: every port has a device.
        XCTAssertTrue(host.ports.allSatisfy { $0.connectedDevice != nil })

        // Match by VID; assert PID + usbVersion derived from bcdUSB.
        let logi = try XCTUnwrap(host.ports.first { $0.connectedDevice?.vendorID == 0x046D }?.connectedDevice)
        XCTAssertEqual(logi.productID, 0xC52B)
        XCTAssertEqual(logi.usbVersion, .usb2_0, "bcdUSB 0x0210 → USB 2.0")

        let sandisk = try XCTUnwrap(host.ports.first { $0.connectedDevice?.vendorID == 0x0781 }?.connectedDevice)
        XCTAssertEqual(sandisk.productID, 0x55A2)
        XCTAssertEqual(sandisk.usbVersion, .usb3_2, "bcdUSB 0x0320 → USB 3.2")
    }

    /// Negotiated link speed and power draw are populated on the port
    /// (not the device — the link is a property of where the device is
    /// plugged, not what it is).
    func test_buildHost_negotiatedSpeedAndPowerArePerPort() throws {
        let host = try buildFromFixture()

        // SanDisk: Speed code 4 → "USB Super Speed+", 10 Gbps,
        // 896 mA × 5 V = 4.48 W
        let sandiskPort = try XCTUnwrap(host.ports.first {
            $0.connectedDevice?.vendorID == 0x0781
        })
        XCTAssertEqual(sandiskPort.negotiated?.protocolName, "USB Super Speed+")
        XCTAssertEqual(sandiskPort.negotiated?.bitrate.bitsPerSecond, 10_000_000_000)
        XCTAssertEqual(sandiskPort.powerDraw?.value ?? 0, 4.48, accuracy: 0.001)
    }

    /// Phase-2 simplification: every port is host-rooted (no `parentID`).
    /// Phase 7 reconstructs hub hierarchy; this test pins the current
    /// behaviour so the Reviewer notices when Phase 7 changes it.
    func test_buildHost_phase2_everyPortIsHostRooted() throws {
        let host = try buildFromFixture()
        for port in host.ports {
            XCTAssertNil(port.parentID, "Phase 2 keeps every port host-rooted; Phase 7 introduces nesting.")
        }
    }

    /// DeviceID derivation matches DeviceID.make output — pinning the
    /// builder to use the canonical factory rather than rolling its own
    /// composite-ID logic. Defends against a future shortcut that would
    /// silently break replug stability.
    func test_buildHost_deviceID_matchesDeviceIDMake() throws {
        let host = try buildFromFixture()
        let sandisk = try XCTUnwrap(host.ports.first { $0.connectedDevice?.vendorID == 0x0781 }?.connectedDevice)
        let expected = DeviceID.make(
            vendorID: 0x0781,
            productID: 0x55A2,
            serial: "0123456789ABCDEF",
            registryPath: "irrelevant-when-serial-present"
        )
        XCTAssertEqual(sandisk.id, expected)
    }

    /// `firstSeen` and `lastSeen` are stamped from the supplied
    /// timestamp. Confirms the builder doesn't accidentally reach for
    /// `Date.now` and break test determinism.
    func test_buildHost_firstSeenAndLastSeen_useSuppliedTimestamp() throws {
        let host = try buildFromFixture()
        for port in host.ports {
            let device = try XCTUnwrap(port.connectedDevice)
            XCTAssertEqual(device.firstSeen, Self.timestamp)
            XCTAssertEqual(device.lastSeen, Self.timestamp)
        }
    }

    // MARK: - Computed totals

    /// `Host.totalPowerDraw` sums per-port draw correctly.
    /// Logitech (98 mA × 5 V = 0.49 W) + SanDisk (896 mA × 5 V = 4.48 W)
    /// + Studio Display (500 mA × 5 V = 2.5 W) = 7.47 W.
    func test_buildHost_totalPowerDraw_sumsPerPort() throws {
        let host = try buildFromFixture()
        XCTAssertEqual(host.totalPowerDraw.value, 7.47, accuracy: 0.001)
    }

    // MARK: - Bitrate static helper

    /// Pins the IOKit Speed code → Bitrate mapping. Static method so
    /// callers don't need a builder instance to ask the question.
    func test_bitrateForSpeedCode_pinnedValues() {
        XCTAssertEqual(PortGraphBuilder.bitrate(forSpeedCode: 0).bitsPerSecond,    1_500_000)
        XCTAssertEqual(PortGraphBuilder.bitrate(forSpeedCode: 2).bitsPerSecond,  480_000_000)
        XCTAssertEqual(PortGraphBuilder.bitrate(forSpeedCode: 4).bitsPerSecond, 10_000_000_000)
        XCTAssertEqual(PortGraphBuilder.bitrate(forSpeedCode: 99).bitsPerSecond, 0, "Unknown codes → 0 bps fallback.")
    }

    // MARK: - Helpers

    private func buildFromFixture() throws -> ManifoldKit.Host {
        let snapshots = try snapshotsFromFixture()
        return PortGraphBuilder().buildHost(
            metadata: metadata(),
            usbDevices: snapshots,
            timestamp: Self.timestamp
        )
    }
}
