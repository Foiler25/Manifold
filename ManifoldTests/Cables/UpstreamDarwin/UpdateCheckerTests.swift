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

@Suite("Update Checker")
struct UpdateCheckerTests {
    @Test("Remote is newer")
    func remoteIsNewer() {
        #expect(AppInfo.isNewer(remote: "0.4.0", current: "0.3.1"))
        #expect(AppInfo.isNewer(remote: "0.3.2", current: "0.3.1"))
        #expect(AppInfo.isNewer(remote: "1.0.0", current: "0.99.99"))
    }

    @Test("Remote is older or equal")
    func remoteIsOlderOrEqual() {
        #expect(!AppInfo.isNewer(remote: "0.3.0", current: "0.3.1"))
        #expect(!AppInfo.isNewer(remote: "0.3.1", current: "0.3.1"))
        #expect(!AppInfo.isNewer(remote: "0.2.9", current: "0.3.0"))
    }

    @Test("Different lengths")
    func differentLengths() {
        #expect(!AppInfo.isNewer(remote: "0.4", current: "0.4.0"))
        #expect(!AppInfo.isNewer(remote: "0.4.0", current: "0.4"))
        #expect(AppInfo.isNewer(remote: "0.4.1", current: "0.4"))
    }

    @Test("Dev fallback")
    func devFallback() {
        #expect(AppInfo.isNewer(remote: "0.3.0", current: "dev"))
    }
}
