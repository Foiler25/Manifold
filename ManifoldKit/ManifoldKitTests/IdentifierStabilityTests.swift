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
// IdentifierStabilityTests.swift
//
// Per SPEC.md §18 Phase 2: PortID and DeviceID derivation must be
// deterministic — same inputs in, same identifier out, every time.
// Without this property the popover animates remove+add on every
// replug, history queries lose continuity, and `OutlineGroup`'s
// per-row state evaporates between renders.
//
// DECISIONS.md D9 specifies the derivation rules; these tests pin
// them so a future "small tweak" can't silently break replug
// stability.

import XCTest
@testable import ManifoldKit

final class IdentifierStabilityTests: XCTestCase {

    // MARK: - DeviceID determinism

    /// Identical inputs produce identical DeviceIDs. Boring but
    /// load-bearing — if this fails, every replug is an attach+detach.
    func test_deviceID_make_isDeterministic_forIdenticalInputs() {
        let a = DeviceID.make(vendorID: 0x046D, productID: 0xC52B, serial: "ABC", registryPath: "/path")
        let b = DeviceID.make(vendorID: 0x046D, productID: 0xC52B, serial: "ABC", registryPath: "/path")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.rawValue, b.rawValue)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    /// Lowercase hex per the wire-format contract — anyone reading the
    /// GRDB tables, the snapshot JSON, or the diagnostic event payloads
    /// can compare IDs without case-folding gymnastics.
    func test_deviceID_make_lowercaseHex() {
        let id = DeviceID.make(vendorID: 0xABCD, productID: 0x1234, serial: "S", registryPath: "/p")
        XCTAssertEqual(id.rawValue, "abcd:1234:S")
    }

    /// Zero-pad to 4 hex digits even for small VIDs/PIDs. A 3-digit
    /// VID would sort wrong in the GRDB index and would mismatch the
    /// canonical form the snapshot JSON uses.
    func test_deviceID_make_zeroPadsHexToFourDigits() {
        let id = DeviceID.make(vendorID: 0x0001, productID: 0x000A, serial: "S", registryPath: "/p")
        XCTAssertEqual(id.rawValue, "0001:000a:S")
    }

    /// When the serial is present, the registry path is ignored (the
    /// serial is a stronger identifier — survives replugging into a
    /// different port). Without this property a device unplugged from
    /// port A and replugged into port B would look like a new device.
    func test_deviceID_make_prefersSerialOverRegistryPath_whenBothPresent() {
        let serialID = DeviceID.make(vendorID: 0x0001, productID: 0x0001, serial: "SERIAL", registryPath: "/path-A")
        let movedID  = DeviceID.make(vendorID: 0x0001, productID: 0x0001, serial: "SERIAL", registryPath: "/path-B-different")
        XCTAssertEqual(serialID, movedID, "Same serial → same DeviceID across ports.")
    }

    /// When the serial is nil, the registry path becomes the suffix —
    /// gives us an ID that's at least stable while the device stays on
    /// the same port. Two no-serial devices on different ports correctly
    /// resolve as different DeviceIDs.
    func test_deviceID_make_fallsBackToRegistryPath_whenSerialNil() {
        let portA = DeviceID.make(vendorID: 0x0001, productID: 0x0001, serial: nil, registryPath: "/path-A")
        let portB = DeviceID.make(vendorID: 0x0001, productID: 0x0001, serial: nil, registryPath: "/path-B")
        XCTAssertNotEqual(portA, portB)
        XCTAssertEqual(portA.rawValue, "0001:0001:/path-A")
        XCTAssertEqual(portB.rawValue, "0001:0001:/path-B")
    }

    /// Two physically identical devices with no serial number plugged
    /// into the same port slot at different times produce the SAME
    /// DeviceID — accepted edge case per DECISIONS.md D9 ("two identical
    /// no-serial devices swapped between ports look like disconnect+connect").
    func test_deviceID_make_identicalNoSerialOnSamePort_collapsesToSameID() {
        let first  = DeviceID.make(vendorID: 0x0001, productID: 0x0001, serial: nil, registryPath: "/path")
        let second = DeviceID.make(vendorID: 0x0001, productID: 0x0001, serial: nil, registryPath: "/path")
        XCTAssertEqual(first, second)
    }

    // MARK: - PortID determinism

    /// PortID equality is direct rawValue equality — no derivation
    /// step that could drift. Pinning this so a future refactor can't
    /// silently introduce normalisation.
    func test_portID_equality_isExactRawValueMatch() {
        let a = PortID("IOService:/X/Y/Z")
        let b = PortID("IOService:/X/Y/Z")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    /// Different paths → different PortIDs. SwiftUI's diff machinery
    /// uses the ID's `hashValue` so divergent paths must produce
    /// different hashes (almost always, modulo astronomical chance).
    func test_portID_differentRawValues_areNotEqual() {
        let a = PortID("IOService:/X/Y/Z")
        let b = PortID("IOService:/X/Y/A")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - HostID determinism

    /// HostID is RawRepresentable<String>; same input → same ID.
    func test_hostID_equality_isExactRawValueMatch() {
        let a = HostID("00000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD")
        let b = HostID(rawValue: "00000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD")
        XCTAssertEqual(a, b)
    }
}
