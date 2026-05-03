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
// ─────────────────────────────────────────────────────────────────────
// SettingsKeysTests.swift
//
// Pin the Phase 14 SettingsKeys + ThemePreference + UpdateChannel
// invariants:
//   - Key strings match the documented contract (a rename without
//     updating the @AppStorage literals in the panes would silently
//     orphan persisted values).
//   - ThemePreference / UpdateChannel raw-value mappings are stable.
//   - Defaults match the SPEC text.

import XCTest
@testable import Manifold

final class SettingsKeysTests: XCTestCase {

    // MARK: - Key string contract

    /// AppStorage literals in GeneralPane / UpdatesPane / Manifold-
    /// App reference these strings; renaming requires updating
    /// every consumer. Pinning the strings here is the cheapest
    /// way to catch a stray rename.
    func test_keyStrings_matchExpectedContract() {
        XCTAssertEqual(SettingsKeys.sampleRateHz,      "settings.general.sampleRateHz")
        XCTAssertEqual(SettingsKeys.themePreference,   "settings.general.themePreference")
        XCTAssertEqual(SettingsKeys.launchAtLogin,     "settings.general.launchAtLogin")
        XCTAssertEqual(SettingsKeys.updateChannel,     "settings.updates.channel")
        XCTAssertEqual(SettingsKeys.lastUpdateCheckISO, "settings.updates.lastCheckISO")
    }

    // MARK: - ThemePreference

    /// Default is `.system` per SPEC §13 wording. A future "default
    /// to dark" change should be a deliberate decision, not an
    /// accident.
    func test_themePreference_defaultIsSystem() {
        XCTAssertEqual(ThemePreference.default, .system)
    }

    /// Raw values match the on-disk strings — renaming a case
    /// without migration would orphan every existing user's
    /// preference.
    func test_themePreference_rawValuesAreStable() {
        XCTAssertEqual(ThemePreference.system.rawValue, "system")
        XCTAssertEqual(ThemePreference.light.rawValue,  "light")
        XCTAssertEqual(ThemePreference.dark.rawValue,   "dark")
    }

    /// `colorScheme` produces the matching mirror enum so
    /// SwiftUI's `preferredColorScheme(_:)` mapping is greppable.
    func test_themePreference_colorSchemeMapping() {
        XCTAssertEqual(ThemePreference.system.colorScheme, .system)
        XCTAssertEqual(ThemePreference.light.colorScheme,  .light)
        XCTAssertEqual(ThemePreference.dark.colorScheme,   .dark)
    }

    /// `allCases` covers exactly the three documented options.
    func test_themePreference_allCases_isExhaustive() {
        XCTAssertEqual(Set(ThemePreference.allCases.map(\.rawValue)), ["system", "light", "dark"])
    }

    // MARK: - UpdateChannel

    /// Default is stable per SPEC §13 ("stable / beta" with stable
    /// listed first as the implied default).
    func test_updateChannel_defaultIsStable() {
        XCTAssertEqual(UpdateChannel.default, .stable)
    }

    func test_updateChannel_rawValuesAreStable() {
        XCTAssertEqual(UpdateChannel.stable.rawValue, "stable")
        XCTAssertEqual(UpdateChannel.beta.rawValue,   "beta")
    }

    func test_updateChannel_allCases_isExhaustive() {
        XCTAssertEqual(Set(UpdateChannel.allCases.map(\.rawValue)), ["stable", "beta"])
    }
}
