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
// NegotiationDiagnosticsModelTests.swift

import XCTest
@testable import Manifold

final class NegotiationDiagnosticsModelTests: XCTestCase {
    func testEmptySnapshotReportsUnsupportedHost() {
        let model = NegotiationDiagnosticsModel(snapshot: CableSnapshot())

        XCTAssertFalse(model.hostSupported)
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testBottlenecksMapToTheResponsibleCapabilityParty() {
        XCTAssertEqual(
            NegotiationDiagnosticsModel.Entry.weakParty(
                for: .hostLimit(hostGbps: 10, capableGbps: 20)
            ),
            .host
        )
        XCTAssertEqual(
            NegotiationDiagnosticsModel.Entry.weakParty(
                for: .cableLimit(cableGbps: 10, capableGbps: 40)
            ),
            .cable
        )
        XCTAssertEqual(
            NegotiationDiagnosticsModel.Entry.weakParty(for: .deviceLimit(deviceGbps: 5)),
            .device
        )
        XCTAssertEqual(
            NegotiationDiagnosticsModel.Entry.weakParty(for: .blockedBySecurity(signaledGbps: 40)),
            .security
        )
        XCTAssertNil(
            NegotiationDiagnosticsModel.Entry.weakParty(for: .fine(activeGbps: 40))
        )
    }
}
