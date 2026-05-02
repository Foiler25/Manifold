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
// SamplerLifecycleTests.swift
//
// Per SPEC.md §17 ("lifecycle pause/resume on surface count
// changes") and SPEC §18 Phase 5 acceptance #3. The sampler integration
// itself is covered manually (the timer firing is not a unit-testable
// concern); these tests cover the surface-count math and pause/resume
// dispatch.
//
// `TelemetrySampler` is what the lifecycle drives, but instantiating
// a real one starts a real Timer. We sub in a real sampler with
// `EventService(notificationCenter: nil)` so no IOKit thread spawns
// — we just need `start()`/`stop()` to flip `isRunning`.

import XCTest
@testable import Manifold

@MainActor
final class SamplerLifecycleTests: XCTestCase {

    // MARK: - Setup

    private func makeSampler() -> TelemetrySampler {
        TelemetrySampler(
            walker: USBWalker(source: NoOpSource()),
            eventService: EventService(notificationCenter: nil)
        )
    }

    /// A walker source that returns no devices — keeps the sampler's
    /// tick path benign during tests so we never fire actual events.
    private struct NoOpSource: USBRegistrySource {
        func enumerate() throws -> [USBDeviceSnapshot] { [] }
    }

    // MARK: - Surface counter

    /// Initial state: no surfaces, sampler not running.
    func test_initialState_noSurfacesSamplerNotRunning() {
        let sampler = makeSampler()
        let lifecycle = SamplerLifecycle(sampler: sampler)
        XCTAssertEqual(lifecycle.activeSurfaceCount, 0)
        XCTAssertFalse(sampler.isRunning)
    }

    /// One popover open → sampler running.
    func test_popoverDidOpen_startsSampler() {
        let sampler = makeSampler()
        let lifecycle = SamplerLifecycle(sampler: sampler)

        lifecycle.popoverDidOpen()

        XCTAssertEqual(lifecycle.activeSurfaceCount, 1)
        XCTAssertTrue(sampler.isRunning)

        sampler.stop()  // tidy
    }

    /// Open + close balance to zero → sampler stops.
    func test_popoverOpenThenClose_stopsSampler() {
        let sampler = makeSampler()
        let lifecycle = SamplerLifecycle(sampler: sampler)

        lifecycle.popoverDidOpen()
        XCTAssertTrue(sampler.isRunning)

        lifecycle.popoverDidClose()
        XCTAssertEqual(lifecycle.activeSurfaceCount, 0)
        XCTAssertFalse(sampler.isRunning)
    }

    /// Two surfaces (popover + window) → close one → sampler still
    /// running because count is still > 0. SPEC §18 Phase 5 #3:
    /// "pauses sampling when popover hidden AND window not visible"
    /// — single closes don't pause.
    func test_twoSurfaces_oneClose_keepsSamplerRunning() {
        let sampler = makeSampler()
        let lifecycle = SamplerLifecycle(sampler: sampler)

        lifecycle.popoverDidOpen()
        lifecycle.windowDidAppear()
        XCTAssertEqual(lifecycle.activeSurfaceCount, 2)
        XCTAssertTrue(sampler.isRunning)

        lifecycle.popoverDidClose()
        XCTAssertEqual(lifecycle.activeSurfaceCount, 1)
        XCTAssertTrue(sampler.isRunning, "Window still visible — sampler stays running.")

        lifecycle.windowDidDisappear()
        XCTAssertEqual(lifecycle.activeSurfaceCount, 0)
        XCTAssertFalse(sampler.isRunning)
    }

    /// Unbalanced close (close without prior open) doesn't go negative.
    /// Belt-and-suspenders for UI lifecycle quirks.
    func test_unbalancedClose_doesNotGoNegative() {
        let sampler = makeSampler()
        let lifecycle = SamplerLifecycle(sampler: sampler)

        lifecycle.popoverDidClose()
        XCTAssertEqual(lifecycle.activeSurfaceCount, 0, "Floors at zero.")
        XCTAssertFalse(sampler.isRunning)
    }

    // MARK: - Late attach

    /// `attach(sampler:)` after a surface is already active → sampler
    /// kicks immediately. Used by AppDelegate which constructs
    /// lifecycle and sampler in different statements.
    func test_lateAttach_withActiveSurface_startsSampler() {
        let lifecycle = SamplerLifecycle()
        lifecycle.popoverDidOpen()  // sampler not yet attached, no-op on sampler

        let sampler = makeSampler()
        lifecycle.attach(sampler: sampler)

        XCTAssertTrue(sampler.isRunning, "Late attach with active surface should start the sampler.")
        sampler.stop()
    }

    // MARK: - Shutdown

    /// `shutdown()` zeros the count and stops the sampler. Idempotent.
    func test_shutdown_stopsSamplerAndIsIdempotent() {
        let sampler = makeSampler()
        let lifecycle = SamplerLifecycle(sampler: sampler)
        lifecycle.popoverDidOpen()
        XCTAssertTrue(sampler.isRunning)

        lifecycle.shutdown()
        XCTAssertEqual(lifecycle.activeSurfaceCount, 0)
        XCTAssertFalse(sampler.isRunning)
        XCTAssertTrue(lifecycle.isShutDown)

        // Idempotent — calling again is a no-op.
        lifecycle.shutdown()
        XCTAssertEqual(lifecycle.activeSurfaceCount, 0)
    }

    /// After shutdown, surface events are no-ops.
    func test_shutdown_subsequentSurfaceEventsAreIgnored() {
        let sampler = makeSampler()
        let lifecycle = SamplerLifecycle(sampler: sampler)
        lifecycle.shutdown()

        lifecycle.popoverDidOpen()
        XCTAssertEqual(lifecycle.activeSurfaceCount, 0, "Surface events after shutdown are dropped.")
        XCTAssertFalse(sampler.isRunning)
    }

    // MARK: - Sample-rate clamping (TelemetrySampler-side, but adjacent)

    func test_sampler_setSampleRate_clampsAboveMax() {
        let sampler = makeSampler()
        sampler.sampleRate = 99.0
        XCTAssertEqual(sampler.sampleRate, TelemetrySamplerConstants.maxRate)
    }

    func test_sampler_setSampleRate_clampsBelowMin() {
        let sampler = makeSampler()
        sampler.sampleRate = 0.01
        XCTAssertEqual(sampler.sampleRate, TelemetrySamplerConstants.minRate)
    }

    func test_sampler_setSampleRate_inRangePreserved() {
        let sampler = makeSampler()
        sampler.sampleRate = 2.5
        XCTAssertEqual(sampler.sampleRate, 2.5)
    }
}
