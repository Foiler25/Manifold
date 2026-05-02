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
// PowerDeficitRule.swift
//
// SPEC §9 rule `power-deficit`. Fires when a port advertises an
// available-current budget AND the connected device's requested
// power exceeds it. The user-visible failure mode this catches: a
// bus-powered drive draws more than the port can supply, the drive
// keeps disconnecting under load, the user has no idea why — a
// diagnostic pointing at the port + the deficit closes that loop.
//
// SPEC trigger:
//   device.requestedPower > port.availablePower
//
// `Port.availablePower` is nil when the port doesn't publish a
// budget; per the comment on `Port.availablePower` ("absent budget
// → infinite, skip firing") we no-op in that case.
//
// "requestedPower" lives on the port (`Port.powerDraw`) in our model
// — the device descriptor's `bMaxPower` is what
// `PortGraphBuilder.makePort` converts and stores there. SPEC's prose
// says "device.requestedPower"; the model wires it through the port,
// so reading `port.powerDraw` gives us the device-requested value.

import Foundation
import ManifoldKit

struct PowerDeficitRule: DiagnosticRule {

    let identifier = "power-deficit"
    var title: String {
        NSLocalizedString("diagnostic.power-deficit.title", comment: "Diagnostic title for power deficit.")
    }
    let defaultSeverity: DiagnosticSeverity = .critical

    func evaluate(against hosts: [ManifoldKit.Host]) -> [Diagnostic] {
        PortTreeWalker.allPorts(in: hosts).compactMap { port in
            guard
                let device = port.connectedDevice,
                let requested = port.powerDraw,
                let budget = port.availablePower,
                requested > budget
            else { return nil }

            let detail = String(
                format: NSLocalizedString(
                    "diagnostic.power-deficit.detail",
                    comment: "Detail. %1$@ device, %2$@ requested formatted, %3$@ available formatted."
                ),
                device.name, requested.formatted, budget.formatted
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
