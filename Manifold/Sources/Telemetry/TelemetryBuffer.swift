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
// TelemetryBuffer.swift
//
// Per SPEC.md §8: fixed-capacity ring buffer of `TelemetrySample`,
// default capacity 60. Used by `PortGraph.telemetryHistory` to back
// each port's sparkline.
//
// Why an Array-backed ring instead of a `Deque` (`swift-collections`):
// 60 elements is tiny; the `removeFirst()` shift is O(60), dominated
// by the 1 Hz sampler tick — measured cost in nanoseconds per
// DECISIONS.md D7. Adding swift-collections for one type is not worth
// a dependency.

import Foundation
import ManifoldKit

struct TelemetryBuffer: Sendable {

    /// Maximum samples retained. The newest replaces the oldest once
    /// full.
    let capacity: Int

    /// Backing storage. `private(set)` so views can read directly
    /// (the sparkline iterates `samples` in insertion order).
    private(set) var samples: [TelemetrySample]

    init(capacity: Int = TelemetryBufferConstants.defaultCapacity) {
        // `precondition` rather than `assert` because a zero/negative
        // capacity would silently produce a buffer that never retains
        // anything — that's a programming bug worth crashing on in
        // any build configuration.
        precondition(capacity > 0, "TelemetryBuffer capacity must be positive")
        self.capacity = capacity
        self.samples = []
        self.samples.reserveCapacity(capacity)
    }

    /// Append `sample`; drop the oldest if at capacity. O(capacity)
    /// in the rotation case, O(1) otherwise. Mutating because Swift's
    /// value semantics + COW give us free reuse when no one else is
    /// reading.
    mutating func append(_ sample: TelemetrySample) {
        if samples.count >= capacity {
            samples.removeFirst()
        }
        samples.append(sample)
    }

    /// Most recent sample, or nil for an empty buffer.
    var latest: TelemetrySample? {
        samples.last
    }
}

/// Magic numbers for the telemetry buffer live here per builder.md
/// "no magic numbers" rule.
enum TelemetryBufferConstants {
    /// SPEC §8: "Capacity = 60 by default." 60 samples at 1 Hz ≈ one
    /// minute of history, which is what the popover sparkline shows.
    static let defaultCapacity: Int = 60
}
