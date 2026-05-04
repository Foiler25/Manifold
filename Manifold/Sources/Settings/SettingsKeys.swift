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
// SettingsKeys.swift
//
// Phase 14. Centralised UserDefaults key namespace for the General /
// Updates panes. Keeps the SwiftUI `@AppStorage` literals + the
// service-side reads agreeing on one set of strings — same pattern
// `NotificationPreferences.Key` set up in Phase 9 and `HistoryPane.Key`
// in Phase 10.
//
// Why a single file rather than per-pane: the General pane's
// settings (sample rate, theme, launch-at-login) are read by code
// outside the View (TelemetrySampler observes the rate change;
// AppDelegate applies the theme; LoginItemController toggles the
// SMAppService registration). Lifting the keys out of the View
// keeps the ownership clear and lets tests pin the strings without
// pulling in SwiftUI.

import Foundation

enum SettingsKeys {

    // MARK: - General

    /// Telemetry sample rate in Hz. Default 1.0 per SPEC §8;
    /// `TelemetrySampler` clamps to `[0.5, 5.0]` via its `didSet`
    /// so an out-of-range stored value gets normalised on read.
    static let sampleRateHz = "settings.general.sampleRateHz"

    /// Theme picker raw string ("system" / "light" / "dark"); maps
    /// to `SwiftUI.ColorScheme?` via `ThemePreference.colorScheme`.
    static let themePreference = "settings.general.themePreference"

    /// Launch-at-login toggle. The actual SMAppService registration
    /// happens in `LoginItemController.apply(_:)` whenever this
    /// changes; `AppStorage` is the source of truth for the UI
    /// state, the controller bridges it to the OS facing API.
    static let launchAtLogin = "settings.general.launchAtLogin"

    // MARK: - Updates

    /// Sparkle update channel ("stable" / "beta"). Phase 14 ships
    /// the picker + persistence; the actual Sparkle wire-up lands
    /// in Phase 15 (Sparkle SPM dep + UpdaterController). Until
    /// then, the UI shows the picker but `Check for updates now`
    /// is disabled with an explanatory banner.
    static let updateChannel = "settings.updates.channel"

    /// ISO-8601 timestamp of the last "Check for updates" attempt.
    /// Empty string means "never checked". Stored as a String so
    /// AppStorage can drive it directly (Date isn't AppStorage-
    /// compatible without a wrapper).
    static let lastUpdateCheckISO = "settings.updates.lastCheckISO"

    // MARK: - Onboarding (Phase 15 #7)

    /// Set to true after the user dismisses the OnboardingSheet.
    /// Default false → first-launch presentation. The sheet's Done
    /// button is the only writer; once true, it stays true for the
    /// life of the install (the UI offers no "show onboarding
    /// again" affordance — Phase 15 ships the simplest shape).
    static let onboardingCompleted = "settings.onboarding.completed"

    // MARK: - Phase 18 — Menu bar / battery

    /// Whether the second (battery) `NSStatusItem` is installed.
    /// Default `true`. On desktop Macs (no `AppleSmartBattery`),
    /// this toggle is a no-op: AppDelegate gates installation on the
    /// app-start probe returning a non-nil snapshot, regardless of
    /// the value here. The MenuBarPane copy surfaces this explicitly.
    static let menubarBatteryItemVisible = "settings.menubar.batteryItemVisible"

    /// Sample rate for `BatterySampler`, independent from the
    /// General-pane USB telemetry rate per D18 / Q13. Default 1.0 Hz,
    /// clamped 0.5–5.0 by the sampler's `didSet`.
    static let batterySampleRateHz = "settings.menubar.batterySampleRateHz"

    /// String id of the most recently selected `SettingsScene` pane.
    /// Bound to `TabView`'s selection in `SettingsScene` so callers
    /// (e.g. the battery popover's gear button) can deep-link into a
    /// specific pane by writing this key before triggering
    /// `openSettings`. Pane ids match the `SettingsTabID.<case>.rawValue`
    /// strings.
    static let selectedSettingsPaneId = "settings.selectedPaneId"
}

/// Stable string ids for each `SettingsScene` pane. Used both as
/// `TabView` selection tags and as the values written to
/// `SettingsKeys.selectedSettingsPaneId` by deep-link callers.
enum SettingsTabID: String, CaseIterable {
    case general
    case notifications
    case history
    case menubar
    case updates
    case about
}

// MARK: - Phase 18 defaults

enum SettingsDefaults {
    /// Default value for `menubarBatteryItemVisible`. Lifted to a
    /// named constant so the `@AppStorage` literals in
    /// `MenuBarPane` and the AppDelegate gate read agree on the
    /// fallback.
    static let menubarBatteryItemVisible: Bool = true

    /// Default battery sampler rate in Hz. 5 Hz matches
    /// `BatterySamplerConstants.defaultRate` — see that comment for
    /// why we run at the slider's max by default (sampler pauses
    /// when no UI is visible, so idle cost stays at zero).
    static let batterySampleRateHz: Double = 5.0
}

// MARK: - ThemePreference

/// Three-way picker mapping. Stored as the raw String for the
/// `@AppStorage` binding; `colorScheme` produces the
/// SwiftUI-native value to apply via `.preferredColorScheme(_:)`.
enum ThemePreference: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    static let `default`: ThemePreference = .system

    /// nil → follow the system setting; SwiftUI interprets nil
    /// `preferredColorScheme` exactly that way.
    var colorScheme: ColorSchemeValue {
        switch self {
        case .system: return .system
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// Tiny enum mirror of `SwiftUI.ColorScheme?`. Named so the
/// key-binding-friendly raw form lives outside SwiftUI imports —
/// `SettingsKeys` is `Foundation`-only.
enum ColorSchemeValue: Sendable {
    case system, light, dark
}

// MARK: - UpdateChannel

/// Two-way picker for Sparkle's update channel. Phase 14 stores
/// the user's preference; Phase 15+ Sparkle integration reads the
/// channel string when constructing the appcast URL.
enum UpdateChannel: String, CaseIterable, Sendable {
    case stable
    case beta

    static let `default`: UpdateChannel = .stable
}
