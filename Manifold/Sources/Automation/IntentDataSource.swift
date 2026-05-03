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
// IntentDataSource.swift
//
// Bridge between the AppIntents `perform()` runtime — which needs
// MainActor access to live model state — and `AppDelegate`'s owned
// services. AppIntents are constructed by the system, so we can't
// hand them a `PortGraph` reference at init time; the standard
// pattern is a process-wide accessor.
//
// Test-friendly via the protocol: production wires
// `LiveIntentDataSource(...)` from AppDelegate; tests inject a
// stub that returns canned data.

import Foundation
import ManifoldKit

@MainActor
protocol IntentDataSource {
    /// Live host snapshot. Empty array when no walks have completed
    /// yet (cold launch).
    var hosts: [ManifoldKit.Host] { get }

    /// Active diagnostics (`PortGraph.diagnostics`).
    var diagnostics: [Diagnostic] { get }

    /// Most-recent N persisted events for the watcher intent. nil
    /// when persistence init failed (Phase 10 silent-disable).
    func recentEvents(limit: Int) async throws -> [StoredEvent]
}

/// Production data source: thin wrapper over the AppDelegate's
/// `PortGraph` and `EventRepository`. AppDelegate constructs one
/// at boot and registers it as `IntentEnvironment.shared`.
@MainActor
final class LiveIntentDataSource: IntentDataSource {

    private let graph: PortGraph
    private let eventRepository: EventRepository?

    init(graph: PortGraph, eventRepository: EventRepository?) {
        self.graph = graph
        self.eventRepository = eventRepository
    }

    var hosts: [ManifoldKit.Host] { graph.hosts }
    var diagnostics: [Diagnostic] { graph.diagnostics }

    func recentEvents(limit: Int) async throws -> [StoredEvent] {
        guard let eventRepository else { return [] }
        return try await eventRepository.recentEvents(limit: limit)
    }
}

// MARK: - Process-wide registration

/// `MainActor`-isolated registry of the live intent data source.
/// Empty until `AppDelegate.applicationDidFinishLaunching` populates
/// it. Intents read via `IntentEnvironment.dataSource` and throw a
/// localized error when the bridge isn't ready (e.g., the system
/// invoked an intent before app launch completed).
///
/// `enum` instead of `final class` because we never instantiate;
/// the static stored property carries the only state.
@MainActor
enum IntentEnvironment {

    /// Live source. nil until set by AppDelegate.
    static var dataSource: (any IntentDataSource)?
}
