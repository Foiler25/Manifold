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
// NotificationPreferences.swift
//
// Thin UserDefaults wrapper for the Phase 9 per-event-type toggles.
// SPEC §18 Phase 9 #4: "Per-event-type toggles in NotificationsPane
// disable individual notification kinds." Three toggles match the
// three event categories that produce notifications: connect,
// disconnect, diagnostic. Telemetry + fullRefresh never notify.
//
// Why a struct around UserDefaults instead of @AppStorage directly:
// `NotificationService` reads these from outside SwiftUI (the event
// consumer task). @AppStorage is SwiftUI-only; for the service-side
// reads we need a Swift API. The Settings pane uses both — `Bindable`
// over the same UserDefaults keys via `@AppStorage` in the View.
//
// `defaults` is injected so tests can pass `UserDefaults(suiteName:)`
// without polluting the app's real defaults.

import Foundation

struct NotificationPreferences {

    /// UserDefaults backing store. Production uses `.standard`;
    /// tests use a dedicated suite (cleared in `setUp`/`tearDown`).
    /// `UserDefaults` is documented thread-safe for read+write but
    /// not currently marked `Sendable` in the stdlib, so this struct
    /// stays non-Sendable. Callers (`NotificationService`,
    /// `NotificationsPane` via @AppStorage) are all @MainActor —
    /// the struct never crosses an isolation boundary.
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Keys

    /// Shared key namespace. All Phase 9 keys live under this prefix
    /// so a future "reset notification settings" affordance can clean
    /// up by enumerating the namespace.
    enum Key {
        static let didRequestAuthorization = "notifications.didRequestAuthorization"
        static let connectEnabled    = "notifications.connect.enabled"
        static let disconnectEnabled = "notifications.disconnect.enabled"
        static let diagnosticEnabled = "notifications.diagnostic.enabled"
    }

    // MARK: - Per-event-type toggles

    /// Notify on `.attached` events. Defaults to true so a fresh
    /// install gives the user the connect/disconnect feedback the
    /// app's value prop centres on.
    var connectEnabled: Bool {
        get { defaults.object(forKey: Key.connectEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.connectEnabled) }
    }

    /// Notify on `.detached` events. Default true (same reasoning).
    var disconnectEnabled: Bool {
        get { defaults.object(forKey: Key.disconnectEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.disconnectEnabled) }
    }

    /// Notify on `.diagnostic` events. Default true — diagnostics are
    /// the surprising, actionable kind; the user almost certainly
    /// wants to hear about them.
    var diagnosticEnabled: Bool {
        get { defaults.object(forKey: Key.diagnosticEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.diagnosticEnabled) }
    }

    // MARK: - Authorization tracking

    /// Set to true after the first `requestAuthorization` call so the
    /// service doesn't re-prompt every launch (the OS would still
    /// no-op the second prompt, but this avoids the API call).
    var didRequestAuthorization: Bool {
        get { defaults.bool(forKey: Key.didRequestAuthorization) }
        set { defaults.set(newValue, forKey: Key.didRequestAuthorization) }
    }
}
