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
// RetentionPolicy.swift
//
// Per SPEC §10.2. Defines:
//   - `SampleAggregation`: the three "buckets" telemetry samples
//     live in (raw / 1-min / 1-hour).
//   - `RetentionPolicy`: how long each bucket sticks around. Defaults
//     are 24h raw, 30d 1-min, 1y 1-hour.
//
// `Codable` so the HistoryPane settings UI can persist an override
// via @AppStorage; `Equatable` so SwiftUI re-renders only when the
// value really changes.

import Foundation

// MARK: - SampleAggregation

/// The three retention buckets. Stored as the `aggregation` column
/// value in `samples` per SPEC §10.1.
enum SampleAggregation: String, Sendable, Codable, CaseIterable {
    case raw
    case oneMin = "1min"
    case oneHour = "1hour"
}

// MARK: - RetentionPolicy

/// How long samples stick around per aggregation bucket. Default
/// values match SPEC §10.2.
struct RetentionPolicy: Sendable, Codable, Equatable {

    /// Keep raw 1-Hz samples this long. Default 24 hours.
    var rawRetention: TimeInterval = 86_400

    /// Keep 1-minute aggregates this long. Default 30 days.
    var oneMinRetention: TimeInterval = 2_592_000

    /// Keep 1-hour aggregates this long. Default 1 year (365 days).
    var oneHourRetention: TimeInterval = 31_536_000

    static let `default` = RetentionPolicy()

    /// Cutoff `Date` for the supplied bucket — sample timestamps
    /// older than this are eligible for the next downsampling step
    /// (raw → 1min → 1hour) and the bucket-specific delete sweep.
    func cutoffDate(for aggregation: SampleAggregation, now: Date = .now) -> Date {
        switch aggregation {
        case .raw:     return now.addingTimeInterval(-rawRetention)
        case .oneMin:  return now.addingTimeInterval(-oneMinRetention)
        case .oneHour: return now.addingTimeInterval(-oneHourRetention)
        }
    }
}
