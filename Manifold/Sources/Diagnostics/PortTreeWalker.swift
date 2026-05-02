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
// PortTreeWalker.swift
//
// Internal helpers shared by every Phase-8 rule: the same DFS over
// `[Host] → [Port]` tree shape recurs in three rules. Lifting it
// here keeps each rule focused on its own predicate.
//
// Plain free functions, not a type — there's no state to carry, and
// `flatMap`-style composition reads more naturally than method calls.

import ManifoldKit

enum PortTreeWalker {

    /// Visit every port in `hosts` (including descendants). Order is
    /// pre-order DFS, hosts iterated in the order given.
    static func allPorts(in hosts: [ManifoldKit.Host]) -> [ManifoldKit.Port] {
        hosts.flatMap { allPorts(in: $0.ports) }
    }

    /// DFS over a `[Port]` slice. Pulled out so rules can recurse on
    /// a sub-tree (e.g., a hub's children) without re-routing through
    /// the host wrapper.
    static func allPorts(in ports: [ManifoldKit.Port]) -> [ManifoldKit.Port] {
        ports.flatMap { [$0] + allPorts(in: $0.children) }
    }

    /// Maximum depth of any branch rooted at `port`, counting `port`
    /// itself as depth 1. A leaf returns 1; one level of children
    /// returns 2; and so on. Used by `DaisyChainDepthRule`.
    static func depth(of port: ManifoldKit.Port) -> Int {
        1 + (port.children.map(depth(of:)).max() ?? 0)
    }
}
