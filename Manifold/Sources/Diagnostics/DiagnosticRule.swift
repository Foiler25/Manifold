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
// DiagnosticRule.swift
//
// Per SPEC.md §9. A rule is a pure function from current graph state
// to a (possibly empty) list of diagnostics. No mutation, no IO, no
// access to history — every input arrives via `evaluate(against:)`.
//
// Why pure: rules need to be trivially testable without spinning up
// IOKit, the event service, or any shared state. The Phase 8 acceptance
// requires three test cases per rule (positive / negative / edge); the
// pure-function shape lets each test feed in a hand-built `[Host]` and
// assert on the exact `[Diagnostic]` returned.

import Foundation
import ManifoldKit

/// One diagnostic rule. SPEC §9 contract; conformers live in
/// `Manifold/Sources/Diagnostics/Rules/`.
protocol DiagnosticRule: Sendable {

    /// Stable identifier ("running-at-usb-2"). Used by
    /// `PortGraph.applyDiagnostic` for dedup, by GRDB persistence, and
    /// by the Shortcuts intent that filters by rule. Must match the
    /// SPEC §9 table exactly.
    var identifier: String { get }

    /// Short human-readable headline ("Running @ USB 2.0"). The
    /// emitted `Diagnostic.title` echoes this verbatim — rules get
    /// ONE label, the badges and the Diagnostics tab share it.
    var title: String { get }

    /// Severity tier. Constant per rule (no rule downgrades itself
    /// between firings); the `Diagnostic` carries this through to
    /// the popover/tab colour-coding.
    var defaultSeverity: DiagnosticSeverity { get }

    /// Walk `hosts` and return zero or more diagnostics. Implementations
    /// MUST be:
    ///   - pure (no global state, no IO),
    ///   - safe to call concurrently from any actor,
    ///   - cheap enough to run on every graph rebuild (typical Mac:
    ///     ≤100 ports → micro-second budget).
    func evaluate(against hosts: [ManifoldKit.Host]) -> [Diagnostic]
}
