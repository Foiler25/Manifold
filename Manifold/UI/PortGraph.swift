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
// PortGraph.swift
//
// `@MainActor @Observable` source of truth for every UI surface
// (popover, window, settings). Per SPEC.md §4.6 — though the SPEC
// comment suggests this type lives inside `MainWindow.swift` (Phase
// 6), giving it its own file in `Manifold/UI/` keeps the model/view
// separation honest. Phase 6 can relocate or keep, Builder's call.
//
// `@Observable` (not `ObservableObject`) so we don't pull in Combine.
// Property reads in any SwiftUI view are tracked automatically and
// re-render when the model mutates.
//
// `final class` not `actor` because the type is `@MainActor`-bound.
// Every consumer (`AppDelegate`, popover SwiftUI, future Phase 6
// window) is also MainActor; isolation alignment lets reads/writes
// be synchronous.

import Foundation
import ManifoldKit

@MainActor
@Observable
final class PortGraph {

    /// Every host we've discovered. Phase 2 always emits exactly one
    /// (the local Mac); the array shape is preserved for the future
    /// if remote-host support is ever added (explicitly out of scope
    /// per BRIEF.md, but the API doesn't preclude it).
    private(set) var hosts: [ManifoldKit.Host] = []

    /// Active diagnostics produced by the Phase 8 engine. Phase 2
    /// ships an empty list; Phase 8 starts populating it.
    private(set) var diagnostics: [Diagnostic] = []

    /// Wall-clock time of the last mutation. Used by the popover
    /// "last updated" affordance and as a monotonic test signal —
    /// `replace(hosts:diagnostics:)` and `apply(_:)` both bump it.
    private(set) var lastUpdated: Date = .now

    init() {}

    // MARK: - Mutation

    /// Replace the entire graph atomically. Called on initial walk,
    /// on `.fullRefresh`, and (Phase 14) when the user changes a
    /// setting that affects discovery filtering.
    ///
    /// `lastUpdated` advances on every replace even when the new
    /// content is identical to the old — useful as a "I tried to
    /// refresh" signal for tests and for any UI that wants to flash
    /// the "just synced" indicator.
    func replace(hosts: [ManifoldKit.Host], diagnostics: [Diagnostic] = []) {
        self.hosts = hosts
        self.diagnostics = diagnostics
        self.lastUpdated = .now
    }

    /// Apply one `PortEvent` to the model. Phase 2 implements the
    /// two cases the popover and the spec acceptance check exercise:
    ///
    ///   - `.fullRefresh` — bumps `lastUpdated`. The actual re-walk
    ///     is initiated by whichever component owns the
    ///     `DiscoveryService` (Phase 2: `AppDelegate`; Phase 3:
    ///     `EventService`). The model itself does not call IOKit.
    ///
    ///   - `.diagnostic(_)` — appends to `diagnostics` and bumps
    ///     `lastUpdated`. Lets Phase 8 land a working diagnostic flow
    ///     before Phase 3's EventService is ready to drive it.
    ///
    /// `.attached` / `.detached` / `.telemetry` are no-ops in Phase 2
    /// because their implementations require deeply-nested Port tree
    /// mutations that should be designed alongside Phase 3's event
    /// stream — hard-coding a partial pattern here would either lock
    /// in the wrong shape or be torn out next phase. Phase 3 will
    /// implement the full match-port-by-ID + insert/remove pass.
    func apply(_ event: PortEvent) {
        switch event {
        case .fullRefresh:
            lastUpdated = .now

        case .diagnostic(let diag):
            diagnostics.append(diag)
            lastUpdated = .now

        case .attached, .detached, .telemetry:
            // Phase 3 lands the per-port mutation logic. Until then
            // the only path that produces these events is Phase 5+
            // testing fixtures — none of which exist yet.
            break
        }
    }

    // MARK: - Convenience derivations

    /// Total connected device count across every host. Used by the
    /// Phase-1/2 popover header ("N devices connected") and by the
    /// Shortcut intent (Phase 12) that returns the same number.
    var totalDeviceCount: Int {
        hosts.reduce(0) { acc, host in
            acc + host.ports.reduce(0) { portAcc, port in
                portAcc + (port.connectedDevice == nil ? 0 : 1) + Self.descendantDeviceCount(of: port)
            }
        }
    }

    /// Recursive helper for `totalDeviceCount` — counts devices in
    /// any nested children Phase 7 starts populating.
    private static func descendantDeviceCount(of port: ManifoldKit.Port) -> Int {
        port.children.reduce(0) { acc, child in
            acc + (child.connectedDevice == nil ? 0 : 1) + descendantDeviceCount(of: child)
        }
    }
}
