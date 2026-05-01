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
// Log.swift
//
// Centralised `os.Logger` access for the app. Two reasons to wrap
// `Logger` rather than instantiate it inline at every call site:
//
//   1. The subsystem string ("com.Loofa.Manifold") is the identifier
//      `Console.app` shows for our process. Defining it once keeps every
//      log line filterable as a single bucket.
//   2. Categories sort our log lines by subsystem area (discovery,
//      events, telemetry, …), which matters once Phase 3 starts emitting
//      hot-plug events at sub-second cadence and Console becomes the
//      only practical way to debug them.

import Foundation
import os

/// Namespace for project-wide logging. Caseless enum — there's nothing
/// to instantiate.
enum Log {

    /// Subsystem identifier shown in Console.app. Matches the bundle ID
    /// so filtering by "com.Loofa.Manifold" surfaces every log line
    /// regardless of category.
    static let subsystem = "com.Loofa.Manifold"

    /// Category for the IORegistry walks (USB / TB / displays). Phase 1
    /// is the first user; later phases add `events`, `telemetry`,
    /// `diagnostics`, etc. as siblings.
    static let discovery = Logger(subsystem: subsystem, category: "discovery")

    /// Category for app-level lifecycle (launch, NSStatusItem install,
    /// popover open/close).
    static let app = Logger(subsystem: subsystem, category: "app")
}
