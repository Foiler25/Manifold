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
// DiagnosticRegistry.swift
//
// Per SPEC.md §9. Holds the registered rules and runs them all in
// `evaluateAll(against:)`. @MainActor so registration and evaluation
// share isolation with `PortGraph` (the only consumer in Phase 8 —
// `AppDelegate.rebuildGraph` calls evaluateAll then PortGraph.replace
// in one MainActor hop).
//
// Why a class (not a struct): the registration step happens during
// app boot once, and tests want to share the boot-time registry with
// the engine. A struct would force every test to re-register.

import Foundation
import ManifoldKit

@MainActor
final class DiagnosticRegistry {

    private(set) var rules: [any DiagnosticRule] = []

    init() {}

    /// Append a rule. No de-duplication (SPEC doesn't mandate it; if
    /// a rule with the same identifier is registered twice the engine
    /// will evaluate it twice and PortGraph.applyDiagnostic will
    /// dedupe by `(target, ruleIdentifier)`). The plain-array shape
    /// preserves registration order so rule output is deterministic
    /// across runs.
    func register(_ rule: any DiagnosticRule) {
        rules.append(rule)
    }

    /// Run every rule against `hosts` and return the concatenated
    /// diagnostics list. Order matches registration order, then
    /// per-rule emission order. Caller is expected to dedupe via
    /// `PortGraph.applyDiagnostic` (which keys on
    /// `(target, ruleIdentifier)`).
    func evaluateAll(against hosts: [ManifoldKit.Host]) -> [Diagnostic] {
        rules.flatMap { $0.evaluate(against: hosts) }
    }

    /// Convenience for `AppDelegate` boot: register the SPEC §9 rule
    /// set in the canonical order. Tests that want a custom subset
    /// instantiate `DiagnosticRegistry` directly and call `register`
    /// per-rule.
    static func phase8Registry() -> DiagnosticRegistry {
        let registry = DiagnosticRegistry()
        registry.register(USB2OnUSB3DeviceRule())
        registry.register(PowerDeficitRule())
        registry.register(CableBottleneckRule())
        registry.register(DaisyChainDepthRule())
        registry.register(HubOvercommitRule())
        return registry
    }
}
