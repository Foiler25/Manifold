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
// GetPowerDrawIntent.swift
//
// Per SPEC §11.2. Returns total power draw across the live graph,
// optionally scoped to a single host or single device. Returns
// `Measurement<UnitPower>` so Shortcuts users can plug the value
// into other automations (notify when > N watts, log to a file
// with units, etc.) without unit-confusion bugs.

import AppIntents
import Foundation
import ManifoldKit

struct GetPowerDrawIntent: AppIntent {

    static let title: LocalizedStringResource = "intent.getPowerDraw.title"
    static let description = IntentDescription(
        "intent.getPowerDraw.description"
    )

    @Parameter(title: "intent.parameter.filterByHost")
    var host: HostEntity?

    @Parameter(title: "intent.parameter.filterByDevice")
    var device: DeviceEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Measurement<UnitPower>> {
        let watts = IntentDevices.totalDrawWatts(filteringByHost: host?.hostID, deviceID: device?.deviceID)
        return .result(value: Measurement(value: watts, unit: UnitPower.watts))
    }
}
