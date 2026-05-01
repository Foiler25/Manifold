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
// ─────────────────────────────────────────────────────────────────────
// DisplayInfo.swift
//
// Display-specific metadata. Lives inside `Device.displayInfo` for
// devices where `kind == .display`. Per SPEC.md §4.3.
//
// `CGSize` is Codable via CoreGraphics' Foundation overlay on
// macOS 10.14+, so the synthesized Codable on this struct works
// without manual encode/decode.

// CGSize is in CoreGraphics; its Hashable/Codable conformances live
// in the Foundation overlay. We need both imported, but only
// Foundation needs to be public (CGSize itself appears via the
// Foundation re-export).
public import Foundation
internal import CoreGraphics

public struct DisplayInfo: Hashable, Sendable, Codable {

    /// Pixel resolution. `CGSize` so Apple's CoreGraphics types remain
    /// the lingua franca for display measurements.
    public let resolution: CGSize

    /// Refresh rate in hertz. `Double` covers both integer rates
    /// (60, 120) and the fractional "23.976 Hz" film standard.
    public let refreshHz: Double

    /// Panel technology label as Apple publishes it: "Retina XDR LCD",
    /// "IPS", "OLED". Free-form string — we don't normalise vendor
    /// terminology because users want to see what their hardware says.
    public let panelType: String

    /// `true` when this is the user's main (active) display in the
    /// arrangement.
    public let isMain: Bool

    /// `true` for the laptop's built-in display.
    public let isBuiltIn: Bool

    /// `true` when the panel reports HDR support and the OS has it
    /// enabled. Phase 7's display resolver derives this from the EDID
    /// HDR static metadata block.
    public let supportsHDR: Bool

    public init(
        resolution: CGSize,
        refreshHz: Double,
        panelType: String,
        isMain: Bool,
        isBuiltIn: Bool,
        supportsHDR: Bool
    ) {
        self.resolution = resolution
        self.refreshHz = refreshHz
        self.panelType = panelType
        self.isMain = isMain
        self.isBuiltIn = isBuiltIn
        self.supportsHDR = supportsHDR
    }
}
