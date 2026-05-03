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
// GeneralPane.swift
//
// Phase 14 settings pane per SPEC §13:
//   - Sample rate slider (0.5–5 Hz; clamped by TelemetrySampler).
//   - Theme picker (system / light / dark) — applied immediately
//     by ManifoldApp's `.preferredColorScheme(_:)` modifier on
//     the WindowGroup root.
//   - Launch-at-login toggle (`SMAppService.mainApp.{register,
//     unregister}` via `LoginItemController`).
//
// Each control's @AppStorage key lives in `SettingsKeys`. The
// View pushes the new value out through the supplied closures
// the moment the control changes — no Apply/Save button.

import SwiftUI

struct GeneralPane: View {

    /// Pushed in by `SettingsScene` so the pane can hand the new
    /// rate to TelemetrySampler without import-cycling through
    /// AppDelegate. nil-tolerant for the standalone #Preview.
    let onSampleRateChange: ((Double) -> Void)?

    /// Login-item facade. Production wires `LiveLoginItemController`;
    /// tests inject a stub. nil-tolerant for #Preview.
    let loginItemController: (any LoginItemController)?

    @AppStorage(SettingsKeys.sampleRateHz)
    private var sampleRate: Double = 1.0

    @AppStorage(SettingsKeys.themePreference)
    private var themeRaw: String = ThemePreference.default.rawValue

    @AppStorage(SettingsKeys.launchAtLogin)
    private var launchAtLogin: Bool = false

    /// Surfaces a "couldn't apply" message under the toggle when
    /// SMAppService.register/unregister fails — the AppStorage
    /// flag is reverted to match the actual OS state in that
    /// case, but the user deserves to know why their click had
    /// no effect.
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("settings.general.sampling.section") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("settings.general.sampleRate.title")
                        Spacer()
                        Text(String(format: "%.1f Hz", sampleRate))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $sampleRate,
                        in: 0.5...5.0,
                        step: 0.5
                    )
                    Text("settings.general.sampleRate.detail")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .onChange(of: sampleRate) { _, new in
                    onSampleRateChange?(new)
                }
            }

            Section("settings.general.appearance.section") {
                Picker("settings.general.theme.title", selection: $themeRaw) {
                    Text("settings.general.theme.system").tag(ThemePreference.system.rawValue)
                    Text("settings.general.theme.light").tag(ThemePreference.light.rawValue)
                    Text("settings.general.theme.dark").tag(ThemePreference.dark.rawValue)
                }
                .pickerStyle(.segmented)
                Text("settings.general.theme.detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("settings.general.startup.section") {
                Toggle("settings.general.launchAtLogin.title", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, new in
                        applyLoginItem(new)
                    }
                Text("settings.general.launchAtLogin.detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 460, minHeight: 380)
        .task {
            // Reconcile UI with the actual OS state on appear so a
            // user who toggled login items via System Settings
            // sees the right initial state.
            if let controller = loginItemController {
                let osState = controller.isCurrentlyEnabled
                if launchAtLogin != osState {
                    launchAtLogin = osState
                }
            }
        }
    }

    private func applyLoginItem(_ enabled: Bool) {
        guard let controller = loginItemController else {
            loginItemError = nil
            return
        }
        if controller.apply(enabled) {
            loginItemError = nil
        } else {
            // Revert the flag so the toggle reflects what the OS
            // actually did. Set the error string so the user sees
            // the failure rather than an unresponsive toggle.
            launchAtLogin = !enabled
            loginItemError = NSLocalizedString(
                "settings.general.launchAtLogin.error",
                comment: "Shown when SMAppService.register/unregister fails."
            )
        }
    }
}

#Preview("GeneralPane") {
    GeneralPane(
        onSampleRateChange: nil,
        loginItemController: nil
    )
}
