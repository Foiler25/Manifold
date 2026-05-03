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
// NotificationsPane.swift
//
// Phase 9 settings pane: per-event-type toggles for the three
// notification kinds. SPEC §18 Phase 9 #4: "Per-event-type toggles
// in NotificationsPane disable individual notification kinds."
//
// Phase 14 will compose this pane into the full `SettingsScene`
// (`SettingsScene.swift` is part of Phase 14's work). Phase 9 ships
// the pane as a standalone view so its #Preview, accessibility, and
// AppStorage wiring can be verified now without waiting on the
// scene assembly.
//
// `@AppStorage` keys MUST match `NotificationPreferences.Key.*` —
// the View writes; the service reads. The string keys are the
// contract.

import SwiftUI

struct NotificationsPane: View {

    // Defaults match `NotificationPreferences.Key.*` defaults: true
    // means "notify by default; user opts out". The literal default
    // value here is a SwiftUI fallback only — the keys themselves
    // are the source of truth, and `NotificationPreferences` reads
    // from `defaults.object(forKey:) as? Bool ?? true` for the same
    // reason.
    @AppStorage(NotificationPreferences.Key.connectEnabled)
    private var connectEnabled: Bool = true

    @AppStorage(NotificationPreferences.Key.disconnectEnabled)
    private var disconnectEnabled: Bool = true

    @AppStorage(NotificationPreferences.Key.diagnosticEnabled)
    private var diagnosticEnabled: Bool = true

    var body: some View {
        Form {
            Section {
                Toggle("settings.notifications.connect.title", isOn: $connectEnabled)
                Text("settings.notifications.connect.detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("settings.notifications.disconnect.title", isOn: $disconnectEnabled)
                Text("settings.notifications.disconnect.detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("settings.notifications.diagnostic.title", isOn: $diagnosticEnabled)
                Text("settings.notifications.diagnostic.detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("settings.notifications.dnd.note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 420, minHeight: 320)
    }
}

#Preview("NotificationsPane") {
    NotificationsPane()
}
