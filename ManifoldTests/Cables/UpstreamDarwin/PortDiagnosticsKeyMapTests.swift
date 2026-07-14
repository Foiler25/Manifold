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
import Foundation
import Testing

@Suite("PortDiagnosticsWatcher port-key mapping")
struct PortDiagnosticsKeyMapTests {

    @Test("AppleSmartBattery property changes trigger a contract refresh")
    func propertyChangesTriggerRefresh() {
        // 0x130 is the IOMessage payload for a service property change. The
        // watcher refreshes on every kIOGeneralInterest callback so it also
        // remains robust to SDKs where the composed C macro is not importable.
        #expect(PortDiagnosticsWatcher.shouldRefresh(for: 0x130))
    }

    @Test("An all-zero controller entry does not create a false PD contract")
    func zeroContractIsNil() {
        #expect(PortDiagnosticsWatcher.contract(from: [
            "PortControllerActiveContractRdo": 0,
            "PortControllerMaxPower": 0,
            "PortControllerNPDOs": 0,
            "PortControllerPortPDO": []
        ]) == nil)
    }

    @Test("A live controller contract is retained")
    func activeContractIsPublished() {
        let contract = PortDiagnosticsWatcher.contract(from: [
            "PortControllerActiveContractRdo": UInt32(1 << 28),
            "PortControllerMaxPower": 65_000,
            "PortControllerNPDOs": 1,
            "PortControllerPortPDO": [UInt32(0x0001912C)]
        ])
        #expect(contract?.maxPower == 65_000)
    }

    // Build a self-keyed PowerSource with a winning contract of `watts` mW.
    private func source(port: Int, type: Int = 2, watts: Int) -> PowerSource {
        PowerSource(
            id: UInt64(port), name: "USB-PD",
            parentPortType: type, parentPortNumber: port, options: [],
            winning: PowerOption(voltageMV: 20000, maxCurrentMA: 5000, maxPowerMW: watts)
        )
    }

    // Build a PortControllerInfo entry dict with the given max power.
    private func entry(maxPowerMW: Int) -> [String: Any] {
        ["PortControllerMaxPower": maxPowerMW]
    }

    // MARK: - Watts-based join for active-contract entries

    @Test("Charger entry maps to the source's port key regardless of array offset")
    func chargerMapsToSourcePort() {
        // Three entries: two idle ports flanking a 100 W charger at offset 2.
        let entries = [entry(maxPowerMW: 0), entry(maxPowerMW: 0), entry(maxPowerMW: 100_000)]
        let portKeys = ["2/1", "2/2", "2/3", "2/4"]
        let sources = [source(port: 4, watts: 100_000)]

        let map = PortDiagnosticsWatcher.portKeyMap(entries: entries, portKeys: portKeys, sources: sources)

        // Offset 2 (the charger) must map to "2/4" (the source's port), not "2/3"
        // (what the old array-offset code would have produced).
        #expect(map[2] == "2/4")
    }

    @Test("Idle entries fall back to positional HPM order (contiguous ports)")
    func idleEntriesUsePositionalFallback() {
        // Four idle ports, no active charge contract.
        let entries = [entry(maxPowerMW: 0), entry(maxPowerMW: 0),
                       entry(maxPowerMW: 0), entry(maxPowerMW: 0)]
        let portKeys = ["2/1", "2/2", "2/3", "2/4"]

        let map = PortDiagnosticsWatcher.portKeyMap(entries: entries, portKeys: portKeys, sources: [])

        // Positional fallback: offset N -> portKeys[N].
        #expect(map[0] == "2/1")
        #expect(map[1] == "2/2")
        #expect(map[2] == "2/3")
        #expect(map[3] == "2/4")
    }

    @Test("Non-contiguous layout: charger at offset 1 maps to port 4, not port 2")
    func nonContiguousChargerLandsOnCorrectPort() {
        // Simulates the bug this fix addresses: PortControllerInfo offset does
        // not match port numbering. The charger is at offset 1 in the array but
        // belongs to port 4 (a non-contiguous assignment).
        let entries = [entry(maxPowerMW: 0), entry(maxPowerMW: 60_000)]
        let portKeys = ["2/1", "2/2"]  // HPM traversal order (not necessarily port order)
        let sources = [source(port: 4, watts: 60_000)]

        let map = PortDiagnosticsWatcher.portKeyMap(entries: entries, portKeys: portKeys, sources: sources)

        // Old offset code: map[1] = portKeys[1] = "2/2" (wrong).
        // Watts join: map[1] = "2/4" (correct).
        #expect(map[1] == "2/4")
        // Idle port at offset 0 still uses positional fallback.
        #expect(map[0] == "2/1")
    }

    @Test("Every entry gets a key: no entry is silently dropped")
    func everyEntryGetsAKey() {
        let entries = [entry(maxPowerMW: 0), entry(maxPowerMW: 45_000), entry(maxPowerMW: 0)]
        let portKeys = ["2/1", "2/2", "2/3"]
        let sources = [source(port: 3, watts: 45_000)]

        let map = PortDiagnosticsWatcher.portKeyMap(entries: entries, portKeys: portKeys, sources: sources)

        #expect(map.count == entries.count)
        #expect(map[0] != nil)
        #expect(map[1] != nil)
        #expect(map[2] != nil)
    }

    @Test("Overflow entries beyond known HPM ports get a best-effort fallback key")
    func overflowEntriesGetFallbackKey() {
        // Two HPM port keys but three PortControllerInfo entries.
        let entries = [entry(maxPowerMW: 0), entry(maxPowerMW: 0), entry(maxPowerMW: 0)]
        let portKeys = ["2/1", "2/2"]

        let map = PortDiagnosticsWatcher.portKeyMap(entries: entries, portKeys: portKeys, sources: [])

        #expect(map[0] == "2/1")
        #expect(map[1] == "2/2")
        // Offset 2 exceeds portKeys: gets "2/3" (1-based fallback).
        #expect(map[2] == "2/3")
    }

    @Test("Empty entries produce an empty map")
    func emptyEntriesEmptyMap() {
        let map = PortDiagnosticsWatcher.portKeyMap(entries: [], portKeys: ["2/1"], sources: [])
        #expect(map.isEmpty)
    }

    @Test("Ambiguous wattage (two ports at same watts) falls back to positional")
    func ambiguousWattsFallsBackToPositional() {
        // Two ports both receiving 60 W: watts-join is ambiguous and omits the
        // entry. The positional fallback should still assign a key.
        let entries = [entry(maxPowerMW: 60_000)]
        let portKeys = ["2/1"]
        let sources = [source(port: 1, watts: 60_000), source(port: 2, watts: 60_000)]

        let map = PortDiagnosticsWatcher.portKeyMap(entries: entries, portKeys: portKeys, sources: sources)

        // Watts join skips the ambiguous entry; positional fallback covers it.
        #expect(map[0] == "2/1")
    }
}
