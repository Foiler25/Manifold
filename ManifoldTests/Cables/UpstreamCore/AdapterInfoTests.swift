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

/// Unit tests for CableAdapterInfo and AdapterHVCEntry.
@Suite("Adapter Info")
struct AdapterInfoTests {

    // MARK: - AdapterHVCEntry

    @Test("HVC entry watts calculation")
    func hvcEntryWatts() {
        let entry = AdapterHVCEntry(voltageMV: 20000, currentMA: 5000)
        #expect(entry.wattsInt == 100)
    }

    @Test("HVC entry watts rounding")
    func hvcEntryWattsRounding() {
        // 4990 mA * 20000 mV = 99.8W, rounds to 100
        let entry = AdapterHVCEntry(voltageMV: 20000, currentMA: 4990)
        #expect(entry.wattsInt == 100)
    }

    @Test("HVC entry label format")
    func hvcEntryLabel() {
        let entry = AdapterHVCEntry(voltageMV: 20000, currentMA: 4990)
        #expect(entry.label == "20V/4.99A")
    }

    @Test("HVC entry label at low voltage")
    func hvcEntryLabelLowVoltage() {
        let entry = AdapterHVCEntry(voltageMV: 5000, currentMA: 2960)
        #expect(entry.label == "5V/2.96A")
    }

    @Test("HVC entry Equatable conformance")
    func hvcEntryEquatable() {
        let a = AdapterHVCEntry(voltageMV: 9000, currentMA: 3000)
        let b = AdapterHVCEntry(voltageMV: 9000, currentMA: 3000)
        #expect(a == b)
    }

    @Test("HVC entry Hashable conformance")
    func hvcEntryHashable() {
        let a = AdapterHVCEntry(voltageMV: 5000, currentMA: 3000)
        let b = AdapterHVCEntry(voltageMV: 20000, currentMA: 5000)
        let set: Set<AdapterHVCEntry> = [a, b, a]
        #expect(set.count == 2)
    }

    // MARK: - CableAdapterInfo backward compatibility

    @Test("Minimal init keeps backward compatibility")
    func minimalInitStillWorks() {
        // Existing callers pass only (watts, isCharging, source).
        // New fields should all default to nil / empty.
        let info = CableAdapterInfo(watts: 100, isCharging: true, source: "AC")
        #expect(info.watts == 100)
        #expect(info.isCharging == true)
        #expect(info.source == "AC")
        #expect(info.voltageMV == nil)
        #expect(info.currentMA == nil)
        #expect(info.adapterDescription == nil)
        #expect(info.powerTier == nil)
        #expect(info.isWireless == nil)
        #expect(info.hvcMenu.isEmpty)
    }

    @Test("Full init populates all fields")
    func fullInit() {
        let menu = [
            AdapterHVCEntry(voltageMV: 5000, currentMA: 2960),
            AdapterHVCEntry(voltageMV: 9000, currentMA: 2980),
            AdapterHVCEntry(voltageMV: 15000, currentMA: 2990),
            AdapterHVCEntry(voltageMV: 20000, currentMA: 4990),
        ]
        let info = CableAdapterInfo(
            watts: 100,
            isCharging: nil,
            source: "AC",
            voltageMV: 20000,
            currentMA: 4990,
            adapterDescription: "pd charger",
            powerTier: 2,
            isWireless: false,
            hvcMenu: menu
        )
        #expect(info.watts == 100)
        #expect(info.voltageMV == 20000)
        #expect(info.currentMA == 4990)
        #expect(info.adapterDescription == "pd charger")
        #expect(info.powerTier == 2)
        #expect(info.isWireless == false)
        #expect(info.hvcMenu.count == 4)
        #expect(info.hvcMenu.last?.wattsInt == 100)
    }

    @Test("Equatable with HVC menu")
    func equatableWithHVCMenu() {
        let menu = [AdapterHVCEntry(voltageMV: 20000, currentMA: 5000)]
        let a = CableAdapterInfo(watts: 100, isCharging: nil, source: "AC", hvcMenu: menu)
        let b = CableAdapterInfo(watts: 100, isCharging: nil, source: "AC", hvcMenu: menu)
        #expect(a == b)
    }

    @Test("Not equal when HVC menu differs")
    func notEqualWhenHVCMenuDiffers() {
        let a = CableAdapterInfo(watts: 100, isCharging: nil, source: "AC",
                            hvcMenu: [AdapterHVCEntry(voltageMV: 20000, currentMA: 5000)])
        let b = CableAdapterInfo(watts: 100, isCharging: nil, source: "AC",
                            hvcMenu: [AdapterHVCEntry(voltageMV: 20000, currentMA: 3000)])
        #expect(a != b)
    }

    @Test("Nil adapter has all fields nil")
    func nilAdapterAllFieldsNil() {
        let info = CableAdapterInfo(watts: nil, isCharging: nil, source: nil)
        #expect(info.watts == nil)
        #expect(info.source == nil)
        #expect(info.hvcMenu.isEmpty)
    }
}
