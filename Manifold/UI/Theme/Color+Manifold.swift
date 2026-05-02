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
// Color+Manifold.swift
//
// Palette tokens per SPEC.md §13.4. Every color used in any view file
// in the app should reference one of these constants — Reviewer
// enforces "No hardcoded colors in views". The hex values come from
// BRIEF.md's Iconography section and define Manifold's visual identity:
//
//   - manifoldAccent (#00D67A): primary green for live data + active
//     affordances. Slightly punchier than ViewPorts' green.
//   - manifoldWarning (#F2A93B): amber for warning-severity diagnostics.
//   - manifoldCritical (#E5484D): red for critical-severity diagnostics.
//   - manifoldSurface (#0A0A0A): pure dark background for the popover
//     and standalone window.
//   - manifoldCard (#161616): card background, one step lighter than
//     surface for stacked content.
//   - manifoldText (#FFFFFF): default foreground.
//
// Phase 15 (Polish) may refine these into light/dark adaptive variants
// once the full theming pass happens. For Phase 4 we ship the dark
// values directly — the popover renders against the menu bar
// vibrancy, not a custom background, so dark-only is fine.

import SwiftUI
import ManifoldKit

extension Color {

    /// Primary brand accent — live data, active toggles, charts'
    /// primary line. `#00D67A` per BRIEF.md.
    static let manifoldAccent   = Color(manifoldHex: 0x00D67A)

    /// Warning severity — amber. `#F2A93B`.
    static let manifoldWarning  = Color(manifoldHex: 0xF2A93B)

    /// Critical severity — red. `#E5484D`.
    static let manifoldCritical = Color(manifoldHex: 0xE5484D)

    /// Surface background. `#0A0A0A`.
    static let manifoldSurface  = Color(manifoldHex: 0x0A0A0A)

    /// Card / elevated surface. `#161616`.
    static let manifoldCard     = Color(manifoldHex: 0x161616)

    /// Default foreground. `#FFFFFF`.
    static let manifoldText     = Color(manifoldHex: 0xFFFFFF)

    // MARK: - Severity helpers

    /// Map a `DiagnosticSeverity` to the Manifold palette. Centralised
    /// so badge / inline / banner views all agree on the color tier.
    /// Phase 8 adds the diagnostic engine that produces these severities;
    /// the helper exists now so Phase 4's host-header diagnostic count
    /// can already render in the right color.
    static func manifoldSeverity(_ severity: DiagnosticSeverity) -> Color {
        switch severity {
        case .info:     return .manifoldAccent
        case .warning:  return .manifoldWarning
        case .critical: return .manifoldCritical
        }
    }
}

// MARK: - Hex initializer

private extension Color {
    /// Construct a `Color` from a 24-bit RGB hex literal (`0xRRGGBB`).
    /// Internal-only — every color in `Color+Manifold` flows through
    /// this constructor; views never call it directly. The `manifoldHex`
    /// argument label is deliberately verbose so `Color(0x00D67A)`-style
    /// shortcuts elsewhere in the codebase fail to compile (they should
    /// use a named token from this file).
    init(manifoldHex hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

