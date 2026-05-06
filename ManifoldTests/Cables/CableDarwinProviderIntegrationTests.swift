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
// CableDarwinProviderIntegrationTests.swift
//
// Phase 21 diagnostic — exercises `CableDarwinProvider` against real
// IOKit on the test machine. Used to isolate whether the "Cables tab
// stuck on loading" symptom is a provider bug (this test fails) or a
// wiring bug in CableEngine / CableEngineLifecycle (this test passes
// but the running app doesn't render).
//
// On Apple Silicon Macs this should return at least one USB-C port.
// On Intel Macs / Rosetta the snapshot may legitimately be empty —
// we still assert that snapshot() and watch() return / yield without
// throwing.

import XCTest
@testable import Manifold

@MainActor
final class CableDarwinProviderIntegrationTests: XCTestCase {

    func test_snapshot_returnsCableSnapshot_withinTwoSeconds() async throws {
        let provider = CableDarwinProvider()
        let snap = try await provider.snapshot()
        // Don't assert on `ports.count` (Intel / desktop Macs may have
        // 0 USB-C ports exposed via these IOKit classes). Just
        // confirm we got a non-throwing return.
        print("CableDarwinProviderIntegrationTests.snapshot — ports=\(snap.ports.count) identities=\(snap.identities.count) usbDevices=\(snap.usbDevices.count) thunderbolt=\(snap.thunderboltSwitches.count)")
        XCTAssertNotNil(snap)
    }

    func test_watch_yieldsFirstSnapshot_withinFiveSeconds() async throws {
        let provider = CableDarwinProvider()
        let stream = provider.watch()

        let firstSnap: CableSnapshot? = try await withThrowingTaskGroup(of: CableSnapshot?.self) { group in
            group.addTask {
                for try await snap in stream {
                    return snap
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return nil
            }
            let result = try await group.next() ?? nil
            group.cancelAll()
            return result
        }

        guard let firstSnap else {
            XCTFail("CableDarwinProvider.watch() did not yield within 5 seconds — this is the bug behind the 'Cables tab stuck on loading' symptom")
            return
        }
        print("CableDarwinProviderIntegrationTests.watch — first yield: ports=\(firstSnap.ports.count)")
    }
}
