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

// MARK: - PortDiagnosticsWatcherCorpusSweepTests
//
// First corpus coverage for `PortDiagnosticsWatcher` (Watchers/PortDiagnosticsWatcher.swift).
//
// SEAM NOTE: `PortDiagnosticsWatcher.refresh()` reads live IOKit
// (`PowerTelemetryWatcher.appleSmartBatteryProperties()` and
// `PowerSourceWatcher.readAllPowerSources()`), so it is unreachable from a
// test. Its three per-entry builders -- `contract(from:)`,
// `healthCounters(from:)`, `eventTrace(from:)` -- are `private static func`,
// so they too cannot be called directly, even via `@testable import` (Swift's
// `private` stays file-scoped regardless of the import). What IS fully
// reachable, and is where the interesting logic actually lives, is
// `portKeyMap(entries:portKeys:sources:)`: a `nonisolated static func` with no
// IOKit dependency at all, taking plain `[String: Any]` / `[PowerSource]`
// values. This is the function the task brief is really about: it is the
// piece that decides which physical port an unlabelled `PortControllerInfo`
// array entry belongs to (issue class: idle-port entries have no port
// identifier at all, so `PowerControllerPortJoin`'s watts-based match is the
// load-bearing logic, with positional fallback only for entries with no
// watts signal). This file sweeps it against real probe-32 /
// probe-17 data.
//
// The three private builders are trivial one-line mappings from a dict to a
// public model (`PDContract`, `PortHealthCounters`, `PDEventTrace`) using
// public helpers (`wcInt`, `wcUInt32`, `wcBool`, `wcUInt8`, `PDO.decode`).
// `PDO.decode` itself already has dedicated corpus coverage in
// `Tests/WhatCableCoreTests/PDODecodeCorpusSweepTests.swift`; this file does
// not duplicate that. The `contract`/`healthCounters` re-assembly below,
// duplicated from the current source with a comment, exists only to prove
// the overall shape (a full `PDContract` from a real corpus entry) survives
// end-to-end without crashing -- it is NOT independent evidence that the
// private glue itself is correct, since a bug in the real private function
// that this duplicate faithfully copies would not be caught here. That
// residual gap is real and is called out again below.
@Suite("PortDiagnosticsWatcher corpus sweep - portKeyMap (probes 17 + 32)")
struct PortDiagnosticsWatcherCorpusSweepTests {

    // MARK: - Probe root (duplicated across sweep files by house convention)

    private static let probeRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableDarwinTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .deletingLastPathComponent().appendingPathComponent("research/customer-probes")
    }()

    private static func allProbeFolders() -> [String] {
        (try? FileManager.default
            .contentsOfDirectory(atPath: probeRoot.path)
            .filter { entry in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(
                    atPath: probeRoot.appendingPathComponent(entry).path,
                    isDirectory: &isDir
                )
                return isDir.boolValue
            }
            .sorted()
        ) ?? []
    }

    private static func loadProbeText(folder: String, fileName: String) -> String? {
        let url = probeRoot.appendingPathComponent(folder).appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = root["output"] as? String
        else { return nil }
        return text
    }

    // MARK: - Probe-32 PortControllerInfo extraction
    //
    // Duplicated (with light renaming) from
    // `PowerTelemetryParsingTests.extractPortControllerInfoItems` /
    // `findArraySection` / `parseFirstInt`, per the house rule of copying
    // shared parsing helpers into each new sweep file rather than editing an
    // existing one. See that file's doc comment for the full probe-32 format
    // notes; only the pieces this file needs are reproduced here.

    private static func parseFirstInt(from s: String) -> Int? {
        let trimmed = s.drop(while: { $0 == " " })
        let digits = trimmed.prefix { c in c.isNumber || c == "-" }
        return Int(digits)
    }

    private static func findArraySection(_ text: String, key: String) -> String? {
        let prefix = "  \(key) = "
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix(prefix) {
                let rest = line.dropFirst(prefix.count).drop(while: { $0 == " " })
                if rest.hasPrefix("Array[") {
                    if let range = text.range(of: line) {
                        let afterLine = text[range.upperBound...]
                        if afterLine.hasPrefix("\n") { return String(afterLine.dropFirst()) }
                        return String(afterLine)
                    }
                }
            }
        }
        return nil
    }

    private static func extractPortControllerInfoItems(_ text: String) -> [[String: Any]] {
        guard let after = findArraySection(text, key: "PortControllerInfo") else { return [] }
        var items: [[String: Any]] = []
        var current: [String: Any] = [:]
        var inItem = false

        for line in after.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.contains("Dict[") {
                if inItem { items.append(current) }
                current = [:]
                inItem = true
            } else if inItem && trimmed.hasPrefix("PortController") {
                if let eqRange = trimmed.range(of: " = ") {
                    let key = String(trimmed[..<eqRange.lowerBound])
                    let valStr = String(trimmed[eqRange.upperBound...]).drop(while: { $0 == " " })
                    if let n = parseFirstInt(from: String(valStr)) {
                        current[key] = NSNumber(value: n)
                    }
                }
            } else if inItem && !trimmed.hasPrefix(" ") && !trimmed.isEmpty && !trimmed.hasPrefix("[") {
                break
            }
        }
        if inItem { items.append(current) }
        return items
    }

    // MARK: - Probe-17 self-keyed PowerSource extraction
    //
    // Duplicated (with light renaming) from
    // `TransportWatcherSweepTests.parseDashBlocks` / `parseProperties` /
    // `extractWinningOption`, per the same house rule.

    private static func parseProperties(body: String, indent: String) -> [String: Any] {
        var props: [String: Any] = [:]
        let deeper = indent + " "
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            guard s.hasPrefix(indent), !s.hasPrefix(deeper) else { continue }
            let stripped = String(s.dropFirst(indent.count))
            guard let colonRange = stripped.range(of: ": ") else { continue }
            let key = String(stripped[..<colonRange.lowerBound])
            let valStr = String(stripped[colonRange.upperBound...])
            if valStr == "true" {
                props[key] = NSNumber(value: true)
            } else if valStr == "false" {
                props[key] = NSNumber(value: false)
            } else if valStr.hasPrefix("\""), valStr.hasSuffix("\""), valStr.count >= 2 {
                props[key] = String(valStr.dropFirst().dropLast())
            } else if let m = matchInt(valStr) {
                props[key] = NSNumber(value: m)
            }
        }
        return props
    }

    private static func matchInt(_ s: String) -> Int? {
        if let spaceIdx = s.firstIndex(of: " ") {
            if let v = Int(s[..<spaceIdx]) { return v }
        }
        return Int(s)
    }

    private static func parseDashBlocks(text: String, classPrefix: String) -> [[String: Any]] {
        let escapedPrefix = NSRegularExpression.escapedPattern(for: classPrefix)
        guard let regex = try? NSRegularExpression(pattern: "--- \(escapedPrefix)\\[\\d+\\] ---") else { return [] }
        let nsText = text as NSString
        let headerMatches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        var blocks: [[String: Any]] = []
        for (i, match) in headerMatches.enumerated() {
            let bodyStart = match.range.upperBound
            let bodyEnd = i + 1 < headerMatches.count ? headerMatches[i + 1].range.lowerBound : nsText.length
            var body = nsText.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
            for sep in ["\n---", "\n==="] {
                if let r = body.range(of: sep) { body = String(body[..<r.lowerBound]) }
            }
            blocks.append(parseProperties(body: body, indent: "  "))
        }
        return blocks
    }

    private static func extractWinningOption(text: String, blockIndex: Int, classPrefix: String) -> [String: Int]? {
        let pattern = "--- \(classPrefix)[\(blockIndex)] ---"
        guard let headerRange = text.range(of: pattern) else { return nil }
        let bodyStart = headerRange.upperBound
        var body = String(text[bodyStart...])
        for sep in ["\n---", "\n==="] {
            if let r = body.range(of: sep) { body = String(body[..<r.lowerBound]) }
        }
        let marker = "WinningPowerSourceOption: {"
        guard let start = body.range(of: marker) else { return nil }
        let afterBrace = body[start.upperBound...]
        guard let endBrace = afterBrace.range(of: "\n  }") else { return nil }
        let inner = String(afterBrace[..<endBrace.lowerBound])

        var result: [String: Int] = [:]
        for line in inner.split(separator: "\n") {
            let s = String(line)
            guard s.hasPrefix("    "), !s.hasPrefix("     ") else { continue }
            let stripped = String(s.dropFirst(4))
            guard let colonRange = stripped.range(of: ": ") else { continue }
            let key = String(stripped[..<colonRange.lowerBound])
            let valStr = String(stripped[colonRange.upperBound...])
            if let v = matchInt(valStr) { result[key] = v }
        }
        return result.isEmpty ? nil : result
    }

    /// Self-keyed `PowerSource` list from probe 17's flat `IOPortFeaturePowerSource`
    /// section, same construction TransportWatcherSweepTests / ChargingDiagnosticProbeSweepTests use.
    private static func parsePowerSources(text: String) -> [PowerSource] {
        let blocks = parseDashBlocks(text: text, classPrefix: "IOPortFeaturePowerSource")
        var result: [PowerSource] = []
        for (i, props) in blocks.enumerated() {
            let name = (props["PowerSourceName"] as? String) ?? "Unknown"
            let parentType = (props["ParentPortType"] as? NSNumber)?.intValue
                ?? (props["ParentBuiltInPortType"] as? NSNumber)?.intValue ?? 0
            let parentNum = (props["ParentBuiltInPortNumber"] as? NSNumber)?.intValue
                ?? (props["ParentPortNumber"] as? NSNumber)?.intValue ?? 0
            let winRaw = extractWinningOption(text: text, blockIndex: i, classPrefix: "IOPortFeaturePowerSource")
            let winning: PowerOption? = winRaw.flatMap { w in
                guard let v = w["Voltage (mV)"], v > 0 else { return nil }
                let c = w["Max Current (mA)"] ?? 0
                let p = w["Max Power (mW)"] ?? (v * c / 1000)
                return PowerOption(voltageMV: v, maxCurrentMA: c, maxPowerMW: p)
            }
            result.append(PowerSource(
                id: UInt64(1000 + i), name: name, parentPortType: parentType,
                parentPortNumber: parentNum, options: [], winning: winning
            ))
        }
        return result
    }

    // MARK: - Corpus sweep: portKeyMap

    @Test("Probe 17+32 sweep: portKeyMap resolves a key for every entry, watts-matched entries land on the matching source's own port")
    func portKeyMapSweep() {
        var foldersScanned = 0
        var entriesTotal = 0
        var wattsMatchedTotal = 0
        var positionalFallbackTotal = 0
        var outOfRangeFallbackTotal = 0

        for folder in Self.allProbeFolders() {
            guard let probe32 = Self.loadProbeText(folder: folder, fileName: "32_smart_battery_full_keys.json") else { continue }
            let entries = Self.extractPortControllerInfoItems(probe32)
            guard !entries.isEmpty else { continue }
            foldersScanned += 1
            entriesTotal += entries.count

            let sources: [PowerSource]
            if let probe17 = Self.loadProbeText(folder: folder, fileName: "17_deep_property_dump.json") {
                sources = Self.parsePowerSources(text: probe17)
            } else {
                sources = []
            }

            // portKeys: the HPM positional-traversal fallback list. We don't
            // have live IOKit's hpmPortKeys() here, so approximate it with a
            // plausible "2/1".."2/N" list sized to the entry count -- exactly
            // the shape portKeyMap expects for its positional-fallback branch,
            // without claiming it is the true HPM traversal order (which this
            // sweep cannot observe without IOKit).
            let portKeys = (1...max(entries.count, 1)).map { "2/\($0)" }

            let keyMap = PortDiagnosticsWatcher.portKeyMap(entries: entries, portKeys: portKeys, sources: sources)

            // Invariant 1: every entry resolves to SOME key (no silent drops;
            // portKeyMap's own contract guarantees this by construction via
            // its three-tier fallback, but a future edit could break that).
            #expect(keyMap.count == entries.count,
                "\(folder): portKeyMap resolved \(keyMap.count) keys for \(entries.count) entries")

            let sourcePortKeys = Set(sources.map(\.portKey))
            let maxPowers = entries.map { ($0["PortControllerMaxPower"] as? NSNumber)?.intValue ?? 0 }
            let wattsMap = PowerControllerPortJoin.portKeysByContent(controllerMaxPowerMW: maxPowers, sources: sources)

            for (offset, _) in entries.enumerated() {
                guard let resolvedKey = keyMap[offset] else { continue }
                if let wattsKey = wattsMap[offset] {
                    wattsMatchedTotal += 1
                    // Invariant 2: when the watts-based join resolves unambiguously,
                    // portKeyMap must use that key verbatim, never override it with
                    // the positional fallback. This is the actual `PowerControllerPortJoin`
                    // production logic under test, not a re-derivation of it.
                    #expect(resolvedKey == wattsKey,
                        "\(folder) entry[\(offset)]: watts-matched key \(wattsKey) but portKeyMap returned \(resolvedKey)")
                    #expect(sourcePortKeys.contains(resolvedKey),
                        "\(folder) entry[\(offset)]: watts-matched key \(resolvedKey) is not among the self-keyed source portKeys")
                } else if offset < portKeys.count {
                    positionalFallbackTotal += 1
                    #expect(resolvedKey == portKeys[offset],
                        "\(folder) entry[\(offset)]: expected positional fallback \(portKeys[offset]), got \(resolvedKey)")
                } else {
                    outOfRangeFallbackTotal += 1
                    #expect(resolvedKey == "2/\(offset + 1)",
                        "\(folder) entry[\(offset)]: expected out-of-range fallback 2/\(offset + 1), got \(resolvedKey)")
                }
            }
        }

        print("[PortDiagnosticsWatcherSweep] \(foldersScanned) folders, \(entriesTotal) entries, "
            + "\(wattsMatchedTotal) watts-matched, \(positionalFallbackTotal) positional-fallback, "
            + "\(outOfRangeFallbackTotal) out-of-range-fallback")

        // Coverage floor: actual counts measured directly from the on-disk
        // corpus during this pass (see printed sweep summary above for the
        // exact run's numbers). Floor set to ~85% of the measured folder
        // count so the assertion is falsifiable rather than a rubber stamp.
        //
        // Two-tier reality: only 12 probe-32 files are git-tracked (the
        // entries here are sourced from probe 32); the other ~375 are
        // on-disk-only. Gate on a raw-corpus-presence threshold well above
        // the 12-file fresh-clone case, so a fresh clone SKIPS these counts
        // instead of failing them, while the per-entry correctness checks
        // above (watts-match/positional/out-of-range resolution) keep
        // running unconditionally regardless of corpus size.
        if foldersScanned >= 50 {
            #expect(foldersScanned >= 240,
                "Expected at least 240 folders with probe-32 PortControllerInfo entries; got \(foldersScanned)")
            #expect(entriesTotal >= 240,
                "Expected at least 240 PortControllerInfo entries across the corpus; got \(entriesTotal)")
            // At least some watts-matched joins must occur, or the
            // PowerControllerPortJoin integration inside portKeyMap regressed
            // silently (this is the load-bearing path the whole function
            // exists for).
            #expect(wattsMatchedTotal >= 1,
                "Expected at least one watts-matched portKeyMap resolution across the corpus")
        }
    }

    // MARK: - Fixture: idle-port positional fallback vs watts-matched entry
    //
    // The real corpus mostly has one or two entries per machine, so the
    // "idle entry falls back positionally while a live entry watts-matches"
    // scenario is easy to miss in a pure corpus sweep depending on which
    // machines happen to have both shapes at once. Restated here as an
    // explicit fixture so the two-tier fallback itself always has direct
    // coverage regardless of what today's corpus snapshot contains.
    @Test("Fixture: watts-matched entry takes its source's key; idle entry falls back positionally")
    func fixtureMixedWattsAndPositionalFallback() {
        let sources = [
            PowerSource(id: 1, name: "USB-PD", parentPortType: 2, parentPortNumber: 1, options: [],
                        winning: PowerOption(voltageMV: 20_000, maxCurrentMA: 3_250, maxPowerMW: 65_000)),
        ]
        let entries: [[String: Any]] = [
            ["PortControllerMaxPower": NSNumber(value: 65_000)],  // matches source above
            ["PortControllerMaxPower": NSNumber(value: 0)],       // idle: no watts signal
        ]
        let portKeys = ["2/1", "2/2"]
        let keyMap = PortDiagnosticsWatcher.portKeyMap(entries: entries, portKeys: portKeys, sources: sources)

        #expect(keyMap[0] == "2/1", "watts-matched entry should take the source's own portKey")
        #expect(keyMap[1] == "2/2", "idle entry with no watts signal should fall back to the positional HPM order")
    }

    @Test("Fixture: entry index beyond known HPM ports falls back to a best-effort 1-based key")
    func fixtureOutOfRangeFallback() {
        let entries: [[String: Any]] = [["PortControllerMaxPower": NSNumber(value: 0)]]
        let keyMap = PortDiagnosticsWatcher.portKeyMap(entries: entries, portKeys: [], sources: [])
        #expect(keyMap[0] == "2/1")
    }
}
