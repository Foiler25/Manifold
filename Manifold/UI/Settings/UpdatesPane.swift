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
// UpdatesPane.swift
//
// Phase 14 settings pane shell per SPEC §13:
//   - Update channel picker (stable / beta).
//   - Last-check timestamp (display-only).
//   - "Check for updates now" button — Phase 14 ships the picker +
//     persistence; the actual Sparkle wire-up is SPEC §15 + Phase
//     15 work (Sparkle SPM dep + UpdaterController). Until then the
//     button is disabled with an explanatory banner so the channel
//     picker is functional in isolation.

import SwiftUI

struct UpdatesPane: View {

    @AppStorage(SettingsKeys.updateChannel)
    private var channelRaw: String = UpdateChannel.default.rawValue

    @AppStorage(SettingsKeys.lastUpdateCheckISO)
    private var lastCheckISO: String = ""

    var body: some View {
        Form {
            Section("settings.updates.channel.section") {
                Picker("settings.updates.channel.title", selection: $channelRaw) {
                    Text("settings.updates.channel.stable").tag(UpdateChannel.stable.rawValue)
                    Text("settings.updates.channel.beta").tag(UpdateChannel.beta.rawValue)
                }
                .pickerStyle(.segmented)
                Text("settings.updates.channel.detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("settings.updates.check.section") {
                LabeledContent("settings.updates.lastCheck.title") {
                    Text(formattedLastCheck)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button {
                    // Sparkle wiring lands Phase 15. Until then the
                    // button is disabled and this body is unreachable.
                } label: {
                    Label("settings.updates.check.button", systemImage: "arrow.down.circle")
                }
                .disabled(true)
                Text("settings.updates.sparkleDeferred")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 460, minHeight: 320)
    }

    /// "Never" when the timestamp string is empty; otherwise an
    /// `ISO8601 → DateFormatter.string(from:)` round-trip in
    /// medium/short style so the user sees a localised wall clock.
    private var formattedLastCheck: String {
        guard !lastCheckISO.isEmpty,
              let date = ISO8601DateFormatter().date(from: lastCheckISO) else {
            return NSLocalizedString("settings.updates.lastCheck.never", comment: "")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

#Preview("UpdatesPane") {
    UpdatesPane()
}
