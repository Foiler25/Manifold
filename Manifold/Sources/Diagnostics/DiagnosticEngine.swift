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
// DiagnosticEngine.swift
//
// Thin coordinator between `AppDelegate.rebuildGraph` and
// `DiagnosticRegistry`. Owns the registry lifecycle, exposes one
// entry point (`diagnostics(for:)`) the consumer calls between the
// discovery walk and the `PortGraph.replace(hosts:diagnostics:)`
// commit.
//
// Why a thin wrapper over `DiagnosticRegistry.evaluateAll` rather
// than calling it directly: keeps the boot-time wiring honest. The
// engine instance is owned by `AppDelegate`, so future Phase 9+ work
// (fire diagnostics over UNUserNotificationCenter, debounce
// state-change-driven re-evaluations, etc.) has a natural home.

import Foundation
import ManifoldKit

@MainActor
final class DiagnosticEngine {

    let registry: DiagnosticRegistry

    init(registry: DiagnosticRegistry = .phase8Registry()) {
        self.registry = registry
    }

    /// Evaluate every registered rule against `hosts` and return the
    /// concatenated diagnostics list. Caller passes the result into
    /// `PortGraph.replace(hosts:diagnostics:)`.
    func diagnostics(for hosts: [ManifoldKit.Host]) -> [Diagnostic] {
        registry.evaluateAll(against: hosts)
    }
}
