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
// Constants.swift
//
// Phase 21 — named constants for the cable-diagnostics layer per
// builder.md "no magic numbers" rule. The provider's polling interval
// is internal to `CableDarwinProvider` (1s, hardcoded upstream), so
// the constants here are about Manifold-side UI/state.

import Foundation

enum CablesConstants {

    /// Cadence used by the absorbed `CableDarwinProvider.watch()` stream
    /// internally. Surfaced here so UI code (loading indicators, "last
    /// updated" labels) can derive expected refresh windows without
    /// hard-coding the same value twice.
    static let providerRefreshIntervalSeconds: Double = 1.0

    /// Intel-Mac empty-state heuristic. The absorbed provider returns an
    /// empty `ports` array on machines where the public IOKit USB-PD
    /// keys aren't present (Intel TB3 controllers per upstream README).
    /// `CablesView` uses this to pick between the "no cables plugged"
    /// and "Apple-Silicon-only" empty states.
    static let emptyPortsImpliesUnsupportedHostThreshold: Int = 0
}
