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
// Diagnostic.swift
//
// One actionable observation produced by the diagnostics engine
// (Phase 8). Per SPEC.md §4.4. Phase 2 ships the type so the rest of
// the model is self-contained; Phase 8 introduces the rules that
// produce these.

public import Foundation

// MARK: - DiagnosticSeverity

/// Three-level severity. Drives the popover badge colour
/// (info=accent, warning=amber, critical=red — see BRIEF.md
/// Iconography palette) and the notification routing (Phase 9 may
/// suppress info-level toasts).
public enum DiagnosticSeverity: String, Sendable, Codable, CaseIterable {
    case info, warning, critical
}

// MARK: - Diagnostic

public struct Diagnostic: Identifiable, Hashable, Sendable, Codable {

    /// Unique per-emission identifier. A rule firing twice for the
    /// same condition produces two diagnostics with different IDs but
    /// the same `ruleIdentifier` + `target`.
    public let id: UUID

    /// Port the diagnostic is about. Diagnostics targeting the host
    /// itself (Phase 8's daisy-chain depth rule) use the host's
    /// root-most port ID.
    public let target: PortID

    /// Severity tier — see `DiagnosticSeverity`.
    public let severity: DiagnosticSeverity

    /// Stable rule identifier ("running-at-usb-2", "power-deficit",
    /// "cable-bottleneck", …). Used for dedup, persistence, and the
    /// Shortcuts intent that filters diagnostics by rule.
    public let ruleIdentifier: String

    /// Short headline for the popover badge / notification title:
    /// "Running @ USB 2.0", "Power deficit", "TB4 device on TB3 link".
    public let title: String

    /// One- or two-sentence explanation for the inspector pane and
    /// notification body: "Device supports USB 3.0 but is on a USB
    /// 2.0 link — check the cable or hub upstream."
    public let detail: String

    /// Wall-clock time the rule fired. Persisted to GRDB so the
    /// History view can show diagnostic timelines.
    public let triggeredAt: Date

    public init(
        id: UUID = UUID(),
        target: PortID,
        severity: DiagnosticSeverity,
        ruleIdentifier: String,
        title: String,
        detail: String,
        triggeredAt: Date = .now
    ) {
        self.id = id
        self.target = target
        self.severity = severity
        self.ruleIdentifier = ruleIdentifier
        self.title = title
        self.detail = detail
        self.triggeredAt = triggeredAt
    }
}
