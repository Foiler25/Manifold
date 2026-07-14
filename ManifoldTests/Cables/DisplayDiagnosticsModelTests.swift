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
// DisplayDiagnosticsModelTests.swift

import XCTest
@testable import Manifold

final class DisplayDiagnosticsModelTests: XCTestCase {
    func testActiveDisplayWithoutModeDataProducesHonestUnknownEntry() {
        let snapshot = CableSnapshot(
            ports: [], powerSources: [], identities: [], usbDevices: [], adapter: nil,
            displayPorts: [makeTransport(active: true)]
        )

        let model = DisplayDiagnosticsModel(snapshot: snapshot)

        XCTAssertTrue(model.hostSupported)
        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.entries.first?.diagnostic.bottleneck, .unknownMode)
        XCTAssertNil(model.entries.first?.port)
    }

    func testInactiveDisplayLinksAreNotPresented() {
        let snapshot = CableSnapshot(
            ports: [], powerSources: [], identities: [], usbDevices: [], adapter: nil,
            displayPorts: [makeTransport(active: false)]
        )

        let model = DisplayDiagnosticsModel(snapshot: snapshot)

        XCTAssertTrue(model.hostSupported)
        XCTAssertTrue(model.entries.isEmpty)
    }

    private func makeTransport(active: Bool) -> IOPortTransportStateDisplayPort {
        IOPortTransportStateDisplayPort(
            link: DisplayPortLink(
                active: active,
                laneCount: 4,
                maxLaneCount: 4,
                linkRate: 8_100,
                linkRateDescription: "HBR3 (8.1 Gbps/lane)",
                tunneled: false,
                hpdState: active ? 1 : 0
            ),
            monitor: nil,
            parentPortType: 2,
            parentPortNumber: 1
        )
    }
}
