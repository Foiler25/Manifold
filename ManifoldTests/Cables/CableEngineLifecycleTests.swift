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
// CableEngineLifecycleTests.swift
//
// Phase 21 — locks in the windowDidAppear/attach race fix. SwiftUI's
// `onAppear` can fire before NSApplicationDelegate's
// `applicationDidFinishLaunching` returns, which means
// `cableEngineLifecycle.windowDidAppear()` may run before
// `cableEngineLifecycle.attach(engine)`. Without the replay-on-attach
// fix, that drops the start signal — engine never runs, Cables tab
// stays on the loading state. Production logs (see
// `app:com.Loofa.Manifold` Console output, 2026-05-06 17:40:47)
// confirmed the race.

import XCTest
@testable import Manifold

@MainActor
final class CableEngineLifecycleTests: XCTestCase {

    // MARK: - Race fix

    func test_windowDidAppearBeforeAttach_startsEngineOnAttach() async {
        let lifecycle = CableEngineLifecycle()
        let engine = CableEngine(
            provider: StubCableProvider(snapshots: [CableSummaryFixtures.oneEmptyPort], trailingError: nil)
        )

        // SwiftUI fires onAppear before applicationDidFinishLaunching
        // completes — windowDidAppear lands first, with no engine yet.
        lifecycle.windowDidAppear()
        XCTAssertFalse(engine.isRunning, "Engine has no reference; can't start yet")

        // applicationDidFinishLaunching runs and attaches the engine.
        // The replay-on-attach kicks the engine immediately because
        // the window is already visible.
        lifecycle.attach(engine)
        XCTAssertTrue(engine.isRunning, "Engine should start once attached if window is already visible")
    }

    // MARK: - Normal ordering

    func test_attachThenWindowDidAppear_startsEngine() {
        let lifecycle = CableEngineLifecycle()
        let engine = CableEngine(
            provider: StubCableProvider(snapshots: [], trailingError: nil)
        )

        lifecycle.attach(engine)
        XCTAssertFalse(engine.isRunning)
        lifecycle.windowDidAppear()
        XCTAssertTrue(engine.isRunning)
    }

    // MARK: - Disappear semantics

    func test_windowDidDisappear_stopsEngine() {
        let lifecycle = CableEngineLifecycle()
        let engine = CableEngine(
            provider: StubCableProvider(snapshots: [], trailingError: nil)
        )

        lifecycle.attach(engine)
        lifecycle.windowDidAppear()
        XCTAssertTrue(engine.isRunning)

        lifecycle.windowDidDisappear()
        XCTAssertFalse(engine.isRunning)
    }

    func test_multipleSurfacesOnlyStopAfterLastDisappears() {
        let lifecycle = CableEngineLifecycle()
        let engine = CableEngine(provider: StubCableProvider(snapshots: [], trailingError: nil))
        lifecycle.attach(engine)

        lifecycle.surfaceDidAppear("main")
        lifecycle.surfaceDidAppear("pro.power")
        lifecycle.surfaceDidAppear("pro.power")
        XCTAssertTrue(engine.isRunning)

        lifecycle.surfaceDidDisappear("main")
        XCTAssertTrue(engine.isRunning)
        lifecycle.surfaceDidDisappear("pro.power")
        XCTAssertFalse(engine.isRunning)
    }

    func test_windowDidDisappearBeforeAttach_doesNotStartOnAttach() {
        // If the user closed the window between launch and attach
        // (impossible in practice but tested for completeness), the
        // engine should not start when attach runs.
        let lifecycle = CableEngineLifecycle()
        let engine = CableEngine(
            provider: StubCableProvider(snapshots: [], trailingError: nil)
        )

        lifecycle.windowDidAppear()
        lifecycle.windowDidDisappear()
        lifecycle.attach(engine)
        XCTAssertFalse(engine.isRunning)
    }

    // MARK: - Shutdown

    func test_shutdown_isIdempotent_andStopsEngine() {
        let lifecycle = CableEngineLifecycle()
        let engine = CableEngine(
            provider: StubCableProvider(snapshots: [], trailingError: nil)
        )

        lifecycle.attach(engine)
        lifecycle.windowDidAppear()
        XCTAssertTrue(engine.isRunning)

        lifecycle.shutdown()
        XCTAssertTrue(lifecycle.isShutDown)
        XCTAssertFalse(engine.isRunning)

        // Subsequent windowDidAppear should be a no-op after shutdown.
        lifecycle.windowDidAppear()
        XCTAssertFalse(engine.isRunning)

        // shutdown() is idempotent.
        lifecycle.shutdown()
        XCTAssertTrue(lifecycle.isShutDown)
    }
}
