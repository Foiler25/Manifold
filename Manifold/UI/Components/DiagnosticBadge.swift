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
// DiagnosticBadge.swift
//
// Inline severity pill rendered next to a `PortRow` when one or more
// diagnostics target that port. Per SPEC §18 Phase 8: "Active
// diagnostics render inline in popover (red/amber badges)".
//
// One row per diagnostic — kept compact (icon + title only) so the
// popover row doesn't grow unbounded when a port has multiple rules
// firing. The Diagnostics tab in the main window shows the full
// detail string; the badge is the at-a-glance signal.

import SwiftUI
import ManifoldKit

struct DiagnosticBadge: View {

    let diagnostic: Diagnostic

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: severityIcon)
                .font(.caption2.weight(.semibold))
            Text(diagnostic.title)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(Color.manifoldSeverity(diagnostic.severity))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(Color.manifoldSeverity(diagnostic.severity).opacity(0.15))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(severityAccessibilityPrefix) \(diagnostic.title)")
    }

    private var severityIcon: String {
        switch diagnostic.severity {
        case .info:     return "info.circle.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }

    /// Spoken severity prefix so VO reads "Warning, Running @ USB 2.0"
    /// rather than just the title (which loses the urgency).
    private var severityAccessibilityPrefix: String {
        switch diagnostic.severity {
        case .info:     return NSLocalizedString("popover.diagnostic.severity.info",     comment: "VO prefix for an info diagnostic.")
        case .warning:  return NSLocalizedString("popover.diagnostic.severity.warning",  comment: "VO prefix for a warning diagnostic.")
        case .critical: return NSLocalizedString("popover.diagnostic.severity.critical", comment: "VO prefix for a critical diagnostic.")
        }
    }
}

#Preview("DiagnosticBadge — warning") {
    DiagnosticBadge(diagnostic: PreviewData.runningAtUSB2Warning)
        .padding()
        .background(Color.manifoldSurface)
}
