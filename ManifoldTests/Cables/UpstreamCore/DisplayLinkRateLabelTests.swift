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

/// Pins `DisplayDiagnostic.linkRateDescription` / `linkRateShortName`, the
/// shared helper the Diagnostics screen's "Link rate" row, its "DP HBR3 x 4"
/// mode label, and the pin diagram's DP badge all delegate to. Before this
/// helper existed, two call sites in `CableDiagnosticView.swift` (plus a
/// third in `PinDiagramView.swift`) each hand-rolled their own numeric
/// `linkRate` -> label table with codes (6/10/20/30/40) that never once
/// appeared in a corpus sweep of 219 real customer probe-33 submissions. The
/// helper is description-first (macOS's own `linkRateDescription` string is
/// always preferred) with a fallback map restricted to the four codes the
/// corpus actually confirms: 0, 2, 3, 4.
@Suite("Display link-rate labelling")
struct DisplayLinkRateLabelTests {

    // MARK: - Description-first

    @Test("macOS's own description renders verbatim")
    func descriptionRendersVerbatim() {
        #expect(DisplayDiagnostic.linkRateDescription(rate: 3, description: "5.4 Gbps (HBR2)") == "5.4 Gbps (HBR2)")
    }

    @Test("Short name extracts the parenthesised token from the description")
    func shortNameFromDescription() {
        #expect(DisplayDiagnostic.linkRateShortName(rate: 3, description: "5.4 Gbps (HBR2)") == "HBR2")
    }

    @Test("An unexpected description string still wins over the numeric code")
    func unexpectedDescriptionStillWins() {
        // Description is always preferred: even a rate code the confirmed
        // map doesn't recognise renders macOS's own words rather than
        // falling through to "Rate N".
        #expect(DisplayDiagnostic.linkRateDescription(rate: 99, description: "20 Gbps (UHBR20)") == "20 Gbps (UHBR20)")
        #expect(DisplayDiagnostic.linkRateShortName(rate: 99, description: "20 Gbps (UHBR20)") == "UHBR20")
    }

    // MARK: - Confirmed numeric fallback (no description)

    @Test("Code 2 with no description falls back to the confirmed HBR label")
    func code2NoDescription() {
        #expect(DisplayDiagnostic.linkRateDescription(rate: 2, description: nil) == "2.7 Gbps (HBR)")
        #expect(DisplayDiagnostic.linkRateShortName(rate: 2, description: nil) == "HBR")
    }

    @Test("Code 3 with no description falls back to the confirmed HBR2 label")
    func code3NoDescription() {
        #expect(DisplayDiagnostic.linkRateDescription(rate: 3, description: nil) == "5.4 Gbps (HBR2)")
        #expect(DisplayDiagnostic.linkRateShortName(rate: 3, description: nil) == "HBR2")
    }

    @Test("Code 4 with no description falls back to the confirmed HBR3 label")
    func code4NoDescription() {
        #expect(DisplayDiagnostic.linkRateDescription(rate: 4, description: nil) == "8.1 Gbps (HBR3)")
        #expect(DisplayDiagnostic.linkRateShortName(rate: 4, description: nil) == "HBR3")
    }

    @Test("Empty-string description is treated the same as nil")
    func emptyDescriptionFallsBackToNumeric() {
        #expect(DisplayDiagnostic.linkRateDescription(rate: 3, description: "") == "5.4 Gbps (HBR2)")
    }

    // MARK: - No-link case

    @Test("Code 0 with no description resolves to \"No Link\"")
    func code0NoDescription() {
        #expect(DisplayDiagnostic.linkRateDescription(rate: 0, description: nil) == "No Link")
        // "No Link" has no parenthesised token, so there's no short mode
        // name to extract; the caller falls back to its own "Rate N" wording.
        #expect(DisplayDiagnostic.linkRateShortName(rate: 0, description: nil) == nil)
    }

    // MARK: - Unknown / unconfirmed code, no description

    @Test("An unconfirmed code with no description falls through to nil (caller renders \"Rate N\")")
    func unconfirmedCodeNoDescriptionFallsThrough() {
        // The old code invented labels for 6/10/20/30/40. None of those are
        // corpus-confirmed, so the shared helper must NOT recognise them:
        // it should return nil and let the caller use its own "Rate N".
        for invented in [1, 6, 10, 20, 30, 40, 7] {
            #expect(DisplayDiagnostic.linkRateDescription(rate: invented, description: nil) == nil,
                "Code \(invented) is not corpus-confirmed and should not resolve to an invented label")
            #expect(DisplayDiagnostic.linkRateShortName(rate: invented, description: nil) == nil)
        }
    }

    // MARK: - Defensive string-shape cases (PR #387 review findings)

    @Test("Whitespace-only description is treated as absent")
    func whitespaceDescriptionFallsBackToNumeric() {
        // A blank IOKit string must not render as an empty-looking row, and
        // the row and the short-name badge must agree on the same input.
        #expect(DisplayDiagnostic.linkRateDescription(rate: 3, description: "   ") == "5.4 Gbps (HBR2)")
        #expect(DisplayDiagnostic.linkRateShortName(rate: 3, description: "   ") == "HBR2")
    }

    @Test("Description with stray whitespace renders trimmed")
    func descriptionIsTrimmed() {
        #expect(DisplayDiagnostic.linkRateDescription(rate: 3, description: " 5.4 Gbps (HBR2) ") == "5.4 Gbps (HBR2)")
    }

    @Test("A description without parens is used whole as the short name")
    func noParensDescriptionUsedWhole() {
        // A real OS string beats the caller's "Rate N" fallback even when
        // there's no parenthesised token to extract.
        #expect(DisplayDiagnostic.linkRateShortName(rate: 99, description: "UHBR20") == "UHBR20")
    }

    @Test("Nested or malformed parens fall back to the full description, never a fragment")
    func malformedParensFallBackToFullDescription() {
        #expect(DisplayDiagnostic.linkRateShortName(rate: 99, description: "20 Gbps (UHBR20 (Alt))") == "20 Gbps (UHBR20 (Alt))")
        #expect(DisplayDiagnostic.linkRateShortName(rate: 99, description: "5.4 Gbps ()") == "5.4 Gbps ()")
    }

    @Test("An explicit \"No Link\" description yields no short name")
    func noLinkDescriptionYieldsNoShortName() {
        #expect(DisplayDiagnostic.linkRateShortName(rate: 0, description: "No Link") == nil)
    }

    // MARK: - Confirmed map exactly matches the corpus sweep

    @Test("The confirmed map contains exactly the four corpus-observed codes")
    func confirmedMapMatchesCorpusSweep() {
        // 219 probe-33 files swept 2026-07-03: only 0/2/3/4 ever appear.
        #expect(Set(DisplayDiagnostic.confirmedLinkRateDescriptions.keys) == Set([0, 2, 3, 4]))
        #expect(DisplayDiagnostic.confirmedLinkRateDescriptions[0] == "No Link")
        #expect(DisplayDiagnostic.confirmedLinkRateDescriptions[2] == "2.7 Gbps (HBR)")
        #expect(DisplayDiagnostic.confirmedLinkRateDescriptions[3] == "5.4 Gbps (HBR2)")
        #expect(DisplayDiagnostic.confirmedLinkRateDescriptions[4] == "8.1 Gbps (HBR3)")
    }
}
