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

@Suite("Cable resistance tier (spec-anchored)")
struct CableResistanceTierTests {

    private func estimate(_ mOhm: Double, _ status: CableResistanceEstimate.Status = .stable)
        -> CableResistanceEstimate {
        CableResistanceEstimate(milliohms: mOhm, sampleCount: 40, rSquared: 0.9, status: status)
    }

    @Test("Non-stable estimates have no tier")
    func nonStableNil() {
        #expect(estimate(50, .converging).tier(ratedFiveA: true) == nil)
        #expect(estimate(50, .insufficient).tier(ratedFiveA: false) == nil)
        #expect(estimate(50, .unreliable).tier(ratedFiveA: true) == nil)
    }

    @Test("5 A budget: good < 100, marginal 100-150, high > 150")
    func fiveAmpBudget() {
        #expect(estimate(99).tier(ratedFiveA: true) == .good)
        #expect(estimate(100).tier(ratedFiveA: true) == .marginal)
        #expect(estimate(150).tier(ratedFiveA: true) == .marginal)
        #expect(estimate(151).tier(ratedFiveA: true) == .high)
    }

    @Test("3 A budget: good < 165, marginal 165-250, high > 250")
    func threeAmpBudget() {
        #expect(estimate(164).tier(ratedFiveA: false) == .good)
        #expect(estimate(165).tier(ratedFiveA: false) == .marginal)
        #expect(estimate(250).tier(ratedFiveA: false) == .marginal)
        #expect(estimate(251).tier(ratedFiveA: false) == .high)
    }

    @Test("The old 300 mOhm reading is now High, not Marginal")
    func oldThresholdRegression() {
        // The bug this fixes: 280 mOhm used to read "Marginal" (orange). It's
        // out of spec for every rating now.
        #expect(estimate(280).tier(ratedFiveA: false) == .high)
        #expect(estimate(280).tier(ratedFiveA: true) == .high)
    }
}
