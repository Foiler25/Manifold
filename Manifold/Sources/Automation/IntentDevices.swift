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
// IntentDevices.swift
//
// Shared host/port walking helpers used by GetConnectedDevicesIntent
// and GetPowerDrawIntent. Pulled out so each intent stays a thin
// wrapper around `IntentEnvironment.dataSource`.

import Foundation
import ManifoldKit

enum IntentDevices {

    /// Project every connected device to a `DeviceEntity`. Optional
    /// host filter narrows to one host's port tree.
    @MainActor
    static func collect(filteringByHost hostID: HostID?) -> [DeviceEntity] {
        guard let source = IntentEnvironment.dataSource else { return [] }
        var out: [DeviceEntity] = []
        for host in source.hosts {
            if let hostID, host.id != hostID { continue }
            walk(host.ports, into: &out)
        }
        return out
    }

    /// Sum `port.powerDraw` across every connected device, optionally
    /// scoped to a single host or a single device. Used by
    /// `GetPowerDrawIntent`.
    @MainActor
    static func totalDrawWatts(filteringByHost hostID: HostID?, deviceID: DeviceID?) -> Double {
        guard let source = IntentEnvironment.dataSource else { return 0 }
        var total: Double = 0
        for host in source.hosts {
            if let hostID, host.id != hostID { continue }
            sumDraw(host.ports, deviceID: deviceID, total: &total)
        }
        return total
    }

    // MARK: - Walkers

    private static func walk(_ ports: [ManifoldKit.Port], into out: inout [DeviceEntity]) {
        for port in ports {
            if let device = port.connectedDevice {
                out.append(DeviceEntity(device: device, powerDrawWatts: port.powerDraw?.value))
            }
            walk(port.children, into: &out)
        }
    }

    private static func sumDraw(_ ports: [ManifoldKit.Port], deviceID: DeviceID?, total: inout Double) {
        for port in ports {
            if let watts = port.powerDraw?.value {
                if let deviceID {
                    if port.connectedDevice?.id == deviceID { total += watts }
                } else {
                    total += watts
                }
            }
            sumDraw(port.children, deviceID: deviceID, total: &total)
        }
    }
}
