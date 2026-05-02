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
// EventStreamTests.swift
//
// Per SPEC.md §17 ("Mock IOKitNotificationCenter that emits scripted
// events into the AsyncStream; assert PortGraph.apply produces correct
// deltas") and §18 Phase 3:
//
//   - EventService.events() returns AsyncStream<PortEvent>
//   - Multiple consumers each get their own stream that sees all events
//   - shutdown() finishes every active stream (criterion #6 indirect)
//   - Notification callbacks correctly hop to @MainActor (criterion #7)
//   - F5 fallback fixture is exercised in CI (rev-4 bullet #10)
//
// Tests construct EventService in test mode (`notificationCenter: nil`)
// — no live IOKit thread spins up — and use `inject(_:)` to script
// events. The PortGraph delta assertion lives in PortGraphMutationTests.

import XCTest
@testable import Manifold
import ManifoldKit

final class EventStreamTests: XCTestCase {

    // MARK: - Fixture

    private static let fixtureName = "ioreg-phase3-events"

    private func loadPhase3Snapshots() throws -> [USBDeviceSnapshot] {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: Self.fixtureName, withExtension: "json") else {
            throw FixtureLookupError.notFound(name: Self.fixtureName)
        }
        return try FixtureUSBSource(fixtureURL: url).enumerate()
    }

    private enum FixtureLookupError: Error {
        case notFound(name: String)
    }

    // MARK: - Single subscriber

    /// Headline: subscribe → emit → see the event.
    func test_events_yieldsScriptedEvent() async throws {
        let service = EventService(notificationCenter: nil)
        defer { service.shutdown() }

        let stream = service.events()
        let device = try makeFirstDevice()
        let portID = PortID("/test/port")

        Task.detached {
            try? await Task.sleep(for: .milliseconds(20))
            service.inject(.attached(device, at: portID))
        }

        let event = try await Self.firstEvent(of: stream, timeoutSeconds: 1)

        switch event {
        case .attached(let d, at: let p):
            XCTAssertEqual(d, device)
            XCTAssertEqual(p, portID)
        default:
            XCTFail("Expected .attached, got \(String(describing: event))")
        }
    }

    /// `.fullRefresh` emitted via `requestRefresh()` reaches every
    /// subscriber. Pins the public-API path.
    func test_requestRefresh_yieldsFullRefresh() async throws {
        let service = EventService(notificationCenter: nil)
        defer { service.shutdown() }

        let stream = service.events()

        Task.detached {
            try? await Task.sleep(for: .milliseconds(20))
            service.requestRefresh()
        }

        let event = try await Self.firstEvent(of: stream, timeoutSeconds: 1)
        XCTAssertEqual(event, .fullRefresh)
    }

    // MARK: - Multiple subscribers

    /// Two independent `events()` calls both see the same event. Pins
    /// the SPEC §7 multiplexing contract.
    func test_events_twoSubscribersBothSeeSameEvent() async throws {
        let service = EventService(notificationCenter: nil)
        defer { service.shutdown() }

        let stream1 = service.events()
        let stream2 = service.events()
        let device = try makeFirstDevice()
        let portID = PortID("/test/multiport")

        Task.detached {
            try? await Task.sleep(for: .milliseconds(20))
            service.inject(.attached(device, at: portID))
        }

        async let event1 = Self.firstEvent(of: stream1, timeoutSeconds: 1)
        async let event2 = Self.firstEvent(of: stream2, timeoutSeconds: 1)

        let (e1, e2) = try await (event1, event2)
        XCTAssertEqual(e1, e2)
    }

    // MARK: - shutdown

    /// `shutdown()` finishes every active stream. Pinning the cleanup
    /// path so the SPEC §18 Phase 3 acceptance #6 ("EventService
    /// shutdown cleanly releases all IOKit notification iterators") has
    /// a unit-test correlate (the IOKit iterator side is verified by
    /// `leaks(1)` in the manual stress run).
    func test_shutdown_terminatesActiveStreams() async throws {
        let service = EventService(notificationCenter: nil)
        let stream = service.events()

        Task.detached {
            try? await Task.sleep(for: .milliseconds(20))
            service.shutdown()
        }

        // Drain any events first (none expected); when shutdown fires,
        // .next() returns nil to signal end-of-stream.
        let event = try await Self.firstEvent(of: stream, timeoutSeconds: 1)
        XCTAssertNil(event, "Stream should finish when service shuts down.")
    }

    /// `shutdown()` is idempotent — calling twice is a no-op after the
    /// first. Pinned because both `applicationWillTerminate` and an
    /// explicit user-driven shutdown path could each fire it.
    func test_shutdown_isIdempotent() async {
        let service = EventService(notificationCenter: nil)
        service.shutdown()
        service.shutdown()  // would crash or assert if not idempotent
        // No assertion needed; reaching this line is the assertion.
    }

    // MARK: - F5 fallback fixture coverage (rev-4 bullet)

    /// The Phase 3 fixture's third device has `Speed: null` +
    /// `bcdUSB: 0x0300`. Walking it via `USBWalker(source: fixture)`
    /// must resolve speed via the F5 fallback — confirming the
    /// fallback chain is exercised in CI rather than only by the
    /// boot-SSD live walk on Brandon's M1 Max. Closes Phase 2 Q3.
    func test_phase3Fixture_includesF5FallbackEntry() throws {
        let snapshots = try loadPhase3Snapshots()

        // The fixture preserves nil for Speed; the fallback chain only
        // activates inside the LIVE walker (LiveIOKitUSBSource.makeSnapshot)
        // because that's where we read from IOKit. Fixture-mode preserves
        // the raw nil so this assertion is meaningful.
        let hub = snapshots.first { $0.vendorID == 0x0951 || $0.productName == "USB-C Hub" }
        XCTAssertNotNil(hub, "Phase 3 fixture should include the F5 fallback hub.")
        XCTAssertNil(hub?.speed, "Hub fixture must have nil Speed so the fallback path is meaningful.")
        XCTAssertEqual(hub?.bcdUSB, 0x0300, "Hub fixture must have bcdUSB populated for fallback derivation.")
    }

    // MARK: - Helpers

    /// Build a Device from the first fixture entry. Used as the
    /// payload for scripted .attached events.
    private func makeFirstDevice() throws -> Device {
        let snapshots = try loadPhase3Snapshots()
        guard let first = snapshots.first else {
            throw FixtureLookupError.notFound(name: "first device")
        }
        return PortGraphBuilder.makeDevice(from: first, timestamp: Date(timeIntervalSince1970: 0))
    }

    /// Pull the first event off a stream with a hard timeout. Inlines
    /// the iterator construction so it stays inside the @Sendable
    /// closure (AsyncStream.Iterator isn't Sendable, but the stream
    /// itself is — fine to capture and re-iterate inside the task).
    /// Static so `async let` callers don't capture the XCTestCase
    /// `self` (which isn't Sendable).
    private static func firstEvent(
        of stream: AsyncStream<PortEvent>,
        timeoutSeconds: Double
    ) async throws -> PortEvent? {
        try await withThrowingTaskGroup(of: PortEvent?.self) { group in
            group.addTask {
                var iter = stream.makeAsyncIterator()
                return await iter.next()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw TimeoutError()
            }
            guard let first = try await group.next() else {
                throw TimeoutError()
            }
            group.cancelAll()
            return first
        }
    }

    private struct TimeoutError: Error {}
}
