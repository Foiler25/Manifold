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
// Portions of this file derive from WhatCable
// (https://github.com/darrylmorley/whatcable) by Darryl Morley,
// originally distributed under the MIT licence. See
// `Manifold/Sources/Cables/ATTRIBUTION.md` for the full original
// copyright + permission notice.
//
// ─────────────────────────────────────────────────────────────────────
// CableSnapshotProvider.swift
//
// Protocol that abstracts cable / port / power IOKit reading from its
// consumer. `CableEngine` owns one of these and binds the UI to its
// `watch()` stream — the concrete `CableDarwinProvider` is the only
// implementation today, but the seam keeps `CableEngine` testable
// without touching IOKit (see `CableEngineTests` for the fake).

import Foundation

/// Platform backends conform to this. UI code binds to the protocol,
/// not to a concrete watcher class.
///
/// `watch()` semantics:
/// - Emits an initial snapshot immediately.
/// - After that, emits only when the snapshot actually changes.
/// - Cancellation tears down underlying IOKit notifications and timers
///   via the stream's `onTermination` handler.
/// - Errors finish the stream; backends must not retry silently.
public protocol CableSnapshotProvider: Sendable {
    func snapshot() async throws -> CableSnapshot
    func watch() -> AsyncThrowingStream<CableSnapshot, Error>
}
