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

@Suite("Display Current Mode")
struct DisplayCurrentModeTests {

    @Test("shortLabel names common Mac/monitor resolutions")
    func shortLabelNamesCommonResolutions() {
        #expect(DisplayCurrentMode(width: 5120, height: 2880, refreshHz: 60).shortLabel == "5K 60Hz")
        #expect(DisplayCurrentMode(width: 3840, height: 2160, refreshHz: 120).shortLabel == "4K 120Hz")
        #expect(DisplayCurrentMode(width: 2560, height: 1440, refreshHz: 144).shortLabel == "1440p 144Hz")
        #expect(DisplayCurrentMode(width: 1920, height: 1080, refreshHz: 60).shortLabel == "1080p 60Hz")
    }

    @Test("shortLabel rounds refresh and falls back to raw pixels")
    func shortLabelFallsBackToRawPixels() {
        // Unusual resolution: no friendly name, so show raw pixels.
        #expect(DisplayCurrentMode(width: 1234, height: 567, refreshHz: 59.94).shortLabel == "1234x567 60Hz")
    }
}
