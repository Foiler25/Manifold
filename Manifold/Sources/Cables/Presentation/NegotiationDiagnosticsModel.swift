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
// NegotiationDiagnosticsModel.swift

import Foundation

struct NegotiationDiagnosticsModel {
    enum CapabilityParty: Equatable {
        case host
        case cable
        case device
        case security
    }

    struct Entry: Identifiable {
        let port: AppleHPMInterface
        let diagnostic: DataLinkDiagnostic
        let sources: [PowerSource]
        let cableIdentity: USBPDSOP?
        let trmTransports: [TRMTransport]

        var id: UInt64 { port.id }
        var weakParty: CapabilityParty? {
            Self.weakParty(for: diagnostic.bottleneck)
        }
        var negotiatedWatts: Int? {
            guard let milliwatts = PowerSource.preferredChargingSource(in: sources)?.winning?.maxPowerMW,
                  milliwatts > 0 else { return nil }
            return Int((Double(milliwatts) / 1000).rounded())
        }
        var cableRatedWatts: Int? { cableIdentity?.cableVDO?.maxWatts }

        static func weakParty(for bottleneck: DataLinkDiagnostic.Bottleneck) -> CapabilityParty? {
            switch bottleneck {
            case .hostLimit: return .host
            case .cableLimit, .cableContradictsActive: return .cable
            case .deviceLimit: return .device
            case .blockedBySecurity: return .security
            case .fine, .degraded, .unknownCable: return nil
            }
        }
    }

    let entries: [Entry]
    let hostSupported: Bool

    var diagnosticsByPortKey: [String: DataLinkDiagnostic] {
        Self.valuesByPortKey(entries.compactMap { entry in
            entry.port.portKey.map { ($0, entry.diagnostic) }
        })
    }

    /// HPM registry services are keyed by registry ID, not display port key.
    /// On unusual controller layouts two services can therefore report the
    /// same portKey. Keep the first stable reading instead of using
    /// Dictionary(uniqueKeysWithValues:), which traps on that valid input.
    static func valuesByPortKey<Value>(_ values: [(String, Value)]) -> [String: Value] {
        values.reduce(into: [:]) { result, element in
            if result[element.0] == nil {
                result[element.0] = element.1
            }
        }
    }

    init(snapshot: CableSnapshot) {
        hostSupported = !snapshot.ports.isEmpty
        entries = snapshot.ports
            .filter { $0.connectionActive == true }
            .compactMap { port in
                let identities = snapshot.identities.filter { $0.canonicallyMatches(port: port) }
                let devices = port.matchingDevices(from: snapshot.usbDevices)
                let usb3 = snapshot.usb3Transports.filter { $0.canonicallyMatches(port: port) }
                let cio = snapshot.cioCapabilities.first { $0.canonicallyMatches(port: port) }
                guard let diagnostic = DataLinkDiagnostic(
                    port: port,
                    identities: identities,
                    devices: devices,
                    usb3Transports: usb3,
                    cio: cio,
                    thunderboltSwitches: snapshot.thunderboltSwitches
                ) else { return nil }
                return Entry(
                    port: port,
                    diagnostic: diagnostic,
                    sources: snapshot.powerSources.filter { $0.canonicallyMatches(port: port) },
                    cableIdentity: identities.first {
                        $0.endpoint == .sopPrime || $0.endpoint == .sopDoublePrime
                    },
                    trmTransports: snapshot.trmTransports.filter { $0.canonicallyMatches(port: port) }
                )
            }
    }
}
