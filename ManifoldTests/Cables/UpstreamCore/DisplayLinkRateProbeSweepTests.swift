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

/// Corpus-replay sweep for `DisplayDiagnostic.linkRateDescription` /
/// `linkRateShortName`, mirroring the pattern in
/// `DataLinkDiagnosticProbeSweepTests` (`WhatCableCoreTests`) and
/// `DisplayPortTransportWatcherSweepTests` (`WhatCableDarwinTests`).
///
/// Sweeps every `33_displayport_capability.json` probe under
/// `research/customer-probes/`, pulls out each block's `LinkRate` /
/// `LinkRateDescription` pair, and checks the shared helper against real
/// hardware data rather than a hand-picked fixture:
///
/// - The helper must never fall through to the caller's "Rate N" fallback
///   for a pair the corpus actually contains.
/// - Where a description is present, the helper must return it verbatim.
/// - The confirmed numeric-only fallback (used when no description is
///   available) must agree with what the description says for the same
///   `LinkRate` code, so the two paths can never disagree in practice.
///
/// Fresh clones without the raw corpus (only `01_walk_pd_tree.json` is
/// committed; probe 33 is gitignored) trivially pass: the missing-file guard
/// returns an empty list and the guarded minimum-count assertions are
/// skipped.
@Suite("Display link-rate labelling -- customer probe sweep")
struct DisplayLinkRateProbeSweepTests {

    // MARK: - Corpus root

    private static let probeRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .deletingLastPathComponent().appendingPathComponent("research/customer-probes")
    }()

    private static func allProbeFolders() -> [String] {
        guard let entries = try? FileManager.default
            .contentsOfDirectory(atPath: probeRoot.path) else { return [] }
        return entries.filter { entry in
            var isDir: ObjCBool = false
            let path = probeRoot.appendingPathComponent(entry).path
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return isDir.boolValue
        }.sorted()
    }

    private static func hasProbe33Files() -> Bool {
        let folders = allProbeFolders()
        for folder in folders.prefix(10) {
            let url = probeRoot
                .appendingPathComponent(folder)
                .appendingPathComponent("33_displayport_capability.json")
            if FileManager.default.fileExists(atPath: url.path) { return true }
        }
        return false
    }

    private static func loadProbeText(folder: String) -> String? {
        let url = probeRoot
            .appendingPathComponent(folder)
            .appendingPathComponent("33_displayport_capability.json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = root["output"] as? String
        else { return nil }
        return text
    }

    /// One `LinkRate` / `LinkRateDescription` pair pulled from a probe-33
    /// `=== DisplayPort node [N] ===` block.
    private struct RatePair {
        let folder: String
        let blockIndex: Int
        let rate: Int
        let description: String?
    }

    /// Parse every `=== DisplayPort node [N] ===` block in the probe text and
    /// pull out its `LinkRate = N` / `LinkRateDescription = "..."` fields.
    /// Deliberately narrow (just the two fields this sweep cares about)
    /// rather than a full property parse.
    private static func parseRatePairs(folder: String, text: String) -> [RatePair] {
        guard let regex = try? NSRegularExpression(
            pattern: "=== DisplayPort node \\[\\d+\\] ===")
        else { return [] }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        var pairs: [RatePair] = []
        for (i, match) in matches.enumerated() {
            let bodyStart = match.range.upperBound
            let bodyEnd = i + 1 < matches.count
                ? matches[i + 1].range.lowerBound
                : nsText.length
            let body = nsText.substring(with: NSRange(location: bodyStart,
                                                       length: bodyEnd - bodyStart))

            guard let rateMatch = body.range(of: #"(?m)^  LinkRate = (\d+)"#, options: .regularExpression)
            else { continue }
            let rateLine = body[rateMatch]
            guard let rate = Int(rateLine.split(separator: " ").last ?? "") else { continue }

            var description: String?
            if let descRange = body.range(of: #"(?m)^  LinkRateDescription = "([^"]*)""#, options: .regularExpression) {
                let descLine = body[descRange]
                if let firstQuote = descLine.firstIndex(of: "\""),
                   let lastQuote = descLine.lastIndex(of: "\""),
                   firstQuote != lastQuote {
                    description = String(descLine[descLine.index(after: firstQuote)..<lastQuote])
                }
            }

            pairs.append(RatePair(folder: folder, blockIndex: i, rate: rate, description: description))
        }
        return pairs
    }

    private static func allRatePairs() -> [RatePair] {
        var pairs: [RatePair] = []
        for folder in allProbeFolders() {
            guard let text = loadProbeText(folder: folder) else { continue }
            pairs.append(contentsOf: parseRatePairs(folder: folder, text: text))
        }
        return pairs
    }

    // MARK: - Tests

    @Test("Every observed LinkRate/LinkRateDescription pair resolves without hitting the Rate N fallback")
    func everyObservedPairResolves() {
        let pairs = Self.allRatePairs()

        var examined = 0
        for pair in pairs {
            examined += 1
            let resolved = DisplayDiagnostic.linkRateDescription(rate: pair.rate, description: pair.description)
            #expect(resolved != nil,
                "Probe \(pair.folder)/33 block \(pair.blockIndex): LinkRate \(pair.rate) (description: \(pair.description ?? "nil")) did not resolve; the caller would fall back to \"Rate N\"")

            // When macOS supplied its own description, the helper must
            // return it verbatim: description always wins over the numeric
            // fallback.
            if let description = pair.description, !description.isEmpty {
                #expect(resolved == description,
                    "Probe \(pair.folder)/33 block \(pair.blockIndex): expected the helper to return the description verbatim (\(description)), got \(resolved ?? "nil")")
            }
        }

        if Self.hasProbe33Files() {
            #expect(examined >= 60,
                "Expected at least 60 LinkRate/LinkRateDescription pairs across the probe-33 corpus; got \(examined)")
        }
    }

    @Test("The confirmed numeric-only fallback agrees with the real description for the same code")
    func numericFallbackAgreesWithDescription() {
        let pairs = Self.allRatePairs()

        var checked = 0
        for pair in pairs {
            guard let description = pair.description, !description.isEmpty else { continue }
            // Simulate the no-description path for this same rate code and
            // confirm it lands on the same description the real probe
            // reported. This is the guarantee that the two fallback tiers
            // (description-first, confirmed-numeric) can never disagree.
            let numericOnly = DisplayDiagnostic.linkRateDescription(rate: pair.rate, description: nil)
            #expect(numericOnly == description,
                "Probe \(pair.folder)/33 block \(pair.blockIndex): LinkRate \(pair.rate)'s confirmed numeric fallback (\(numericOnly ?? "nil")) disagrees with the real macOS description (\(description))")
            checked += 1
        }

        if Self.hasProbe33Files() {
            #expect(checked >= 60,
                "Expected at least 60 description-bearing pairs to check the numeric fallback against; got \(checked)")
        }
    }

    @Test("Only the corpus-confirmed codes (0, 2, 3, 4) appear across the whole probe-33 corpus")
    func onlyConfirmedCodesAppear() {
        let pairs = Self.allRatePairs()
        let observedCodes = Set(pairs.map(\.rate))

        // The invented codes (1, 6, 10, 20, 30, 40) from the old table must
        // never appear in real data; if one ever does, the confirmed map
        // needs a fresh corpus review, not a silent re-guess.
        let neverConfirmed: Set<Int> = [1, 6, 10, 20, 30, 40]
        #expect(observedCodes.isDisjoint(with: neverConfirmed),
            "Found a LinkRate code (\(observedCodes.intersection(neverConfirmed))) that was never in the corpus before; review whether it should be added to the confirmed map")

        if Self.hasProbe33Files() && !pairs.isEmpty {
            #expect(observedCodes.isSubset(of: [0, 2, 3, 4]),
                "Expected only codes {0,2,3,4} across the probe-33 corpus; found \(observedCodes)")
        }
    }
}
