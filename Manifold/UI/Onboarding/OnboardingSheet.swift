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
// Phase 15 #7: brief permissions explainer on first launch. The
// SPEC text is "splash/intro on first launch: brief permissions
// explainer" — Manifold needs the Notifications permission (Phase
// 9 wiring) and benefits from the user understanding the unsandboxed
// IOKit access (the BRIEF-stated trade-off for direct USB/TB
// visibility). One-shot affordance gated by an
// `@AppStorage(SettingsKeys.onboardingCompleted)` flag.
//
// Design intent: short. Three lines + three icons + one Done
// button. Not a multi-page wizard. The user just installed an
// open-source utility — they want to see devices, not click
// through a tutorial.

import SwiftUI

struct OnboardingSheet: View {

    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKeys.onboardingCompleted)
    private var onboardingCompleted: Bool = false

    var body: some View {
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
                row(icon: "menubar.dock.rectangle", title: "onboarding.menubar.title", detail: "onboarding.menubar.detail")
                row(icon: "bell.badge",              title: "onboarding.notifications.title", detail: "onboarding.notifications.detail")
                row(icon: "lock.shield",             title: "onboarding.privacy.title", detail: "onboarding.privacy.detail")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Spacer(minLength: 0)

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
        .padding(20)
        .frame(width: 460, height: 480)
    }

    /// One row in the explainer body: icon column + title/detail
    /// pair. Localized labels read sensibly under VoiceOver as a
    /// combined element ("Menu bar live, Open the menu bar icon for
    /// the live device list").
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

#Preview("OnboardingSheet") {
    OnboardingSheet()
}
