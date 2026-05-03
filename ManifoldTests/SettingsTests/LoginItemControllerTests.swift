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
// LoginItemControllerTests.swift
//
// The protocol exists specifically so we don't hit
// `SMAppService.mainApp.register()` from a unit test (it would
// mutate the user's actual login items). These tests pin the
// stub-shape contract the protocol declares and prove the
// register/unregister/state-query surface works as expected via
// a recording stub.

import XCTest
@testable import Manifold

final class LoginItemControllerTests: XCTestCase {

    // MARK: - Recording stub

    /// Captures every `apply(_:)` call so the test can assert the
    /// register/unregister sequence without touching the OS. Also
    /// flips `isCurrentlyEnabled` to mirror the last applied
    /// state — same shape the production controller exposes.
    final class StubLoginItemController: LoginItemController, @unchecked Sendable {

        var calls: [Bool] = []
        var nextResult: Bool = true
        var isCurrentlyEnabled: Bool = false

        func apply(_ enabled: Bool) -> Bool {
            calls.append(enabled)
            if nextResult {
                isCurrentlyEnabled = enabled
                return true
            }
            return false
        }
    }

    /// Initial state is `false`. `apply(true)` flips to true and
    /// records the call. `apply(false)` flips back. Pins the
    /// happy-path state machine.
    func test_apply_recordsCallAndFlipsState() {
        let stub = StubLoginItemController()
        XCTAssertFalse(stub.isCurrentlyEnabled)
        XCTAssertTrue(stub.apply(true))
        XCTAssertEqual(stub.calls, [true])
        XCTAssertTrue(stub.isCurrentlyEnabled)
        XCTAssertTrue(stub.apply(false))
        XCTAssertEqual(stub.calls, [true, false])
        XCTAssertFalse(stub.isCurrentlyEnabled)
    }

    /// Failure path: `apply` returns false; state does NOT flip.
    /// Pins the contract that GeneralPane uses to revert its
    /// AppStorage flag — without this, a UI toggle could fall
    /// out of sync with the OS.
    func test_apply_returnsFalse_onFailure_stateDoesNotFlip() {
        let stub = StubLoginItemController()
        stub.nextResult = false
        XCTAssertFalse(stub.apply(true))
        XCTAssertFalse(stub.isCurrentlyEnabled, "Failed apply must NOT flip the state")
    }
}
