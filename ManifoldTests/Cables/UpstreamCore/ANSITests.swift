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

/// Tests the pure `shouldEnable` decision logic only, not `configure(isTTY:)`
/// / `isEnabled` directly. Those two touch a single shared static
/// (`configuredIsTTY`), and Swift Testing can run test files in this target
/// concurrently in the same process; a test that flipped that shared value
/// could make TextFormatterTests' "No ANSI escapes in non-TTY output" test
/// flaky. `shouldEnable` takes both inputs as plain parameters, so it
/// exercises the exact same logic with no shared state involved.
@Suite("ANSI color decision")
struct ANSITests {
    @Test("Colour is on when stdout is a TTY and NO_COLOR is not set")
    func colorOnWhenTTYAndNoColorUnset() {
        #expect(ANSI.shouldEnable(isTTY: true, noColorSet: false))
    }

    @Test("Colour is off when stdout is not a TTY")
    func colorOffWhenNotTTY() {
        #expect(ANSI.shouldEnable(isTTY: false, noColorSet: false) == false)
    }

    @Test("Colour is off when NO_COLOR is set, even on a TTY")
    func colorOffWhenNoColorSet() {
        #expect(ANSI.shouldEnable(isTTY: true, noColorSet: true) == false)
    }

    @Test("Colour is off when neither a TTY nor NO_COLOR set is true")
    func colorOffWhenNeitherTrue() {
        #expect(ANSI.shouldEnable(isTTY: false, noColorSet: true) == false)
    }
}
