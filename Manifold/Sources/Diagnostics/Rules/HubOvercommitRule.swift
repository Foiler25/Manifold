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
// HubOvercommitRule.swift
//
// SPEC §9 rule `hub-overcommit`. Fires when the sum of children's
// total power draw on a hub exceeds the hub's advertised budget
// (default 4.5 W per the USB 3.x spec — 900 mA at 5 V — when the
// hub doesn't advertise its own).
//
// SPEC trigger:
//   hub with sum(children.totalDraw) > advertised hub budget
//   (default 4.5W per USB 3.x)
//
// "Hub" in our model is a port whose connected device exists AND
// has children — a downstream-facing port with attached devices is
// by definition a hub or a hub-like TB device. We don't have a
// `DeviceKind.hub` case yet (Phase 8 adds the rule; Phase 11 adds
// the kind classifier when CoreUSB exposes hub-vs-device cleanly),
// so the structural-shape proxy ("any port with non-empty children")
// is the conservative read.
//
// `Port.availablePower` (the per-port budget the host advertises
// downstream) is what the hub-port itself was given by the host;
// for the hub-overcommit check we compare against `availablePower`
// when present, falling back to the 4.5 W USB 3 default. The
// fallback matches the SPEC "(default 4.5W per USB 3.x)" wording.

import Foundation
import ManifoldKit

struct HubOvercommitRule: DiagnosticRule {

    /// USB 3.x default hub budget per the spec: 900 mA × 5 V = 4.5 W.
    /// Used when the port doesn't publish a budget of its own.
    static let defaultUSB3HubBudget = Watts(4.5)

    let identifier = "hub-overcommit"
    var title: String {
        NSLocalizedString("diagnostic.hub-overcommit.title", comment: "Diagnostic title for hub overcommit.")
    }
    let defaultSeverity: DiagnosticSeverity = .warning

    func evaluate(against hosts: [ManifoldKit.Host]) -> [Diagnostic] {
        PortTreeWalker.allPorts(in: hosts).compactMap { port in
            guard
                port.connectedDevice != nil,
                !port.children.isEmpty
            else { return nil }

            // childrenTotal: sum of every descendant's draw (uses the
            // built-in `totalDraw` recursive sum on each child).
            let childrenTotalValue = port.children.reduce(0.0) { $0 + $1.totalDraw.value }
            let childrenTotal = Watts(childrenTotalValue)
            let budget = port.availablePower ?? Self.defaultUSB3HubBudget

            guard childrenTotal > budget else { return nil }

            let detail = String(
                format: NSLocalizedString(
                    "diagnostic.hub-overcommit.detail",
                    comment: "Detail. %1$@ children total formatted, %2$@ budget formatted."
                ),
                childrenTotal.formatted, budget.formatted
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
