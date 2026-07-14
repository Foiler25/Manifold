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
// DisplayDiagnosticsModel.swift

import Foundation

struct DisplayDiagnosticsModel {
    struct Entry: Identifiable {
        let id: String
        let transport: IOPortTransportStateDisplayPort
        let diagnostic: DisplayDiagnostic
        let port: AppleHPMInterface?
    }

    let entries: [Entry]
    let hostSupported: Bool

    init(snapshot: CableSnapshot) {
        hostSupported = !snapshot.ports.isEmpty || !snapshot.displayPorts.isEmpty
        entries = snapshot.displayPorts.enumerated().compactMap { index, transport in
            guard transport.link.active else { return nil }
            let port = snapshot.ports.first { transport.canonicallyMatches(port: $0) }
            let identities = port.map { matched in
                snapshot.identities.filter { $0.canonicallyMatches(port: matched) }
            } ?? []
            let cable = identities.first {
                $0.endpoint == .sopPrime || $0.endpoint == .sopDoublePrime
            }
            let billboard = port?.hasBillboardDevice(among: snapshot.usbDevices) ?? false
            guard let diagnostic = DisplayDiagnostic(
                dp: transport,
                cable: cable,
                billboardPresent: billboard
            ) else { return nil }
            return Entry(
                id: "\(transport.portKey)-\(index)",
                transport: transport,
                diagnostic: diagnostic,
                port: port
            )
        }
    }
}
