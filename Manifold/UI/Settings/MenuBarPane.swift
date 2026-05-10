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
// Phase 18 origin (sixth Settings tab per SPEC §20.7) extended in
// Phase 19 (SPEC §21.9) with five additional battery-alert sections:
//
//   1. Battery alerts (master) — single toggle for the whole feature.
//   2. Sounds (master) — mute switch for all four event-type sounds.
//   3. Low Battery Alerts — user-managed list of `.low` thresholds.
//   4. Charged Alerts — user-managed list of `.charged` thresholds.
//   5. Power Source Alerts — fixed two-row plug + unplug toggles.
//
// All five battery-alert sections are gated on `graph.battery == nil`
// at app start (probe was nil → desktop Mac). The pre-existing
// "Show battery in menu bar" toggle stays visible per §20.10.

import SwiftUI

struct MenuBarPane: View {

    /// Live `PortGraph`. Used to gate the battery-alert sections —
    /// `graph.battery == nil` means desktop Mac (or pre-first-tick),
    /// in which case the entire alert configuration UI is hidden.
    let graph: PortGraph

    /// Phase 19 — shared alert preferences instance. nil on desktop
    /// Macs (AppDelegate didn't construct the alert stack).
    let batteryAlertPreferences: BatteryAlertPreferences?

    @AppStorage(SettingsKeys.menubarBatteryItemVisible)
    private var batteryItemVisible: Bool = SettingsDefaults.menubarBatteryItemVisible

    @AppStorage(SettingsKeys.batteryAlertsEnabled)
    private var batteryAlertsEnabled: Bool = SettingsDefaults.batteryAlertsEnabled

    /// Inline editor state for the Add buttons. Tracked per-kind so
    /// adding a low alert doesn't clobber the charged-alert editor.
    @State private var pendingLowPercent: Int = 20
    @State private var pendingChargedPercent: Int = 80
    @State private var showLowAdd: Bool = false
    @State private var showChargedAdd: Bool = false

    private var batteryHardwarePresent: Bool {
        graph.battery != nil || batteryAlertPreferences != nil
    }

    var body: some View {
        Form {
            // Section 1 (existing) — Menu bar items
            Section("settings.menubar.section.items") {
                Toggle("settings.menubar.batteryItem.title", isOn: $batteryItemVisible)
                Text("settings.menubar.batteryItem.detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Phase 19 sections — gated on battery hardware. Phase
            // 21.7 dropped the previous "Battery sampling" section:
            // both `BatteryInterestObserver` (kIOGeneralInterest) and
            // `BatteryNotificationObserver` (IOPS) are push-driven, so
            // there is no rate the user could meaningfully control.
            if batteryHardwarePresent, let prefs = batteryAlertPreferences {
                batteryAlertsMasterSection
                soundsMasterSection(prefs: prefs)
                lowAlertsSection(prefs: prefs)
                chargedAlertsSection(prefs: prefs)
                powerSourceSection(prefs: prefs)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 460, minHeight: 320)
    }

    // MARK: - Phase 19 sections

    @ViewBuilder
    private var batteryAlertsMasterSection: some View {
        Section("settings.menubar.alerts.section.master") {
            Toggle("settings.menubar.alerts.master.title", isOn: $batteryAlertsEnabled)
            Text("settings.menubar.alerts.master.detail")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func soundsMasterSection(prefs: BatteryAlertPreferences) -> some View {
        Section("settings.menubar.alerts.section.sounds") {
            @Bindable var bindable = prefs
            Toggle(
                "settings.menubar.alerts.sounds.master.title",
                isOn: $bindable.batteryAlertsSoundEnabled
            )
            .disabled(!batteryAlertsEnabled)
            Text("settings.menubar.alerts.sounds.master.detail")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func lowAlertsSection(prefs: BatteryAlertPreferences) -> some View {
        Section("settings.menubar.alerts.section.low") {
            ForEach(prefs.alerts.filter({ $0.kind == .low })) { row in
                BatteryAlertRowView(prefs: prefs, row: row)
                    .disabled(!batteryAlertsEnabled)
            }

            if showLowAdd {
                inlineAdder(
                    binding: $pendingLowPercent,
                    range: BatteryAlertConfigBounds.lowMinPercent
                        ... BatteryAlertConfigBounds.lowMaxPercent,
                    save: {
                        prefs.add(kind: .low, percent: pendingLowPercent)
                        showLowAdd = false
                    },
                    cancel: { showLowAdd = false }
                )
            } else {
                Button {
                    pendingLowPercent = MenuBarPaneConstants.defaultLowAddPercent
                    showLowAdd = true
                } label: {
                    Label("settings.menubar.alerts.low.add", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(!batteryAlertsEnabled)
            }
        }
    }

    @ViewBuilder
    private func chargedAlertsSection(prefs: BatteryAlertPreferences) -> some View {
        Section("settings.menubar.alerts.section.charged") {
            ForEach(prefs.alerts.filter({ $0.kind == .charged })) { row in
                BatteryAlertRowView(prefs: prefs, row: row)
                    .disabled(!batteryAlertsEnabled)
            }

            if showChargedAdd {
                inlineAdder(
                    binding: $pendingChargedPercent,
                    range: BatteryAlertConfigBounds.chargedMinPercent
                        ... BatteryAlertConfigBounds.chargedMaxPercent,
                    save: {
                        prefs.add(kind: .charged, percent: pendingChargedPercent)
                        showChargedAdd = false
                    },
                    cancel: { showChargedAdd = false }
                )
            } else {
                Button {
                    pendingChargedPercent = MenuBarPaneConstants.defaultChargedAddPercent
                    showChargedAdd = true
                } label: {
                    Label("settings.menubar.alerts.charged.add", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(!batteryAlertsEnabled)
            }
        }
    }

    @ViewBuilder
    private func powerSourceSection(prefs: BatteryAlertPreferences) -> some View {
        Section("settings.menubar.alerts.section.powerSource") {
            @Bindable var bindable = prefs
            HStack {
                Image(systemName: "powerplug.portrait.fill")
                    .foregroundStyle(Color.manifoldAccent)
                    .frame(width: MenuBarPaneConstants.rowIconColumnWidth)
                Toggle("settings.menubar.alerts.pluggedIn.title", isOn: $bindable.pluggedInEnabled)
                Spacer()
                Toggle(isOn: $bindable.pluggedInPlaysSound) {
                    Image(systemName: bindable.pluggedInPlaysSound ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .accessibilityLabel("settings.menubar.alerts.row.sound.label")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .disabled(!bindable.pluggedInEnabled || !prefs.batteryAlertsSoundEnabled)
            }
            .disabled(!batteryAlertsEnabled)

            HStack {
                Image(systemName: "powerplug.portrait")
                    .foregroundStyle(Color.manifoldWarning)
                    .frame(width: MenuBarPaneConstants.rowIconColumnWidth)
                Toggle("settings.menubar.alerts.unplugged.title", isOn: $bindable.unpluggedEnabled)
                Spacer()
                Toggle(isOn: $bindable.unpluggedPlaysSound) {
                    Image(systemName: bindable.unpluggedPlaysSound ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .accessibilityLabel("settings.menubar.alerts.row.sound.label")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .disabled(!bindable.unpluggedEnabled || !prefs.batteryAlertsSoundEnabled)
            }
            .disabled(!batteryAlertsEnabled)
        }
    }

    /// Inline percent stepper + Save / Cancel for the Add flows.
    /// Lives inline (no sheet) per SPEC §21.9 to keep the pane focused.
    @ViewBuilder
    private func inlineAdder(
        binding: Binding<Int>,
        range: ClosedRange<Int>,
        save: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) -> some View {
        HStack {
            Stepper(value: binding, in: range) {
                Text("\(binding.wrappedValue)%")
                    .font(.body.monospacedDigit())
            }
            Spacer()
            Button("settings.menubar.alerts.add.cancel", action: cancel)
                .buttonStyle(.borderless)
            Button("settings.menubar.alerts.add.save", action: save)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}

// MARK: - Per-row view

/// One configurable row in the Low or Charged section. Renders the
/// percent badge, the leading enabled toggle, the per-row sound
/// toggle, and the trash icon.
private struct BatteryAlertRowView: View {

    let prefs: BatteryAlertPreferences
    let row: BatteryAlertConfig

    var body: some View {
        HStack {
            Image(systemName: "battery.25")
                .foregroundStyle(BatteryViewSectionsConstants.levelTint(percent: row.percent))
                .frame(width: MenuBarPaneConstants.rowIconColumnWidth)

            // Percent capsule badge — color-graded by level.
            Text("\(row.percent)%")
                .font(.body.monospacedDigit())
                .padding(.horizontal, MenuBarPaneConstants.rowBadgeHorizontalPadding)
                .padding(.vertical, MenuBarPaneConstants.rowBadgeVerticalPadding)
                .background(
                    Capsule().fill(
                        BatteryViewSectionsConstants.levelTint(percent: row.percent)
                            .opacity(MenuBarPaneConstants.rowBadgeBackgroundOpacity)
                    )
                )
                .foregroundStyle(BatteryViewSectionsConstants.levelTint(percent: row.percent))

            Toggle(
                "settings.menubar.alerts.row.enabled.label",
                isOn: Binding(
                    get: { row.enabled },
                    set: { newValue in
                        var updated = row
                        updated.enabled = newValue
                        prefs.update(updated)
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            Spacer()

            // Sound toggle.
            Toggle(
                isOn: Binding(
                    get: { row.playsSound },
                    set: { newValue in
                        var updated = row
                        updated.playsSound = newValue
                        prefs.update(updated)
                    }
                )
            ) {
                Image(systemName: row.playsSound ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .accessibilityLabel("settings.menubar.alerts.row.sound.label")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .disabled(!row.enabled || !prefs.batteryAlertsSoundEnabled)

            // Trash button.
            Button {
                prefs.remove(id: row.id)
            } label: {
                Image(systemName: "trash")
                    .accessibilityLabel("settings.menubar.alerts.row.delete.label")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }
}

// MARK: - Constants

enum MenuBarPaneConstants {
    /// Default percent the "Add low alert" inline editor seeds with.
    /// 20% picks a reasonable middle of the valid range — the user
    /// can still change before saving.
    static let defaultLowAddPercent: Int = 20

    /// Default percent the "Add charged alert" inline editor seeds.
    static let defaultChargedAddPercent: Int = 80

    /// Width of the leading icon column in each alert row. Lifted to
    /// a constant so every row + the power-source rows align.
    static let rowIconColumnWidth: CGFloat = 24

    /// Horizontal padding inside the percent capsule badge.
    static let rowBadgeHorizontalPadding: CGFloat = 8

    /// Vertical padding inside the percent capsule badge.
    static let rowBadgeVerticalPadding: CGFloat = 2

    /// Background opacity for the percent capsule. Subtle — the
    /// foreground color carries the level signal; the capsule's
    /// fill at full opacity would be visually loud.
    static let rowBadgeBackgroundOpacity: Double = 0.18
}

#Preview("MenuBarPane") {
    MenuBarPane(
        graph: PortGraph(),
        batteryAlertPreferences: nil
    )
}
