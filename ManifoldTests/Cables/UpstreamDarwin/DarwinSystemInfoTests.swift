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

/// `fetchMacModel` is a thin wrapper around the `hw.model` sysctl. There's
/// no fake sysctl to swap in, so this just checks it returns something
/// sane on the real hardware running the test, mirroring how other Reading/
/// tests (e.g. SMCPowerReaderTests) treat live IOKit/sysctl reads.
struct DarwinSystemInfoTests {
    @Test("fetchMacModel returns a non-empty model string")
    func fetchMacModelReturnsNonEmptyString() {
        let model = DarwinSystemInfo.fetchMacModel()
        #expect(!model.isEmpty)
        // "unknown" is only the fallback for a failed sysctl call; on any
        // real Mac running this test, the call succeeds.
        #expect(model != "unknown")
    }
}
