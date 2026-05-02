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
// USBWalkerTests.swift
//
// Phase-1 unit tests for `USBWalker` driven by `FixtureUSBSource`. The
// production path (`LiveIOKitUSBSource`) is exercised by the Phase 1
// app itself and by manual Instruments runs — covered separately, not
// here, because hitting live IOKit in unit tests would make CI flaky
// and tie tests to whatever happens to be plugged in.
//
// Per SPEC.md §17 the test target uses XCTest. `@testable import
// Manifold` exposes the walker's internal types (USBDeviceSnapshot,
// FixtureUSBSource, USBWalker) without making them public.

import XCTest
@testable import Manifold

final class USBWalkerTests: XCTestCase {

    // MARK: - Fixture lookup

    /// Canonical fixture name shipped for Phase 1.
    private static let fixtureName = "ioreg-mbp-m3-2usb-1tb"

    /// Locate the fixture inside the test bundle. Synced groups in the
    /// Xcode project pick the JSON up automatically as a Resources-phase
    /// item, so `Bundle(for: …).url(forResource:withExtension:)` finds it
    /// without any path math.
    private func fixtureURL(named name: String) throws -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            // Throw rather than XCTFail so a missing fixture surfaces as
            // "fixture not bundled" rather than as the wrong device-count
            // assertion firing further down.
            throw FixtureLookupError.notFound(name: name)
        }
        return url
    }

    private enum FixtureLookupError: Error {
        case notFound(name: String)
    }

    // MARK: - Walks

    /// Spec criterion: "USBWalkerTests.swift parses the fixture and
    /// asserts the right device count + names."
    func test_walk_fromCanonicalFixture_producesThreeNamedDevices() throws {
        let walker = try makeWalker()
        let devices = try walker.walk()

        XCTAssertEqual(devices.count, 3, "Canonical fixture ships 3 devices.")

        // Sorted by registryPath (USBWalker.walk's contract). The
        // fixture's paths sort lexicographically as:
        // 01100000 → 02100000 → 03100000.
        let names = devices.compactMap { $0.productName }
        XCTAssertEqual(
            names,
            ["USB Receiver", "Extreme Pro SSD", "Studio Display"],
            "Names should appear in registry-path order."
        )
    }

    /// Each device gets a non-zero VID and PID. Defends against future
    /// edits to the fixture that accidentally drop a VID.
    func test_walk_everyDeviceHasVidAndPid() throws {
        let walker = try makeWalker()
        let devices = try walker.walk()

        for device in devices {
            XCTAssertNotEqual(device.vendorID, 0, "VID 0 is invalid USB.")
            XCTAssertNotEqual(device.productID, 0, "PID 0 is invalid USB.")
        }
    }

    /// Field-by-field assertion on the SanDisk SSD entry. Catches any
    /// future regression in property bridging — particularly around the
    /// IOKit keys with spaces ("USB Product Name", "Requested Power")
    /// that `FixtureUSBSource.FixtureDevice.CodingKeys` translates.
    func test_walk_sandiskRecord_decodesEveryField() throws {
        let walker = try makeWalker()
        let devices = try walker.walk()

        // Locate by VID+PID, not by index, so a future re-sort doesn't
        // break this test.
        guard let ssd = devices.first(where: { $0.vendorID == 0x0781 }) else {
            return XCTFail("SanDisk entry missing from fixture.")
        }

        XCTAssertEqual(ssd.vendorID,         0x0781)
        XCTAssertEqual(ssd.productID,        0x55A2)
        XCTAssertEqual(ssd.productName,      "Extreme Pro SSD")
        XCTAssertEqual(ssd.vendorName,       "SanDisk")
        XCTAssertEqual(ssd.serial,           "0123456789ABCDEF")
        XCTAssertEqual(ssd.bcdUSB,           0x0320)
        XCTAssertEqual(ssd.speed,            4)
        XCTAssertEqual(ssd.requestedPowerMA, 896)
        XCTAssertEqual(ssd.portNum,          1)
        XCTAssertEqual(ssd.locationID,       0x02000000)
    }

    /// The Logitech receiver has no serial number — the JSON field is
    /// `null`. Assert that this maps to Swift `nil` rather than an empty
    /// string. (DECISIONS.md D9 falls back to registryPath when serial
    /// is `nil`; an empty string would silently produce a different
    /// composite ID and break replug stability.)
    func test_walk_logitechRecord_serialNumberMapsToNilNotEmptyString() throws {
        let walker = try makeWalker()
        let devices = try walker.walk()

        guard let logi = devices.first(where: { $0.vendorID == 0x046D }) else {
            return XCTFail("Logitech entry missing from fixture.")
        }

        XCTAssertNil(logi.serial)
    }

    /// `walk()`'s contract is sorted-by-registryPath output. Verify it
    /// holds even when the fixture's source order is shuffled — done by
    /// hand-constructing a second fixture inline.
    func test_walk_outputIsSortedByRegistryPath() throws {
        let walker = try makeWalker()
        let devices = try walker.walk()

        let paths = devices.map { $0.registryPath }
        XCTAssertEqual(paths, paths.sorted(), "Output is sorted by registryPath.")
    }

    // MARK: - Speed lookup

    /// Sanity check on the speed-name table. Cheap to test, easy to
    /// regress (off-by-one on the enum), worth pinning.
    func test_speedName_mapsKnownCodesToReadableStrings() {
        XCTAssertEqual(USBDiscoveryConstants.speedName(for: 0), "USB Low Speed")
        XCTAssertEqual(USBDiscoveryConstants.speedName(for: 2), "USB High Speed")
        XCTAssertEqual(USBDiscoveryConstants.speedName(for: 4), "USB Super Speed+")
        XCTAssertEqual(USBDiscoveryConstants.speedName(for: nil), "Unknown")
        XCTAssertTrue(USBDiscoveryConstants.speedName(for: 99).contains("USB ?"))
    }

    // MARK: - bcdUSB → Speed code (Reviewer F13)

    /// Per-cluster pin test for `LiveIOKitUSBSource.deriveSpeedFromBcd`.
    /// Phase 2's F5 fallback chain depends on this when canonical
    /// `Speed` is nil (the M1 Max boot SSD case). Directly testing
    /// each USB-version cluster catches off-by-one regressions in the
    /// switch ranges that the live-walk acceptance check would only
    /// surface for Brandon's specific boot SSD.
    func test_deriveSpeedFromBcd_usb1_returnsFullSpeed() {
        XCTAssertEqual(LiveIOKitUSBSource.deriveSpeedFromBcd(0x0100), 1)
        XCTAssertEqual(LiveIOKitUSBSource.deriveSpeedFromBcd(0x0110), 1)
    }

    func test_deriveSpeedFromBcd_usb2_returnsHighSpeed() {
        XCTAssertEqual(LiveIOKitUSBSource.deriveSpeedFromBcd(0x0200), 2)
        XCTAssertEqual(LiveIOKitUSBSource.deriveSpeedFromBcd(0x0210), 2)
    }

    func test_deriveSpeedFromBcd_usb3Range_returnsSuperSpeed() {
        XCTAssertEqual(LiveIOKitUSBSource.deriveSpeedFromBcd(0x0300), 3)
        XCTAssertEqual(LiveIOKitUSBSource.deriveSpeedFromBcd(0x0310), 3)
        XCTAssertEqual(LiveIOKitUSBSource.deriveSpeedFromBcd(0x0320), 3)
        XCTAssertEqual(LiveIOKitUSBSource.deriveSpeedFromBcd(0x03FF), 3)
    }

    func test_deriveSpeedFromBcd_usb4Range_returnsSuperSpeedPlus() {
        XCTAssertEqual(LiveIOKitUSBSource.deriveSpeedFromBcd(0x0400), 4)
        XCTAssertEqual(LiveIOKitUSBSource.deriveSpeedFromBcd(0x0450), 4)
        XCTAssertEqual(LiveIOKitUSBSource.deriveSpeedFromBcd(0x04FF), 4)
    }

    /// nil input → nil output (no false positive). Vendor-extended
    /// BCDs we don't recognise also return nil → "Unknown" in UI.
    func test_deriveSpeedFromBcd_unknownAndNil_returnsNil() {
        XCTAssertNil(LiveIOKitUSBSource.deriveSpeedFromBcd(nil))
        XCTAssertNil(LiveIOKitUSBSource.deriveSpeedFromBcd(0x0500))   // not yet mapped
        XCTAssertNil(LiveIOKitUSBSource.deriveSpeedFromBcd(0xFFFF))
    }

    // MARK: - Helpers

    private func makeWalker() throws -> USBWalker {
        let url = try fixtureURL(named: Self.fixtureName)
        return USBWalker(source: FixtureUSBSource(fixtureURL: url))
    }
}
