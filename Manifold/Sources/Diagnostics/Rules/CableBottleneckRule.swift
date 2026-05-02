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
// CableBottleneckRule.swift
//
// SPEC §9 rule `cable-bottleneck`. Fires when a Thunderbolt 4
// device is currently linked at TB3 — usually because the user is
// using a passive TB3 cable on a TB4 port. The protocol negotiates
// down silently; the user sees half the bandwidth they expected.
//
// SPEC trigger:
//   TB4 device with `IOThunderboltLinkType == TB3`
//
// We don't have a "TB-version" enum on `Device` (TB devices use
// `Device.usbVersion = nil`), so the "TB4 device" half of the check
// reads from the snapshot-time link properties: a TB4-capable device
// would have negotiated `Thunderbolt 4` if both ends supported it,
// so a `Thunderbolt 3` negotiation on a port whose `kind ==
// .thunderbolt` is already evidence of a downgrade. Phase 8 ships
// the conservative version: `kind == .thunderbolt && protocolName ==
// "Thunderbolt 3"`. False positives are devices that genuinely max
// out at TB3 (still useful info — the user can confirm). Phase 11+
// can refine when CoreDevice surfaces "max supported speed."

import Foundation
import ManifoldKit

struct CableBottleneckRule: DiagnosticRule {

    let identifier = "cable-bottleneck"
    var title: String {
        NSLocalizedString("diagnostic.cable-bottleneck.title", comment: "Diagnostic title for TB4 device on TB3 link.")
    }
    let defaultSeverity: DiagnosticSeverity = .warning

    func evaluate(against hosts: [ManifoldKit.Host]) -> [Diagnostic] {
        PortTreeWalker.allPorts(in: hosts).compactMap { port in
            guard
                port.kind == .thunderbolt,
                let device = port.connectedDevice,
                let negotiated = port.negotiated,
                negotiated.protocolName == "Thunderbolt 3"
            else { return nil }

            let detail = String(
                format: NSLocalizedString(
                    "diagnostic.cable-bottleneck.detail",
                    comment: "Detail. %1$@ device name."
                ),
                device.name
            )
            return Diagnostic(
                target: port.id,
                severity: defaultSeverity,
                ruleIdentifier: identifier,
                title: title,
                detail: detail
            )
        }
    }
}
