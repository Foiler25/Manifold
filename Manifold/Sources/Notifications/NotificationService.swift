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
// NotificationService.swift
//
// Phase 9. Owns:
//   - One-shot `UNUserNotificationCenter.requestAuthorization` on
//     first run (per SPEC §18 Phase 9 #1; tracked via
//     `NotificationPreferences.didRequestAuthorization`).
//   - `handle(_:graph:)` entry point — converts a `PortEvent` to
//     a `UNNotificationRequest` via the builder + posts it.
//   - Honoring the per-event-type toggles (delegated to the builder).
//
// Why a separate consumer task isn't used: the service's `handle`
// is called synchronously from `AppDelegate.handle(event:)` BEFORE
// `portGraph.apply(event)`. This ordering is what lets a `.detached`
// notification still resolve the device's name from the graph (the
// pre-apply graph still contains the device). The cost is that
// `handle` blocks the consumer task briefly while the UN request
// is enqueued (UN's `add` is async-throws but cheap — we fire it
// from a Task to avoid awaiting in the hot path).
//
// Do-Not-Disturb / Focus modes are honored automatically by macOS —
// no app-side opt-in needed (per SPEC §18 Phase 9 #5). The system
// inspects active focus modes when delivering each request.

import Foundation
import UserNotifications
import os
import ManifoldKit

@MainActor
final class NotificationService {

    private var preferences: NotificationPreferences
    private let center: UNUserNotificationCenter

    init(
        preferences: NotificationPreferences = NotificationPreferences(),
        center: UNUserNotificationCenter = .current()
    ) {
        self.preferences = preferences
        self.center = center
    }

    // MARK: - Authorization

    /// Request alert + sound authorization once per install. Idempotent
    /// on the OS side (calling twice doesn't re-prompt — macOS just
    /// returns the existing decision), but we gate via
    /// `didRequestAuthorization` so we don't spam the API.
    ///
    /// Errors are logged + swallowed: notifications are a best-effort
    /// feature, and the app must run regardless of whether the user
    /// granted permission. The next launch's `handle(_:graph:)` calls
    /// will silently no-op if permission was denied (the OS drops the
    /// request).
    func requestAuthorizationIfNeeded() async {
        guard !preferences.didRequestAuthorization else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
            preferences.didRequestAuthorization = true
        } catch {
            Log.app.error("Notification authorization request failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Event handling

    /// Convert one `PortEvent` to a `UNNotificationRequest` and
    /// enqueue it. Called synchronously from `AppDelegate.handle`
    /// BEFORE `portGraph.apply(event)` so the builder's `hosts`
    /// argument still contains the pre-apply state — important for
    /// resolving the device name on `.detached`.
    ///
    /// No-ops for `.telemetry`, `.fullRefresh`, and any event whose
    /// per-event-type toggle is off (the builder returns nil).
    func handle(_ event: PortEvent, graph: PortGraph) {
        guard let content = NotificationContentBuilder.makeContent(
            for: event,
            hosts: graph.hosts,
            preferences: preferences
        ) else { return }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // immediate delivery
        )

        // Fire-and-forget: UN's `add` returns quickly; failures are
        // surfaced via the completion handler. We don't await — the
        // consumer task should keep moving, and notification failures
        // are not user-actionable.
        center.add(request) { error in
            if let error {
                Log.app.error("Failed to deliver notification: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
