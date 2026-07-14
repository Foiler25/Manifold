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
// Portions of this file derive from WhatCable
// (https://github.com/darrylmorley/whatcable) by Darryl Morley,
// originally distributed under the MIT licence. See
// `Manifold/Sources/Cables/ATTRIBUTION.md` for the full original
// copyright + permission notice.
//
// ─────────────────────────────────────────────────────────────────────
@testable import Manifold
import Testing
import Foundation

@Suite("Connection diagnostic (mid-session counter deltas)")
struct ConnectionDiagnosticTests {

    // MARK: SessionDelta arithmetic

    @Test("Delta is the rise from baseline to current")
    func deltaRise() {
        let baseline = ConnectionCounters(plugEvents: 10, overcurrents: 0)
        let current = ConnectionCounters(plugEvents: 13, overcurrents: 1)
        let delta = SessionDelta(baseline: baseline, current: current)
        #expect(delta.plugEvents == 3)
        #expect(delta.overcurrents == 1)
        #expect(!delta.isClean)
    }

    @Test("No change is a clean delta")
    func deltaClean() {
        let counters = ConnectionCounters(plugEvents: 7, overcurrents: 2)
        let delta = SessionDelta(baseline: counters, current: counters)
        #expect(delta.isClean)
        #expect(delta.plugEvents == 0)
    }

    @Test("A controller reset (count goes backwards) clamps to zero")
    func deltaClampsNegative() {
        let baseline = ConnectionCounters(plugEvents: 50, overcurrents: 3)
        let current = ConnectionCounters(plugEvents: 1, overcurrents: 0)
        let delta = SessionDelta(baseline: baseline, current: current)
        #expect(delta.isClean)
    }

    @Test("Missing counters at baseline contribute zero, never a phantom fault")
    func deltaMissingCounters() {
        let baseline = ConnectionCounters(plugEvents: nil, overcurrents: nil)
        let current = ConnectionCounters(plugEvents: 5, overcurrents: 2)
        let delta = SessionDelta(baseline: baseline, current: current)
        #expect(delta.isClean)
    }

    @Test("A nil overcurrent baseline does not manufacture a trip (conservative by design)")
    func nilOvercurrentBaselineStaysClean() {
        // The counter was unreadable at connect and reads 1 later. We cannot
        // tell whether that 1 happened this session or is lifetime history
        // from a previous cable, so we report nothing rather than falsely
        // accuse this cable. A value present at baseline (next test) is caught.
        let baseline = ConnectionCounters(plugEvents: 0, overcurrents: nil)
        let current = ConnectionCounters(plugEvents: 0, overcurrents: 1)
        let delta = SessionDelta(baseline: baseline, current: current)
        #expect(delta.overcurrents == 0)
        #expect(ConnectionDiagnostic(delta: delta, elapsedSeconds: 60) == nil)
    }

    @Test("An overcurrent present at baseline catches a later trip")
    func anchoredOvercurrentBaselineCatchesTrip() throws {
        let baseline = ConnectionCounters(plugEvents: 0, overcurrents: 0)
        let current = ConnectionCounters(plugEvents: 0, overcurrents: 1)
        let delta = SessionDelta(baseline: baseline, current: current)
        #expect(delta.overcurrents == 1)
        let diag = try #require(ConnectionDiagnostic(delta: delta, elapsedSeconds: 60))
        #expect(diag.fault == .overcurrent(count: 1))
    }

    // MARK: Diagnostic tiers

    @Test("Clean session produces no banner")
    func cleanNoBanner() {
        let delta = SessionDelta(plugEvents: 0, overcurrents: 0)
        #expect(ConnectionDiagnostic(delta: delta, elapsedSeconds: 120) == nil)
    }

    @Test("A single plug event is below the bar (normal reconnect)")
    func singleDropNoBanner() {
        let delta = SessionDelta(plugEvents: 1, overcurrents: 0)
        #expect(ConnectionDiagnostic(delta: delta, elapsedSeconds: 120) == nil)
    }

    @Test("Two or more plug events is an amber drops caution")
    func repeatedDropsCaution() throws {
        let delta = SessionDelta(plugEvents: 3, overcurrents: 0)
        let diag = try #require(ConnectionDiagnostic(delta: delta, elapsedSeconds: 180))
        #expect(diag.severity == .caution)
        #expect(diag.fault == .repeatedDrops(count: 3))
        #expect(diag.summary.contains("3"))
    }

    @Test("One overcurrent trip is an orange warning")
    func overcurrentWarning() throws {
        let delta = SessionDelta(plugEvents: 0, overcurrents: 1)
        let diag = try #require(ConnectionDiagnostic(delta: delta, elapsedSeconds: 30))
        #expect(diag.severity == .warning)
        #expect(diag.fault == .overcurrent(count: 1))
    }

    @Test("Overcurrent outranks drops when both fire")
    func overcurrentOutranksDrops() throws {
        let delta = SessionDelta(plugEvents: 5, overcurrents: 1)
        let diag = try #require(ConnectionDiagnostic(delta: delta, elapsedSeconds: 60))
        #expect(diag.fault == .overcurrent(count: 1))
        #expect(diag.severity == .warning)
    }

    // MARK: Elapsed window phrasing

    @Test("Under a minute and a half reads as the last minute")
    func windowSingleMinute() {
        #expect(ConnectionDiagnostic.window(45) == "in the last minute")
        #expect(ConnectionDiagnostic.window(80) == "in the last minute")
    }

    @Test("Multi-minute sessions read the rounded minute count")
    func windowMultipleMinutes() {
        #expect(ConnectionDiagnostic.window(180) == "in the last 3 minutes")
        #expect(ConnectionDiagnostic.window(600) == "in the last 10 minutes")
    }

    @Test("A zero elapsed never reads as zero minutes")
    func windowFloorsAtOne() {
        #expect(ConnectionDiagnostic.window(0) == "in the last minute")
    }

    @Test("Rounding edges floor to one minute, never zero")
    func windowRoundingEdges() {
        // 30s rounds to 0 minutes (round-half-to-even), so the max(1,...)
        // floor is load-bearing, not redundant. 90s rounds to 2 (the boundary
        // into the plural branch). Both are exercised here so neither silently
        // regresses.
        #expect(ConnectionDiagnostic.window(30) == "in the last minute")
        #expect(ConnectionDiagnostic.window(90) == "in the last 2 minutes")
    }

    @Test("The drops detail names the elapsed window")
    func dropsDetailMentionsWindow() throws {
        let delta = SessionDelta(plugEvents: 2, overcurrents: 0)
        let diag = try #require(ConnectionDiagnostic(delta: delta, elapsedSeconds: 300))
        #expect(diag.detail.contains("5 minutes"))
    }
}
