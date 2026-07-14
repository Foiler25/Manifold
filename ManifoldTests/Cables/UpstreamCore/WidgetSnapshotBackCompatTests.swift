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
// Portions of this file derive from WhatCable
// (https://github.com/darrylmorley/whatcable) by Darryl Morley,
// originally distributed under the MIT licence. See
// `Manifold/Sources/Cables/ATTRIBUTION.md` for the full original
// copyright + permission notice.
//
// ─────────────────────────────────────────────────────────────────────
@testable import Manifold
import Foundation
import XCTest

final class WidgetSnapshotBackCompatTests: XCTestCase {
    func testDecodesPrePowerStateSnapshot() throws {
        let json = """
        {
            "ports": [
                {
                    "id": 1,
                    "portName": "USB-C Port 1",
                    "status": "charging",
                    "headline": "Charging - 96W charger",
                    "subtitle": "Power is flowing.",
                    "topBullet": "Charger advertises up to 96W",
                    "iconName": "bolt.fill",
                    "deviceCount": 0,
                    "recentPower": [12.5, 13.0]
                },
                {
                    "id": 2,
                    "portName": "USB-C Port 2",
                    "status": "empty",
                    "headline": "Nothing connected",
                    "subtitle": "Plug a cable in.",
                    "iconName": "powerplug"
                }
            ],
            "timestamp": 738835200.0
        }
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: json)

        XCTAssertEqual(snapshot.ports.count, 2)
        XCTAssertNil(snapshot.powerState)

        let port1 = snapshot.ports[0]
        XCTAssertEqual(port1.id, 1)
        XCTAssertEqual(port1.portName, "USB-C Port 1")
        XCTAssertEqual(port1.status, .charging)
        XCTAssertEqual(port1.headline, "Charging - 96W charger")
        XCTAssertEqual(port1.deviceCount, 0)
        XCTAssertEqual(port1.recentPower, [12.5, 13.0])
        XCTAssertNil(port1.portKey)
        XCTAssertNil(port1.chargerWatts)
        // Fields added after this JSON was written must default to nil.
        XCTAssertNil(port1.linkSpeed)
        XCTAssertNil(port1.displayMode)
        XCTAssertNil(port1.monitorName)
        XCTAssertEqual(port1.displayCount, 0)

        let port2 = snapshot.ports[1]
        XCTAssertEqual(port2.id, 2)
        XCTAssertEqual(port2.status, .empty)
        XCTAssertEqual(port2.deviceCount, 0)
        XCTAssertEqual(port2.recentPower, [])
        XCTAssertNil(port2.portKey)
        XCTAssertNil(port2.chargerWatts)
    }

    func testDecodesSnapshotWithLinkSpeedAndDisplay() throws {
        let json = """
        {
            "ports": [
                {
                    "id": 1,
                    "portName": "USB-C Port 1",
                    "status": "displayCable",
                    "headline": "Display connected",
                    "subtitle": "DisplayPort video over USB-C Alt Mode.",
                    "iconName": "display",
                    "linkSpeed": { "tier": "tb40", "badge": "40G" },
                    "displayMode": "5K 60Hz",
                    "monitorName": "Studio Display"
                }
            ],
            "timestamp": 738835200.0
        }
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: json)
        let port = try XCTUnwrap(snapshot.ports.first)
        XCTAssertEqual(port.linkSpeed?.tier, .tb40)
        XCTAssertEqual(port.linkSpeed?.badge, "40G")
        XCTAssertEqual(port.displayMode, "5K 60Hz")
        XCTAssertEqual(port.monitorName, "Studio Display")
    }

    func testDecodesSnapshotWithPowerState() throws {
        let json = """
        {
            "ports": [
                {
                    "id": 1,
                    "portName": "USB-C Port 1",
                    "status": "charging",
                    "headline": "Charging",
                    "subtitle": "Power is flowing.",
                    "iconName": "bolt.fill",
                    "portKey": "2/1",
                    "chargerWatts": 96
                }
            ],
            "timestamp": 738835200.0,
            "powerState": {
                "batteryPercent": 78,
                "isCharging": true,
                "fullyCharged": false,
                "isDesktopMac": false,
                "adapterWatts": 96,
                "adapterDescription": "pd charger"
            }
        }
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: json)

        XCTAssertEqual(snapshot.ports.count, 1)
        XCTAssertEqual(snapshot.ports[0].portKey, "2/1")
        XCTAssertEqual(snapshot.ports[0].chargerWatts, 96)

        let power = try XCTUnwrap(snapshot.powerState)
        XCTAssertEqual(power.batteryPercent, 78)
        XCTAssertTrue(power.isCharging)
        XCTAssertFalse(power.fullyCharged)
        XCTAssertFalse(power.isDesktopMac)
        XCTAssertEqual(power.adapterWatts, 96)
        XCTAssertEqual(power.adapterDescription, "pd charger")
        XCTAssertNil(power.systemPowerInWatts)
        XCTAssertNil(power.perPortWatts)
        XCTAssertEqual(power.recentSystemPower, [])
    }
}
