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
// OnboardingSheet.swift
//
// First-run sheet. Originally a single-pane permissions explainer
// (Phase 15 #7); 2026-05-04 split into a two-step wizard so the
// new Phase 18 battery monitor gets a proper introduction:
//
//   Step 1 — Welcome / permissions explainer (unchanged content).
//   Step 2 — Battery monitor: live ChargeBannerSection rendering
//            BatteryViewPreviewData.healthy as a demo, plus a
//            "Show in menu bar" toggle bound to the same
//            @AppStorage key the Menu Bar settings pane uses.
//
// One-shot affordance gated by `@AppStorage(SettingsKeys.onboarding-
// Completed)`. The toggle on step 2 binds to the live preference
// store, so flipping it during onboarding immediately drives
// AppDelegate's UserDefaults observer to install / uninstall the
// status item — no extra wiring needed.

import SwiftUI
import ManifoldKit

struct OnboardingSheet: View {

    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKeys.onboardingCompleted)
    private var onboardingCompleted: Bool = false

    @AppStorage(SettingsKeys.menubarBatteryItemVisible)
    private var batteryItemVisible: Bool = SettingsDefaults.menubarBatteryItemVisible

    @State private var step: Step = .welcome

    enum Step {
        case welcome
        case battery
    }

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .welcome:
                welcomePane
                    .transition(.opacity)
            case .battery:
                batteryPane
                    .transition(.opacity)
            }
        }
        .padding(20)
        .frame(width: 460, height: 520)
        .animation(.easeInOut(duration: 0.18), value: step)
    }

    // MARK: - Step 1: Welcome / permissions

    private var welcomePane: some View {
        VStack(spacing: 18) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .padding(.top, 12)

            Text("onboarding.welcome.title")
                .font(.title.weight(.semibold))

            Text("onboarding.welcome.subtitle")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 12) {
                row(icon: "menubar.dock.rectangle",
                    title: "onboarding.menubar.title",
                    detail: "onboarding.menubar.detail")
                row(icon: "bell.badge",
                    title: "onboarding.notifications.title",
                    detail: "onboarding.notifications.detail")
                row(icon: "lock.shield",
                    title: "onboarding.privacy.title",
                    detail: "onboarding.privacy.detail")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Spacer(minLength: 0)

            Button {
                step = .battery
            } label: {
                Text("onboarding.next")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Step 2: Battery monitor

    private var batteryPane: some View {
        VStack(spacing: 16) {
            Image(systemName: "battery.100.bolt")
                .font(.system(size: 48))
                .foregroundStyle(Color.manifoldAccent)
                .padding(.top, 8)

            Text("onboarding.battery.title")
                .font(.title.weight(.semibold))

            Text("onboarding.battery.subtitle")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            // Live demo card — renders the real ChargeBannerSection
            // against BatteryViewPreviewData.healthy so any future UI
            // change to the popover flows through automatically.
            ChargeBannerSection(battery: OnboardingDemoData.battery)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.manifoldCard)
                )
                .padding(.horizontal, 8)

            // Live-bound toggle — flipping this during onboarding
            // triggers AppDelegate's UserDefaults observer, which
            // installs / uninstalls the status item immediately.
            Toggle(isOn: $batteryItemVisible) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("onboarding.battery.toggle.title")
                        .font(.body.weight(.semibold))
                    Text("onboarding.battery.toggle.detail")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 16)

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button {
                    step = .welcome
                } label: {
                    Text("onboarding.back")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)

                Button {
                    onboardingCompleted = true
                    dismiss()
                } label: {
                    Text("onboarding.done")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// One row in the welcome explainer body: icon column +
    /// title/detail pair. Localized labels read sensibly under
    /// VoiceOver as a combined element.
    private func row(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Demo seed

/// Hardcoded `BatteryInfo` used by the onboarding battery demo card.
/// Uses realistic mid-cycle values so the static preview reads as
/// a snapshot of a healthy laptop, not a sterile placeholder.
private enum OnboardingDemoData {
    static let battery = BatteryInfo(
        chargePercent: 84,
        chargeState: .charging,
        healthPercent: 96,
        cycleCount: 47,
        temperatureCelsius: 32.4,
        voltageVolts: 12.45,
        amperageMilliamps: 1234,
        powerWatts: 12.45 * 1.234,
        designCapacityMAh: 4380,
        nominalCapacityMAh: 4205,
        currentCapacityMAh: 3680,
        timeUntilFullMinutes: 24,
        timeUntilEmptyMinutes: nil,
        isExternalConnected: true,
        isFullyCharged: false,
        sampledAt: Date(timeIntervalSince1970: 1_735_689_600)
    )
}

#Preview("OnboardingSheet — welcome") {
    OnboardingSheet()
}
