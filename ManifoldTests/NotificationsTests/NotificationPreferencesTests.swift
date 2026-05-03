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
// NotificationPreferencesTests.swift
//
// Pin the defaults + read/write contract so a future "reset
// notifications" affordance or @AppStorage default mismatch
// surfaces here, not at runtime when the user's toggles silently
// flip.

import XCTest
@testable import Manifold

final class NotificationPreferencesTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "manifold-prefs-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// Fresh defaults → all three event-type toggles default to true.
    /// SPEC §18 Phase 9 #4 doesn't mandate a default direction, but
    /// the user-value-prop reasoning ("connect/disconnect feedback is
    /// the headline feature") says ON by default.
    func test_freshDefaults_allEventTypesEnabledByDefault() {
        let prefs = NotificationPreferences(defaults: defaults)
        XCTAssertTrue(prefs.connectEnabled)
        XCTAssertTrue(prefs.disconnectEnabled)
        XCTAssertTrue(prefs.diagnosticEnabled)
    }

    /// `didRequestAuthorization` defaults to false (we haven't asked
    /// yet on a fresh install).
    func test_freshDefaults_didRequestAuthorizationFalse() {
        let prefs = NotificationPreferences(defaults: defaults)
        XCTAssertFalse(prefs.didRequestAuthorization)
    }

    /// Setting a toggle off persists across instances reading the
    /// same defaults — the AppStorage View and the service-side
    /// reads agree on the same key namespace.
    func test_disablingConnect_persistsAcrossInstances() {
        var first = NotificationPreferences(defaults: defaults)
        first.connectEnabled = false

        let second = NotificationPreferences(defaults: defaults)
        XCTAssertFalse(second.connectEnabled)
    }

    /// Default-true semantics survive an explicit `false → true`
    /// round-trip — pins that we're using `defaults.object(...) as?
    /// Bool ?? true` (not `defaults.bool(...)` which would silently
    /// default to false on absence).
    func test_setFalseThenTrue_persistsTrue() {
        var prefs = NotificationPreferences(defaults: defaults)
        prefs.connectEnabled = false
        prefs.connectEnabled = true
        XCTAssertTrue(NotificationPreferences(defaults: defaults).connectEnabled)
    }

    /// AppStorage key constants match the runtime read paths.
    /// Pins the contract: if anyone renames a `Key.*` constant
    /// without updating @AppStorage in NotificationsPane, this test
    /// fires.
    func test_keyConstants_matchExpectedStrings() {
        XCTAssertEqual(NotificationPreferences.Key.connectEnabled,    "notifications.connect.enabled")
        XCTAssertEqual(NotificationPreferences.Key.disconnectEnabled, "notifications.disconnect.enabled")
        XCTAssertEqual(NotificationPreferences.Key.diagnosticEnabled, "notifications.diagnostic.enabled")
        XCTAssertEqual(NotificationPreferences.Key.didRequestAuthorization, "notifications.didRequestAuthorization")
    }
}
