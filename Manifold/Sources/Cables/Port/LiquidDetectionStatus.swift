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
public import Foundation

public struct LiquidDetectionStatus: Codable, Sendable, Equatable {
    public let liquidDetected: Bool
    public let state: String
    public let measurementStatus: Int
    public let mitigationsEnabled: Bool

    public init(
        liquidDetected: Bool,
        state: String,
        measurementStatus: Int,
        mitigationsEnabled: Bool
    ) {
        self.liquidDetected = liquidDetected
        self.state = state
        self.measurementStatus = measurementStatus
        self.mitigationsEnabled = mitigationsEnabled
    }
}
