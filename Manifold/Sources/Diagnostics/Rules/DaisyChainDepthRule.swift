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
// DaisyChainDepthRule.swift
//
// SPEC §9 rule `daisy-chain-depth`. Fires when the depth of any
// chain rooted at a host port exceeds Thunderbolt's spec maximum of
// 6 hops. Chains deeper than 6 produce undefined behavior under TB
// — usually one end-of-chain device randomly drops.
//
// SPEC trigger:
//   computed traversal depth > 6 from any port
//
// We measure depth from each host-rooted port: `PortTreeWalker.depth`
// returns 1 for a leaf, 2 for one level of children, etc. So "depth
// > 6" maps to "more than 6 ports stacked", matching the TB spec
// (host port + 6 daisy-chained devices).
//
// One emission per offending root port — emitting per-leaf would
// fire once for every device past the threshold and clutter the
// Diagnostics tab.

import Foundation
import ManifoldKit

struct DaisyChainDepthRule: DiagnosticRule {

    static let maxAllowedDepth = 6

    let identifier = "daisy-chain-depth"
    var title: String {
        NSLocalizedString("diagnostic.daisy-chain-depth.title", comment: "Diagnostic title for daisy-chain depth limit exceeded.")
    }
    let defaultSeverity: DiagnosticSeverity = .critical

    func evaluate(against hosts: [ManifoldKit.Host]) -> [Diagnostic] {
        hosts.flatMap { host in
            host.ports.compactMap { rootPort -> Diagnostic? in
                let depth = PortTreeWalker.depth(of: rootPort)
                guard depth > Self.maxAllowedDepth else { return nil }

                let detail = String(
                    format: NSLocalizedString(
                        "diagnostic.daisy-chain-depth.detail",
                        comment: "Detail. %1$lld depth, %2$lld TB max-allowed depth."
                    ),
                    depth, Self.maxAllowedDepth
                )
                return Diagnostic(
                    target: rootPort.id,
                    severity: defaultSeverity,
                    ruleIdentifier: identifier,
                    title: title,
                    detail: detail
                )
            }
        }
    }
}
