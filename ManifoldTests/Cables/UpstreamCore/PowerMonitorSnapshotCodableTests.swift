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
import Testing

struct PowerMonitorSnapshotCodableTests {

    @Test("Round-trips with the per-port metering capability bit")
    func roundTripsCapabilityBit() throws {
        let snapshot = PowerMonitorSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            systemSample: PowerSample(timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                                      systemVoltageIn: 5000, systemCurrentIn: 1000, systemPowerIn: 5000),
            portSamples: [],
            resistanceEstimate: nil,
            perPortMeteringSupported: true
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(PowerMonitorSnapshot.self, from: data)
        #expect(decoded.perPortMeteringSupported)
        #expect(decoded == snapshot)
    }

    @Test("Decodes a legacy snapshot missing newer keys without throwing")
    func decodesLegacyJSONWithDefaults() throws {
        // A snapshot as an older build would have encoded it: no perPortMetering
        // Supported, no hasContract, no battery fields. Must default, not throw.
        let legacy = """
        {
            "timestamp": 1700000000,
            "systemSample": { "timestamp": 1700000000, "systemVoltageIn": 0, "systemCurrentIn": 0, "systemPowerIn": 0 },
            "portSamples": []
        }
        """
        let decoded = try JSONDecoder().decode(PowerMonitorSnapshot.self, from: Data(legacy.utf8))
        #expect(decoded.perPortMeteringSupported == false)
        #expect(decoded.hasContract == false)
        #expect(decoded.externalConnected == true)   // desktop-friendly default
        #expect(decoded.batteryInstalled == false)
    }
}
