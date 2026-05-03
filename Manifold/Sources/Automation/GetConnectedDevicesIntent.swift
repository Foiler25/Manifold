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
// GetConnectedDevicesIntent.swift
//
// Per SPEC §11.2. Returns every connected device across every host,
// optionally filtered to a single host via the `host:` parameter.

import AppIntents
import ManifoldKit

struct GetConnectedDevicesIntent: AppIntent {

    static let title: LocalizedStringResource = "intent.getConnectedDevices.title"
    static let description = IntentDescription(
        "intent.getConnectedDevices.description"
    )

    @Parameter(title: "intent.parameter.filterByHost")
    var host: HostEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[DeviceEntity]> {
        let entities = IntentDevices.collect(filteringByHost: host?.hostID)
        return .result(value: entities)
    }
}
