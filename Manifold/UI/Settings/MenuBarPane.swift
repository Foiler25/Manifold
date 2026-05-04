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
// MenuBarPane.swift
//
// Phase 18 — sixth Settings tab per SPEC §20.7. Two sections:
//
//   1. "Menu bar items" — toggle for the battery status item
//      visibility. Detail copy notes that the toggle is a no-op on
//      desktop Macs (where the status item is never installed
//      regardless of the AppStorage value). The host app's
//      AppDelegate observes the AppStorage value via
//      `UserDefaults.didChangeNotification` and live-toggles
//      install/uninstall — no relaunch needed.
//
//   2. "Battery sampling" — slider for the battery sample rate
//      (0.5–5 Hz). Independent from the General-pane USB sample
//      rate per D18 / Q13.

import SwiftUI

struct MenuBarPane: View {

    /// Optional callback so AppDelegate can apply the battery sample
    /// rate the moment the slider changes. Mirrors the
    /// `onSampleRateChange` plumbing GeneralPane uses for the USB
    /// telemetry rate. nil-tolerant for Previews / tests.
    let onBatterySampleRateChange: ((Double) -> Void)?

    @AppStorage(SettingsKeys.menubarBatteryItemVisible)
    private var batteryItemVisible: Bool = SettingsDefaults.menubarBatteryItemVisible

    @AppStorage(SettingsKeys.batterySampleRateHz)
    private var batterySampleRate: Double = SettingsDefaults.batterySampleRateHz

    var body: some View {
        Form {
            Section("settings.menubar.section.items") {
                Toggle("settings.menubar.batteryItem.title", isOn: $batteryItemVisible)
                Text("settings.menubar.batteryItem.detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("settings.menubar.section.sampling") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("settings.menubar.sampleRate.title")
                        Spacer()
                        Text(String(format: "%.1f Hz", batterySampleRate))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $batterySampleRate,
                        in: MenuBarPaneConstants.sampleRateRange,
                        step: MenuBarPaneConstants.sampleRateStep
                    )
                    Text("settings.menubar.sampleRate.detail")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .onChange(of: batterySampleRate) { _, new in
                    onBatterySampleRateChange?(new)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 460, minHeight: 320)
    }
}

// MARK: - Constants

enum MenuBarPaneConstants {
    /// Sample rate slider range — matches the
    /// `BatterySamplerConstants.minRate ... maxRate` clamp so the
    /// UI never lets the user pick a value the sampler will then
    /// silently snap.
    static let sampleRateRange: ClosedRange<Double> = 0.5 ... 5.0

    /// Slider step. 0.5 Hz keeps the slider's discrete stops aligned
    /// with values users will reason about (1 Hz, 2 Hz, etc.).
    static let sampleRateStep: Double = 0.5
}

#Preview("MenuBarPane") {
    MenuBarPane(onBatterySampleRateChange: nil)
}
