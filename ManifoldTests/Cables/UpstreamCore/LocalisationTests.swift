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

@Suite("Localisation")
struct LocalisationTests {

    @Test("English source strings resolve to themselves")
    func englishSourceStringsResolveToThemselves() {
        let sample = String(localized: "Nothing connected", bundle: _coreLocalizedBundle)
        #expect(sample == "Nothing connected")
    }

    @Test("Interpolated strings resolve")
    func interpolatedStringsResolve() {
        let result = String(
            localized: "Cable speed: \("USB 3.2 Gen 2 (10 Gbps)")",
            bundle: _coreLocalizedBundle
        )
        #expect(result == "Cable speed: USB 3.2 Gen 2 (10 Gbps)")
    }

    @Test("Missing locale gracefully falls back to readable English")
    func missingLocaleFallsBackToEnglish() {
        defer { setCoreLocale("") }
        setCoreLocale("zz-Missing")
        let sample = String(localized: "Nothing connected", bundle: _coreLocalizedBundle)
        #expect(sample == "Nothing connected")
    }
}
