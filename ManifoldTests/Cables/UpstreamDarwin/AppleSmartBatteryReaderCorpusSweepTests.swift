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

// MARK: - AppleSmartBatteryReaderCorpusSweepTests
//
// SEAM NOTE -- READ THIS FIRST: unlike every other file in this pass,
// `AppleSmartBatteryReader`'s parse family (`parseBattery`, `parseChargerData`,
// `parseCarrierMode`, `parseShutdownReason`, `parseAdapterDetails`,
// `parseHVCMenu`, `parsePowerTelemetry`, `parsePortControllerInfo`,
// `parseFedDetails`) are ALL declared `private static func` on the
// `AppleSmartBatteryReader` enum. Swift's `private` is scoped to the
// enclosing declaration (here, the whole file), and `@testable import` only
// elevates `internal` access to look public from outside the module -- it
// does NOT reach `private` or `fileprivate` symbols. There is no
// `nonisolated static` seam here the way there is for
// `PowerTelemetryWatcher` (see `PowerTelemetryParsingTests.swift`) or
// `PortDiagnosticsWatcher.portKeyMap` (see
// `PortDiagnosticsWatcherCorpusSweepTests.swift`): the only public entry
// point on this type is `AppleSmartBatteryReader.read()`, which talks to a
// live `AppleSmartBattery` IOKit service directly and has no `read:` closure
// argument to substitute corpus data into.
//
// This means: **this file does not call, and cannot call, a single line of
// `AppleSmartBatteryReader`'s own parsing code.** Under this task's
// instruction to "test the extracted PARSING/CLASSIFICATION logic they
// delegate to" when the factory itself is IOKit-bound, the honest finding is
// that no such extracted seam exists for this file. Changing that (making the
// parse family `internal`, or splitting a pure `[String: Any] -> AppleSmartBattery`
// function out the way `AppleHPMInterface.from` and `IOThunderboltSwitch.from`
// already do) would close this gap properly, but that is a source-code change
// out of scope for a test-only pass that may only create new test files.
//
// What this file does instead, to still deliver real value from probe 32
// (`32_smart_battery_full_keys.json`, ~410 folders) without touching
// `AppleSmartBatteryReader`:
//
// 1. Parses the same top-level IOKit keys `parseBattery` /
//    `parseAdapterDetails` read (`BatteryInstalled`, `CurrentCapacity`,
//    `MaxCapacity`, and the `AdapterDetails` dict's `Watts`) directly out of
//    the raw probe text, with its own independent extraction logic (NOT
//    copied from the private functions -- there is nothing to copy from, since
//    they are inaccessible; this is a fresh implementation against the raw
//    format).
// 2. Cross-checks those extracted values against `corpus.jsonl`'s
//    `signals.battery_pct` / `signals.adapter_w` fields, which were computed
//    by an entirely separate tool (`scripts/inspect-probe.py`, run by the
//    `/whatcable-process-probe` skill). Agreement between two independently
//    written extractions is real evidence the raw values themselves, and the
//    format assumptions both extractions share, are sound -- even though
//    neither path is `AppleSmartBatteryReader`.
// 3. Confirms the desktop/laptop gate: `BatteryInstalled` (and, downstream,
//    `AppleSmartBatteryReader.read()`'s `isDesktopMac`) is consistent with
//    `corpus.jsonl`'s independently-derived `form_factor` on every folder.
// 4. Checks physical bounds -- and this is where the task brief's warning
//    about unit traps proved concretely true, twice over, while building
//    this file:
//      a. `CurrentCapacity`/`MaxCapacity` are NOT a 0-100 percent pair on
//         every Mac. On this corpus's Intel machines they are real mAh
//         fuel-gauge readings (e.g. 4006/4195); only on Apple Silicon do both
//         happen to already be percent-scaled. The invariant that holds on
//         BOTH platforms -- and the one production itself relies on, see
//         `Sources/WhatCable/Services/WidgetDataWriter.swift`'s
//         `currentCapacity / maxCapacity * 100` -- is the RATIO, not either
//         raw field, so that is what is bounded to 0-100 below.
//      b. There are TWO structurally similar but semantically different
//         "Watts" fields: the top-level `AdapterDetails` dict (what
//         `parseAdapterDetails` reads; the charger's rated/selected-HVC-step
//         capability) versus `AppleRawAdapterDetails[0]` (the ACTIVELY
//         NEGOTIATED wattage, which can be lower once the battery is nearly
//         full -- confirmed 140 W rated vs 65 W negotiated on the same
//         machine). Each is bounds-checked and cross-checked against its own
//         semantically-matching source; they are never treated as
//         interchangeable. See `BatterySnapshot`'s doc comment for the full
//         detail.
// 5. Builds the real public `AppleSmartBattery` / `CableAdapterInfo` model types
//    (WhatCableCore) from the extracted values via their public
//    initialisers, and asserts the values round-trip. This exercises real
//    production TYPES, though not the reader's parsing itself.
@Suite("AppleSmartBatteryReader corpus sweep - probe 32 (seam-limited, see file doc comment)")
struct AppleSmartBatteryReaderCorpusSweepTests {

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

    private static func loadProbe32(folder: String) -> String? {
        let url = probeRoot.appendingPathComponent(folder).appendingPathComponent("32_smart_battery_full_keys.json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = root["output"] as? String
        else { return nil }
        return text
    }

    // MARK: - Independent probe-32 extraction (fresh, not copied from AppleSmartBatteryReader)
    //
    // FINDING while building this file: probe 32 carries TWO structurally
    // similar but semantically different pairs of fields, and naively
    // grabbing "the obvious one" produces numbers that look plausible but
    // measure the wrong thing:
    //
    //  - Battery percent: `CurrentCapacity`/`MaxCapacity` (what
    //    `AppleSmartBatteryReader.parseBattery` actually reads) are already
    //    a coarse, sometimes-clamped percent (observed stuck at 100 while
    //    the real charge was 97-99%). `StateOfCharge` is a separate IOKit
    //    key -- NOT read by `AppleSmartBatteryReader` at all -- that carries
    //    the finer-grained percent `corpus.jsonl`'s `battery_pct` uses. The
    //    two are not the same signal and should not be asserted equal.
    //  - Adapter watts: the top-level `AdapterDetails` dict's `Watts` (what
    //    `AppleSmartBatteryReader.parseAdapterDetails` actually reads) is the
    //    charger's rated/selected-HVC-step capability. `AppleRawAdapterDetails`
    //    is a SEPARATE array whose `[0].Watts` reflects the ACTUAL currently
    //    negotiated wattage, which can be lower once the battery is nearly
    //    full and charging has throttled back (confirmed: 140 W rated vs
    //    65 W actually negotiated on the same machine, m5pro_macos26.5_g).
    //    `corpus.jsonl`'s `adapter_w` extraction happens to land on the raw
    //    array's entry (its regex's first "AdapterDetails" substring match is
    //    inside "AppleRawAdapterDetails", which contains "AdapterDetails" as
    //    a substring) even though it does not intend to distinguish the two.
    //
    // Both pairs are extracted below, clearly labelled, so the production-
    // faithful fields (what `AppleSmartBatteryReader` really reads) get their
    // own bounds checks, and the `corpus.jsonl`-comparable fields get their
    // own honest cross-check against a genuinely equivalent signal.

    private struct BatterySnapshot {
        let batteryInstalled: Bool
        /// Production-faithful: `CurrentCapacity`/`MaxCapacity`, exactly what
        /// `AppleSmartBatteryReader.parseBattery` reads via `read("CurrentCapacity")`.
        let currentCapacity: Int?
        let maxCapacity: Int?
        /// NOT read by AppleSmartBatteryReader; a finer-grained percent used
        /// here only to cross-check against corpus.jsonl's identical signal.
        let stateOfCharge: Int?
        /// Production-faithful: top-level `AdapterDetails` dict's `Watts`,
        /// exactly what `AppleSmartBatteryReader.parseAdapterDetails` reads.
        let adapterDetailsWatts: Int?
        /// `AppleRawAdapterDetails[0].Watts` -- the actively negotiated
        /// wattage, comparable to corpus.jsonl's `adapter_w`. Not read by
        /// `AppleSmartBatteryReader` (which only reads `AdapterDetails`).
        let rawAdapterDetailsWatts: Int?
    }

    private static func matchInt(_ s: String) -> Int? {
        let trimmed = s.drop(while: { $0 == " " })
        let digits = trimmed.prefix { $0.isNumber || $0 == "-" }
        return Int(digits)
    }

    private static func parseTopLevelInt(_ text: String, key: String) -> Int? {
        let prefix = "  \(key) = "
        for line in text.components(separatedBy: "\n") where line.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count).drop(while: { $0 == " " })
            return matchInt(String(rest))
        }
        return nil
    }

    private static func parseTopLevelBool(_ text: String, key: String) -> Bool? {
        let prefix = "  \(key) = "
        for line in text.components(separatedBy: "\n") where line.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("true") { return true }
            if rest.hasPrefix("false") { return false }
        }
        return nil
    }

    /// `StateOfCharge = N`, matching `scripts/inspect-probe.py`'s
    /// `battery_pct()` regex `(?<![A-Za-z])StateOfCharge\s*=\s*(\d+)` exactly
    /// (a negative lookbehind so it never matches inside a longer key name),
    /// so this is a true apples-to-apples cross-check against corpus.jsonl.
    private static func parseStateOfCharge(_ text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z])StateOfCharge\s*=\s*(\d+)"#) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return Int(ns.substring(with: m.range(at: 1)))
    }

    /// Extract `Watts` from EXACTLY the top-level `  AdapterDetails =     Dict[`
    /// key (2-space indent), matching `AppleSmartBatteryReader.parseAdapterDetails`'s
    /// `read("AdapterDetails")` contract. Deliberately does NOT match
    /// `AppleRawAdapterDetails` (a differently-shaped array key with a
    /// different meaning, see the doc comment above).
    private static func parseAdapterDetailsWatts(_ text: String) -> Int? {
        let lines = text.components(separatedBy: "\n")
        guard let headerIdx = lines.firstIndex(where: { $0.hasPrefix("  AdapterDetails =") }) else { return nil }
        // The dict's own properties are indented exactly 6 spaces (one level
        // deeper than the 2-space "  AdapterDetails =" key, then 4 more for
        // the printer's per-level indent step observed in this probe).
        var idx = headerIdx + 1
        while idx < lines.count {
            let line = lines[idx]
            guard line.hasPrefix("      ") else { break }   // dict ended (indent dropped)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Watts =") {
                let rest = trimmed.dropFirst("Watts =".count).drop(while: { $0 == " " })
                return matchInt(String(rest))
            }
            idx += 1
        }
        return nil
    }

    /// Replicates `scripts/inspect-probe.py`'s `charging()` regex
    /// `AdapterDetails[\s\S]{0,400}?Watts\s*=\s*(\d+)` exactly, including its
    /// quirk of matching the FIRST "AdapterDetails" substring in the text --
    /// which is inside "AppleRawAdapterDetails" (itself contains
    /// "AdapterDetails" as a substring) since that key appears earlier in
    /// the dump. This is deliberately NOT the same extraction as
    /// `parseAdapterDetailsWatts` above; it exists only to cross-check
    /// against corpus.jsonl's `adapter_w` on the same terms it was computed.
    private static func parseCorpusStyleAdapterWatts(_ text: String) -> Int? {
        guard let anchor = text.range(of: "AdapterDetails") else { return nil }
        let windowEnd = text.index(anchor.upperBound, offsetBy: 400, limitedBy: text.endIndex) ?? text.endIndex
        let window = text[anchor.upperBound..<windowEnd]
        guard let regex = try? NSRegularExpression(pattern: #"Watts\s*=\s*(\d+)"#) else { return nil }
        let ns = window as NSString
        guard let m = regex.firstMatch(in: String(window), range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return Int(ns.substring(with: m.range(at: 1)))
    }

    private static func parseSnapshot(_ text: String) -> BatterySnapshot {
        let installed = parseTopLevelBool(text, key: "BatteryInstalled") ?? false
        return BatterySnapshot(
            batteryInstalled: installed,
            currentCapacity: parseTopLevelInt(text, key: "CurrentCapacity"),
            maxCapacity: parseTopLevelInt(text, key: "MaxCapacity"),
            stateOfCharge: parseStateOfCharge(text),
            adapterDetailsWatts: parseAdapterDetailsWatts(text),
            rawAdapterDetailsWatts: parseCorpusStyleAdapterWatts(text)
        )
    }

    // MARK: - corpus.jsonl ground truth

    private struct CorpusRow {
        let formFactor: String
        let batteryPct: Int?
        let adapterW: Int?
    }

    private static func loadCorpusJSONL() -> [String: CorpusRow] {
        let url = probeRoot.appendingPathComponent("corpus.jsonl")
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [:] }

        var rows: [String: CorpusRow] = [:]
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let folder = obj["folder"] as? String,
                  let formFactor = obj["form_factor"] as? String
            else { continue }
            let signals = obj["signals"] as? [String: Any] ?? [:]
            rows[folder] = CorpusRow(
                formFactor: formFactor,
                batteryPct: signals["battery_pct"] as? Int,
                adapterW: signals["adapter_w"] as? Int
            )
        }
        return rows
    }

    // MARK: - Corpus sweep

    /// Folders where corpus.jsonl's own `form_factor()` documents a KNOWN
    /// exception: a real laptop whose battery is absent/faulted reports
    /// `BatteryInstalled=false` like a desktop, so `form_factor` falls back
    /// to port-layout (MagSafe presence) to still call it a laptop. This is
    /// not a parsing bug in either tool; it is called out explicitly in
    /// `scripts/inspect-probe.py`'s `form_factor()` comment. Excluded from
    /// the strict gate below so a real mismatch elsewhere isn't masked by
    /// this documented one.
    private static let knownFaultedBatteryLaptops: Set<String> = ["m4pro_macos26.5_f"]

    @Test("Probe-32 sweep: BatteryInstalled matches corpus.jsonl form_factor (documented exceptions aside); StateOfCharge and the actively-negotiated adapter watts agree with corpus.jsonl's independent extraction")
    func probe32SweepCrossCheckedAgainstCorpusJSONL() {
        let corpusRows = Self.loadCorpusJSONL()
        var foldersScanned = 0
        var desktopMismatches = 0
        var laptopMismatches = 0
        var stateOfChargeCrossChecked = 0
        var stateOfChargeMismatches = 0
        var adapterWCrossChecked = 0
        var adapterWMismatches = 0

        for folder in Self.allProbeFolders() {
            guard let text = Self.loadProbe32(folder: folder) else { continue }
            foldersScanned += 1
            let snapshot = Self.parseSnapshot(text)

            // Physical bounds, checked unconditionally on the PRODUCTION-
            // FAITHFUL fields (what AppleSmartBatteryReader itself reads),
            // regardless of whether corpus.jsonl has a row for this folder.
            //
            // FINDING: CurrentCapacity/MaxCapacity are NOT a 0-100 percent
            // pair on every Mac -- confirmed on this corpus's Intel machines,
            // e.g. intel_corei5_1038ng7_macos26.5 reports CurrentCapacity =
            // 4006, MaxCapacity = 4195 (real mAh fuel-gauge units). Apple
            // Silicon machines happen to report both fields already
            // percent-scaled (observed stuck at 100/100), which is what
            // misled an earlier version of this test into bounding
            // CurrentCapacity itself to 0-100. The one invariant that holds
            // on BOTH platforms is the RATIO, which is exactly the formula
            // production already uses (`WidgetDataWriter.swift`:
            // `currentCapacity / maxCapacity * 100`) -- asserted here
            // instead of the raw field, which is also a stronger check since
            // it is the real production formula, not a guess at one.
            if let cur = snapshot.currentCapacity, let max = snapshot.maxCapacity, max > 0 {
                let ratio = Double(cur) / Double(max) * 100
                #expect((0...100.5).contains(ratio),
                    "\(folder): CurrentCapacity/MaxCapacity ratio \(ratio)% outside 0-100 (cur=\(cur), max=\(max))")
            }
            if let watts = snapshot.adapterDetailsWatts {
                #expect((0...300).contains(watts), "\(folder): AdapterDetails.Watts \(watts) outside 0-300 W")
            }
            if let pct = snapshot.stateOfCharge {
                #expect((0...100).contains(pct), "\(folder): StateOfCharge \(pct) outside 0-100")
            }

            guard let corpusRow = corpusRows[folder] else { continue }

            // Desktop/laptop gate: corpus.jsonl's form_factor is derived
            // independently (by the /whatcable-process-probe skill's own
            // BatteryInstalled read), so agreement here is cross-validation,
            // not a tautology against this file's own extraction. One
            // documented exception (faulted-battery laptop) is excluded, see
            // knownFaultedBatteryLaptops above.
            if corpusRow.formFactor == "desktop" {
                if snapshot.batteryInstalled { desktopMismatches += 1 }
                #expect(!snapshot.batteryInstalled,
                    "\(folder): corpus.jsonl says desktop but BatteryInstalled=true")
            } else if !Self.knownFaultedBatteryLaptops.contains(folder)
                        && (corpusRow.formFactor == "laptop" || corpusRow.formFactor.contains("laptop")) {
                if !snapshot.batteryInstalled { laptopMismatches += 1 }
                #expect(snapshot.batteryInstalled,
                    "\(folder): corpus.jsonl says \(corpusRow.formFactor) but BatteryInstalled=false")
            }

            // StateOfCharge cross-check: same key, same regex intent as
            // corpus.jsonl's battery_pct(), so equality here is a genuine
            // apples-to-apples agreement, unlike CurrentCapacity (see file
            // doc comment for why that field is NOT compared this way).
            if let corpusPct = corpusRow.batteryPct, let ourPct = snapshot.stateOfCharge {
                stateOfChargeCrossChecked += 1
                if corpusPct != ourPct { stateOfChargeMismatches += 1 }
                #expect(corpusPct == ourPct,
                    "\(folder): battery_pct \(corpusPct) in corpus.jsonl != StateOfCharge \(ourPct) extracted here")
            }
            // Adapter watts cross-check: corpus.jsonl's regex lands on
            // AppleRawAdapterDetails[0].Watts (the actively negotiated
            // wattage), not the top-level AdapterDetails.Watts (rated
            // capability) -- see rawAdapterDetailsWatts's doc comment.
            // Comparing like-for-like here, not against adapterDetailsWatts.
            if let corpusW = corpusRow.adapterW, let ourW = snapshot.rawAdapterDetailsWatts {
                adapterWCrossChecked += 1
                if corpusW != ourW { adapterWMismatches += 1 }
                #expect(corpusW == ourW,
                    "\(folder): adapter_w \(corpusW) in corpus.jsonl != \(ourW) extracted here (actively-negotiated reading)")
            }
        }

        print("[AppleSmartBatteryReaderSweep] \(foldersScanned) folders, "
            + "\(desktopMismatches) desktop mismatches, \(laptopMismatches) laptop mismatches (excl. documented exceptions), "
            + "\(stateOfChargeCrossChecked) StateOfCharge cross-checked (\(stateOfChargeMismatches) mismatches), "
            + "\(adapterWCrossChecked) adapter-W cross-checked (\(adapterWMismatches) mismatches)")

        // Correctness invariants: run whenever there is ANY probe-32 data at
        // all, including a fresh clone where only the 12 git-tracked probe-32
        // fixtures exist. A mismatch is a real bug regardless of corpus size,
        // so these must never be skipped just because the full corpus isn't
        // on disk (unlike the raw-count floor below).
        if foldersScanned > 0 {
            #expect(desktopMismatches == 0, "form_factor==desktop must always mean BatteryInstalled==false")
            #expect(laptopMismatches == 0, "form_factor containing laptop must always mean BatteryInstalled==true (documented exceptions aside)")
            #expect(stateOfChargeMismatches == 0, "this file's StateOfCharge extraction must agree with corpus.jsonl's independent extraction")
            #expect(adapterWMismatches == 0, "this file's AppleRawAdapterDetails[0].Watts extraction must agree with corpus.jsonl's independent extraction")
        }

        // Coverage floor: actual counts measured directly from the on-disk
        // corpus during this pass (see printed sweep summary). Floor set to
        // ~85% of the measured folder count.
        //
        // Two-tier reality: only 12 probe-32 files are git-tracked; the
        // other ~375 are on-disk-only. Gate the raw-count floors (and the
        // "at least one real cross-check happened" minimums, which are not
        // guaranteed to hold on an arbitrary small fixture set) on a
        // raw-corpus-presence threshold well above the 12-file fresh-clone
        // case, so a fresh clone SKIPS these instead of failing them.
        if foldersScanned >= 50 {
            #expect(foldersScanned >= 340,
                "Expected at least 340 folders with a probe-32 file; got \(foldersScanned)")
            // At least some real cross-checks must have happened, or the
            // mismatch checks above would be vacuously true.
            #expect(stateOfChargeCrossChecked >= 1)
            #expect(adapterWCrossChecked >= 1)
        }
    }

    // MARK: - Model round-trip (touches real production TYPES, not the reader)
    //
    // `AppleSmartBattery` and `CableAdapterInfo` (WhatCableCore) are the types
    // `AppleSmartBatteryReader.read()` would build from these same values.
    // This proves the shape is still compatible and exercises the public
    // initialisers with real corpus-derived numbers, but -- restating the
    // file doc comment -- it does NOT invoke a single line of
    // `AppleSmartBatteryReader`'s own code.
    @Test("Model round-trip: AppleSmartBattery/CableAdapterInfo built from corpus values store what was passed")
    func modelRoundTripFromCorpusValues() {
        var checked = 0
        for folder in Self.allProbeFolders() {
            guard let text = Self.loadProbe32(folder: folder) else { continue }
            let snapshot = Self.parseSnapshot(text)
            guard snapshot.batteryInstalled, let pct = snapshot.currentCapacity else { continue }
            checked += 1

            let adapter = snapshot.adapterDetailsWatts.map { CableAdapterInfo(watts: $0, isCharging: nil, source: nil) }
            let battery = AppleSmartBattery(
                batteryInstalled: true,
                currentCapacity: pct,
                maxCapacity: snapshot.maxCapacity ?? 0,
                adapterDetails: adapter
            )

            #expect(battery.batteryInstalled)
            #expect(battery.currentCapacity == pct, "\(folder): currentCapacity did not round-trip")
            if let watts = snapshot.adapterDetailsWatts {
                #expect(battery.adapterDetails?.watts == watts, "\(folder): adapterDetails.watts did not round-trip")
            }
        }
        print("[AppleSmartBatteryReaderSweep] model round-trip checked on \(checked) folders")
        if checked > 0 {
            #expect(checked >= 1)
        }
    }
}
