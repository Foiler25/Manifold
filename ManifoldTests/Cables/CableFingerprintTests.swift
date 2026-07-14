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
// CableFingerprintTests.swift

import XCTest
@testable import Manifold

final class CableFingerprintTests: XCTestCase {
    func testKeyIsStableHexAndIndependentOfPort() {
        let first = identity(port: 1)
        let second = identity(port: 4)

        XCTAssertEqual(CableIdentity.key(for: first), "1234:ABCD:11223344")
        XCTAssertEqual(CableIdentity.key(for: first), CableIdentity.key(for: second))
    }

    func testZeroVendorOrProductCannotBePersisted() {
        XCTAssertNil(CableIdentity.key(for: identity(vendorID: 0)))
        XCTAssertNil(CableIdentity.key(for: identity(productID: 0)))
    }

    private func identity(
        vendorID: Int = 0x1234,
        productID: Int = 0xABCD,
        port: Int = 1
    ) -> USBPDSOP {
        USBPDSOP(
            id: UInt64(port),
            endpoint: .sopPrime,
            parentPortType: 2,
            parentPortNumber: port,
            vendorID: vendorID,
            productID: productID,
            bcdDevice: 0x0100,
            vdos: [0, 0, 0, 0x1122_3344],
            specRevision: 0
        )
    }
}
