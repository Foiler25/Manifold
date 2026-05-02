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
// ManifoldKit.swift
//
// Module-level metadata for ManifoldKit. The data types (Host, Port,
// Device, Diagnostic, Snapshot codec, …) live alongside in
// `Sources/Models/`; this file only carries the module info constants.
//
// Why the namespace is `ManifoldKitInfo` and not `ManifoldKit`: the
// module itself is named `ManifoldKit`, and a top-level type with that
// same name shadows the module qualifier. After Phase 2 introduced the
// `Port` type, `ManifoldKit.Port` started resolving to the enum (which
// has no `Port` member) instead of the module's struct. Renaming the
// enum to `ManifoldKitInfo` keeps `ManifoldKit.Port` resolving to the
// real type for any caller (including tests) that needs to disambiguate
// from `Foundation.Port` (the old NSPort wrapper).

/// Module-level namespace for ManifoldKit metadata. Caseless enum so
/// it can never be instantiated — pure container for module info.
public enum ManifoldKitInfo {

    /// SPEC.md revision this module's types correspond to.
    ///
    /// Bumped by the Builder whenever the data model lands an update
    /// callers should care about. Phase 2 shipped the full §4 type
    /// set against SPEC rev 3; SPEC rev 4 added §4.6.1 (PortGraph
    /// mutation pattern) without altering the data types themselves.
    /// Bumped to 4 in Phase 6 to keep the sentinel current with the
    /// SPEC's published revision (per Reviewer F3).
    public static let specRevision: Int = 4
}
