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

// Helper: build a minimal PortPowerSample with just the fields
// RegressionAccumulator cares about. adapterVoltage < configuredVoltage
// gives a positive voltage drop (cable resistance signal).
private func portSample(
    configuredVoltage: Int,
    configuredCurrent: Int,
    adapterVoltage: Int,
    current: Int,
    portKey: String = "2/1"
) -> PortPowerSample {
    PortPowerSample(
        portIndex: 1,
        portKey: portKey,
        current: current,
        watts: configuredVoltage * configuredCurrent / 1000,
        configuredVoltage: configuredVoltage,
        configuredCurrent: configuredCurrent,
        adapterVoltage: adapterVoltage,
        vconnCurrent: 0,
        vconnPower: 0
    )
}

@Suite("RegressionAccumulator")
struct RegressionAccumulatorTests {

    // MARK: - Per-cable reset

    @Test("Samples from cable A are discarded when cable B is plugged in")
    func perCableReset() {
        var acc = RegressionAccumulator(settleSkipCount: 0, maxSamples: 120)

        // Cable A: 20V / 3A contract (60W). Settle window = 0 for this test.
        let cableA = portSample(
            configuredVoltage: 20_000, configuredCurrent: 3_000,
            adapterVoltage: 19_700, current: 2_500
        )
        // Feed 12 ticks of cable A to build up a buffer.
        for _ in 0..<12 {
            acc.append(portSamples: [cableA])
        }
        #expect(acc.samples.count == 12)

        // Cable B: 20V / 5A contract (100W). Contract fingerprint changes.
        let cableB = portSample(
            configuredVoltage: 20_000, configuredCurrent: 5_000,
            adapterVoltage: 19_600, current: 4_000
        )
        acc.append(portSamples: [cableB])

        // Cable A samples must be gone; only cable B's sample (accepted after
        // the reset because settleSkipCount = 0) should be present.
        #expect(acc.samples.count == 1, "All cable A samples must be cleared on contract change")
        #expect(acc.lastFingerprint?.configuredCurrent == 5_000)
    }

    @Test("Fingerprint is unchanged when the same cable is still plugged in")
    func sameContractAccumulates() {
        var acc = RegressionAccumulator(settleSkipCount: 0, maxSamples: 120)
        let sample = portSample(
            configuredVoltage: 20_000, configuredCurrent: 3_000,
            adapterVoltage: 19_700, current: 2_500
        )
        for _ in 0..<15 {
            acc.append(portSamples: [sample])
        }
        #expect(acc.samples.count == 15, "Steady contract must accumulate without reset")
    }

    // MARK: - Transient rejection

    @Test("Samples in the settle window are rejected")
    func settleWindowRejectsTransients() {
        // settleSkipCount = 3: ticks 0, 1, 2 after a change are discarded.
        var acc = RegressionAccumulator(settleSkipCount: 3, maxSamples: 120)

        let sample = portSample(
            configuredVoltage: 20_000, configuredCurrent: 3_000,
            adapterVoltage: 19_700, current: 2_500
        )

        // First call always triggers a "first-ever" fingerprint change.
        let accepted0 = acc.append(portSamples: [sample])
        #expect(!accepted0, "Tick 0 (first call) is in the settle window and must be rejected")
        #expect(acc.samples.isEmpty)

        let accepted1 = acc.append(portSamples: [sample])
        #expect(!accepted1, "Tick 1 still in the settle window")
        #expect(acc.samples.isEmpty)

        let accepted2 = acc.append(portSamples: [sample])
        #expect(!accepted2, "Tick 2 still in the settle window")
        #expect(acc.samples.isEmpty)

        // Tick 3: settle window expired, sample should be accepted.
        let accepted3 = acc.append(portSamples: [sample])
        #expect(accepted3, "Tick 3 is past the settle window and must be accepted")
        #expect(acc.samples.count == 1)
    }

    @Test("New contract change resets the settle countdown")
    func contractChangeResetsSettleCountdown() {
        var acc = RegressionAccumulator(settleSkipCount: 3, maxSamples: 120)

        let sampleA = portSample(
            configuredVoltage: 20_000, configuredCurrent: 3_000,
            adapterVoltage: 19_700, current: 2_500
        )
        // Burn through 3 settle ticks for cable A.
        for _ in 0..<3 {
            acc.append(portSamples: [sampleA])
        }
        // Tick 4 lands past settle window.
        let accepted = acc.append(portSamples: [sampleA])
        #expect(accepted)
        #expect(acc.samples.count == 1)

        // Cable B plugged in mid-session. New fingerprint resets countdown.
        let sampleB = portSample(
            configuredVoltage: 20_000, configuredCurrent: 5_000,
            adapterVoltage: 19_600, current: 4_000
        )
        // This call triggers the reset and starts a fresh settle window.
        let rejectedAfterChange = acc.append(portSamples: [sampleB])
        #expect(!rejectedAfterChange, "First tick after cable change must be in the settle window")
        #expect(acc.samples.isEmpty, "Cable A samples must be cleared on the new contract change")
    }

    // MARK: - Clean run (regression guard)

    @Test("Steady stream produces a resistance estimate with sufficient spread")
    func cleanRunProducesEstimate() {
        // settleSkipCount = 0 to skip the settle delay and reach sample count quickly.
        var acc = RegressionAccumulator(settleSkipCount: 0, maxSamples: 120)

        // Simulate a slowly varying load: current steps from 1000 mA to 4000 mA
        // with a fixed cable resistance of ~200 mOhm (0.2 ohm).
        // V_drop = R * I = 0.2 * I[A] = I[mA] * 0.2 / 1000 [V] * 1000 [mV/V]
        // = I[mA] * 0.2 mV/mA. At 1000 mA drop = 200 mV, at 4000 mA drop = 800 mV.
        let configuredVoltage = 20_000
        let configuredCurrent = 5_000
        var allAccepted = true
        for i in 0..<30 {
            let current = 1_000 + (i * 100)  // 1000..3900 mA
            let voltageDrop = Int(Double(current) * 0.2)
            let adapterVoltage = configuredVoltage - voltageDrop
            let sample = portSample(
                configuredVoltage: configuredVoltage,
                configuredCurrent: configuredCurrent,
                adapterVoltage: adapterVoltage,
                current: current
            )
            if !acc.append(portSamples: [sample]) {
                allAccepted = false
            }
        }
        #expect(allAccepted, "All 30 samples in a clean steady run must be accepted")
        #expect(acc.samples.count == 30)

        // Verify the current spread exceeds 200 mA (required for a useful estimate).
        let minCurrent = acc.samples.map(\.current).min() ?? 0
        let maxCurrent = acc.samples.map(\.current).max() ?? 0
        #expect(maxCurrent - minCurrent > 200,
                "Spread must exceed 200 mA for the estimate to be reliable")
    }

    // MARK: - Buffer cap

    @Test("Sample buffer is capped at maxSamples")
    func bufferCap() {
        var acc = RegressionAccumulator(settleSkipCount: 0, maxSamples: 10)
        let sample = portSample(
            configuredVoltage: 20_000, configuredCurrent: 3_000,
            adapterVoltage: 19_700, current: 2_500
        )
        for _ in 0..<20 {
            acc.append(portSamples: [sample])
        }
        #expect(acc.samples.count == 10, "Buffer must not exceed maxSamples")
    }
}
