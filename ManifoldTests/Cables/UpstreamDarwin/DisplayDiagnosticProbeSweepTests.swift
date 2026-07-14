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

// MARK: - DisplayDiagnosticProbeSweepTests (DAR-138)
//
// Corpus-backed tests for DisplayDiagnostic. Each test loads a real probe-33
// file from `research/customer-probes/`, parses it into a
// `IOPortTransportStateDisplayPort` using the same `makeUpdate` path the live
// app uses, then runs `DisplayDiagnostic` and asserts verdict-level
// expectations grounded in the machine's `inspection.md`.
//
// Why WhatCableDarwinTests (not WhatCableCoreTests): the parse step needs
// `DisplayPortTransportWatcher.makeUpdate`, which lives in
// `WhatCableDarwinBackend`. `DisplayDiagnostic` itself is in
// `WhatCableCore` and is accessible from here via the dependency chain.
//
// DSC coverage limit: monitor DSC capability is not in these probes (issue
// #246). Where the verdict is `.compressionPlausible`, the test confirms that
// verdict; it cannot confirm the display is actually compressing. The
// `.fine`-via-DSC upgrade path (CoreGraphics live-mode confirmation) is not
// exercised here because probe 33 carries no CoreGraphics data.
//
// All helpers in this file are file-private; there is no shared
// Support/ProbeCorpus.swift dependency.

@Suite("DisplayDiagnostic -- customer probe sweep (DAR-138)")
struct DisplayDiagnosticProbeSweepTests {

    // MARK: - Corpus root

    private static let probeRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableDarwinTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .deletingLastPathComponent().appendingPathComponent("research/customer-probes")
    }()

    // MARK: - Probe 33 loader

    private static func loadProbe33(folder: String) -> String? {
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

    // MARK: - Probe 33 block parser
    //
    // Parses `=== DisplayPort node [N] ===` blocks from probe 33.
    // Properties use `KEY = VALUE` equals format at 2-space indent.
    // Metadata sub-fields appear as flat `Metadata.KEY = VALUE` lines;
    // they are folded into a nested dict under "Metadata" so the watcher's
    // `read("Metadata") as? [String: Any]` lookup works normally.
    // (File-private copy of the parser from DisplayPortTransportWatcherSweepTests.)

    private static func parseDPNode33Blocks(text: String) -> [[String: Any]] {
        guard let regex = try? NSRegularExpression(
            pattern: "=== DisplayPort node \\[\\d+\\] ===")
        else { return [] }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        var blocks: [[String: Any]] = []
        for (i, match) in matches.enumerated() {
            let bodyStart = match.range.upperBound
            let bodyEnd = i + 1 < matches.count
                ? matches[i + 1].range.lowerBound
                : nsText.length
            let body = nsText.substring(with: NSRange(location: bodyStart,
                                                      length: bodyEnd - bodyStart))
            blocks.append(parseEqualsProps(body: body))
        }
        return blocks
    }

    private static func parseEqualsProps(body: String) -> [String: Any] {
        var props: [String: Any] = [:]
        var metadata: [String: Any] = [:]

        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            guard s.hasPrefix("  "), !s.hasPrefix("   ") else { continue }
            let stripped = String(s.dropFirst(2))

            if stripped.hasPrefix("Metadata.") {
                let rest = String(stripped.dropFirst("Metadata.".count))
                if let (key, val) = parseEqualsLine(rest) {
                    metadata[key] = val
                }
                continue
            }
            if stripped.hasPrefix("---") { continue }
            if let (key, val) = parseEqualsLine(stripped) {
                props[key] = val
            }
        }
        if !metadata.isEmpty { props["Metadata"] = metadata }
        return props
    }

    private static func parseEqualsLine(_ stripped: String) -> (String, Any)? {
        guard let eqRange = stripped.range(of: " = ") else { return nil }
        let key = String(stripped[..<eqRange.lowerBound])
        let valStr = String(stripped[eqRange.upperBound...])
        if valStr == "(absent)" || valStr == "(redacted)" { return nil }
        if valStr.hasPrefix("<") { return nil }
        if valStr.hasPrefix("{") { return nil }
        if valStr == "true" { return (key, NSNumber(value: true)) }
        if valStr == "false" { return (key, NSNumber(value: false)) }
        if valStr.hasPrefix("\""), valStr.hasSuffix("\""), valStr.count >= 2 {
            return (key, String(valStr.dropFirst().dropLast()))
        }
        if let n = matchInt(valStr) { return (key, NSNumber(value: n)) }
        return nil
    }

    private static func matchInt(_ s: String) -> Int? {
        if let spaceIdx = s.firstIndex(of: " ") {
            if let v = Int(s[..<spaceIdx]) { return v }
        }
        return Int(s)
    }

    // MARK: - Model builder

    /// Parse a single props dict (one probe-33 block) into a
    /// `DisplayPortTransportWatcher.DisplayPortUpdate` using the same static
    /// parse function the live watcher uses.
    private static func makeUpdate(props: [String: Any],
                                   id: UInt64) -> DisplayPortTransportWatcher.DisplayPortUpdate? {
        let read: (String) -> Any? = { props[$0] }
        return DisplayPortTransportWatcher.makeUpdate(
            entryID: id,
            read: read,
            portIndex: 0,
            portType: "USB-C",
            hpmControllerUUID: nil
        )
    }

    /// Pull the first active block from a probe-33 text and build a model.
    /// Returns nil when the file is absent (fresh clone) or has no active block.
    private static func firstActiveDP(folder: String,
                                      blockOffset: Int = 0) -> IOPortTransportStateDisplayPort? {
        guard let text = loadProbe33(folder: folder) else { return nil }
        let blocks = parseDPNode33Blocks(text: text)
        var activeCount = 0
        for (i, props) in blocks.enumerated() {
            guard (props["Active"] as? NSNumber)?.boolValue == true else { continue }
            if activeCount < blockOffset {
                activeCount += 1
                continue
            }
            return makeUpdate(props: props, id: UInt64(i))?.status
        }
        return nil
    }

    // MARK: - Helper: EDID hex extraction
    //
    // Probe 33 stores EDID as `Metadata.EDID = <N bytes serial-redacted> HEX...`
    // We strip the `<...>` prefix and decode the hex to pass real EDID bytes to
    // `DisplayDiagnostic(dp:)`. This exercises the production EDID-parse path.
    //
    // Note: the "serial-redacted" prefix marks that the serial-number bytes
    // within the EDID were zeroed before storage, for privacy. The monitor name,
    // timings, and range-limits are intact.

    private static func edidData(folder: String, blockOffset: Int = 0) -> Data? {
        guard let text = loadProbe33(folder: folder) else { return nil }
        let blocks = parseDPNode33Blocks(text: text)
        var activeCount = 0
        for props in blocks {
            guard (props["Active"] as? NSNumber)?.boolValue == true else { continue }
            if activeCount < blockOffset {
                activeCount += 1
                continue
            }
            // Metadata.EDID comes through as a string value that already had
            // the `<N bytes serial-redacted>` prefix stripped by parseEqualsLine
            // (it starts with `<` so it is skipped). We need a different path:
            // find the raw Metadata dict and re-parse the EDID line from the text.
            break
        }
        return nil
    }

    /// Pull EDID hex directly from the raw probe text (bypasses parseEqualsLine's
    /// `<...>` skip rule, which correctly rejects opaque binary but misses the
    /// serial-redacted EDID format that is hex after the prefix).
    private static func edidDataFromText(folder: String,
                                         blockOffset: Int = 0) -> Data? {
        guard let text = loadProbe33(folder: folder) else { return nil }
        let blocks = text.components(separatedBy: "=== DisplayPort node")
        var activeCount = 0
        for block in blocks.dropFirst() {
            guard block.contains("Active = true") else { continue }
            if activeCount < blockOffset {
                activeCount += 1
                continue
            }
            // Match: `  Metadata.EDID = <N bytes serial-redacted> HEX`
            if let range = block.range(of: "Metadata.EDID = "),
               let lineEnd = block[range.upperBound...].firstIndex(of: "\n") {
                let rest = String(block[range.upperBound..<lineEnd])
                // Strip `<N bytes serial-redacted> ` prefix
                if let anglEnd = rest.range(of: "> ") {
                    let hexStr = String(rest[anglEnd.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                    return hexFromString(hexStr)
                }
            }
            break
        }
        return nil
    }

    private static func hexFromString(_ s: String) -> Data? {
        let hex = s.replacingOccurrences(of: " ", with: "")
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<j], radix: 16) else { return nil }
            data.append(byte)
            i = j
        }
        return data.isEmpty ? nil : data
    }

    // MARK: - Individual machine tests

    // MARK: m4max_macos26.5.1_b -- Dell U4320Q on the M4 Max MBP's native HDMI port, HBR3 4/4 lanes
    //
    // Ground truth (probe 33):
    //   Monitor: DELL U4320Q (4K 43", 3840x2160 preferred)
    //   Link: 4 of 4 lanes, 8.1 Gbps (HBR3), tunneled=false
    //   ParentPortType=6, ParentPortTypeDescription="HDMI", ParentPortNumber=1
    //     (the SoC's native HDMI port, not a CalDigit TS4 dock as an earlier
    //     comment guessed; issue #352)
    //   BranchDeviceID: "pHDMIg" (the Mac's internal HDMI bridge)
    //   DFPType: absent at top level; Metadata.DFP Type Description = "HDMI"
    //   EDID: preferred 3840x2160@60Hz, max_pclk=600 MHz
    //   Bandwidth: needed=14.4 Gbps, delivered=4*8.1*0.8=25.92 Gbps --> .fine
    //   sinkType MUST be nil here: the SoC drives HDMI directly, so there
    //   is no USB-C-to-HDMI adapter to blame (issue #352).

    @Test("m4max_macos26.5.1_b: Dell U4320Q on native HDMI port at HBR3 4-lane -- verdict fine, no adapter blame")
    func m4maxDellU4320Q() throws {
        guard let dp = Self.firstActiveDP(folder: "m4max_macos26.5.1_b") else { return }
        guard let edid = Self.edidDataFromText(folder: "m4max_macos26.5.1_b") else { return }

        let diag = try #require(DisplayDiagnostic(dp: dp, edid: EDIDInfo(edid)))
        // Dell U4320Q 4K: preferred 3840x2160@60 with max_pclk 600MHz.
        // 4x8.1x0.8=25.92 Gbps > 14.4 Gbps needed --> .fine.
        #expect(diag.bottleneck == .fine, "Dell U4320Q at HBR3 4-lane should be fine, got \(diag.bottleneck)")
        #expect(diag.isWarning == false)
        // Sanity: the link numbers round-tripped correctly.
        #expect(diag.facts.lanes == 4)
        #expect(diag.facts.maxLanes == 4)
        #expect(diag.facts.rateDescription == "8.1 Gbps (HBR3)")
        // Issue #352: this is the M4 Max MBP's *native* HDMI port (probe has
        // ParentPortType=6, ParentPortTypeDescription="HDMI", ParentPortNumber=1),
        // not a CalDigit TS4 path as the earlier comment guessed. There's no
        // adapter on the chain; the SoC drives HDMI directly. So sinkType must
        // stay nil here so the verdict can't blame an adapter and so the DSC
        // carve-out is reachable for marginal-link cases.
        #expect(diag.facts.sinkType == nil)
        // branchDevice label: "pHDMIg" doesn't start with "Dp", so it passes through as-is.
        #expect(diag.facts.branchDevice == "pHDMIg")
    }

    // MARK: m2pro_macos26.6 -- AORUS FO32U2P 4K240, HBR3 4/4 lanes, direct DP
    //
    // Ground truth:
    //   Monitor: AORUS FO32U2P (4K 240Hz gaming monitor)
    //   Link: 4 of 4 lanes, 8.1 Gbps (HBR3), tunneled=false
    //   DFPType: absent, BranchDeviceID: absent
    //   EDID: preferred 3840x2160@60, max_pclk=2340 MHz (240Hz ceiling)
    //   Bandwidth: needed=56.16 Gbps, delivered=25.92 Gbps, at ceiling (4/4 HBR3)
    //   Expected verdict: .compressionPlausible (link maxed, DSC likely in use)
    //   DSC coverage limit: we confirm .compressionPlausible but cannot confirm DSC
    //   is actually running without probe data. Do NOT assert .fine here.

    @Test("m2pro_macos26.6: AORUS FO32U2P 4K240 at HBR3 4-lane -- compressionPlausible (link ceiling)")
    func m2proDellFO32U2P() throws {
        guard let dp = Self.firstActiveDP(folder: "m2pro_macos26.6") else { return }
        guard let edid = Self.edidDataFromText(folder: "m2pro_macos26.6") else { return }

        let diag = try #require(DisplayDiagnostic(dp: dp, edid: EDIDInfo(edid)))
        // At the DP ceiling (every lane, HBR3). The monitor needs ~56 Gbps
        // uncompressed for 240Hz but the link tops at ~26 Gbps. DSC most likely
        // carries it. The diagnostic must NOT warn: compressionPlausible, not belowMonitorMax.
        #expect(diag.bottleneck == .compressionPlausible,
            "FO32U2P at ceiling should be compressionPlausible, got \(diag.bottleneck)")
        #expect(diag.isWarning == false,
            "compressionPlausible must not be a warning (would wrongly alarm users with DSC monitors)")
        #expect(diag.facts.lanes == 4)
        #expect(diag.facts.rateDescription == "8.1 Gbps (HBR3)")
        // m2pro_macos26.6 probe 33 has no DFP Type Description at all (direct native DP).
        #expect(diag.facts.sinkType == nil, "No DFP adapter in the chain")
        // Monitor name must parse from the real EDID.
        #expect(diag.facts.monitorName == "AORUS FO32U2P")
    }

    // MARK: m1_macos26.5_m -- Dell U3425WE ultrawide, HBR3 4/4 lanes, direct DP
    //
    // Ground truth:
    //   Monitor: DELL U3425WE (3440x1440 WQHD ultrawide, up to 120Hz)
    //   Link: 4 of 4 lanes, 8.1 Gbps (HBR3), tunneled=false
    //   EDID: preferred 3440x1440@60, max_pclk=670 MHz
    //   Bandwidth: needed=16.08 Gbps, delivered=25.92 Gbps --> .fine
    //   Cable exoneration: link is already fine (no shortfall to attribute).

    @Test("m1_macos26.5_m: Dell U3425WE ultrawide at HBR3 4-lane -- verdict fine")
    func m1DellU3425WE() throws {
        guard let dp = Self.firstActiveDP(folder: "m1_macos26.5_m") else { return }
        guard let edid = Self.edidDataFromText(folder: "m1_macos26.5_m") else { return }

        let diag = try #require(DisplayDiagnostic(dp: dp, edid: EDIDInfo(edid)))
        // 4x8.1x0.8=25.92 delivered > 16.08 needed at 120Hz max --> .fine.
        #expect(diag.bottleneck == .fine, "U3425WE at HBR3 4-lane should be fine, got \(diag.bottleneck)")
        #expect(diag.isWarning == false)
        #expect(diag.facts.lanes == 4)
        // Monitor name from EDID.
        #expect(diag.facts.monitorName == "DELL U3425WE")
    }

    // MARK: m1_macos26.5_p -- Lenovo P24h-20, HBR2 2/2 lanes, BranchDeviceID=Dp1.2 (dock)
    //
    // Ground truth:
    //   Monitor: LEN P24h-20 (2560x1440 IPS, max 75Hz)
    //   Link: 2 of 2 lanes, 5.4 Gbps (HBR2), tunneled=false
    //   BranchDeviceID: "Dp1.2" (Lenovo dock reporting DisplayPort 1.2)
    //   DFPType: absent (so NO adapterLimit -- "Dp1.2" is a DP hub, not HDMI/DVI/VGA)
    //   EDID: preferred 2560x1440@60, max_pclk=300 MHz (75Hz)
    //   Bandwidth: needed=7.2 Gbps, delivered=2x5.4x0.8=8.64 Gbps --> .fine
    //   The link is NOT at the DP ceiling (2 lanes < HBR3 threshold, but it delivers
    //   enough for 75Hz). branchDevice label normalises to "DisplayPort 1.2".

    @Test("m1_macos26.5_p: Lenovo P24h-20 via Dp1.2 dock at HBR2 2-lane -- verdict fine, branchDevice normalised")
    func m1LenovoP24h20() throws {
        guard let dp = Self.firstActiveDP(folder: "m1_macos26.5_p") else { return }
        guard let edid = Self.edidDataFromText(folder: "m1_macos26.5_p") else { return }

        let diag = try #require(DisplayDiagnostic(dp: dp, edid: EDIDInfo(edid)))
        // 2x5.4x0.8=8.64 Gbps > 7.2 Gbps needed --> .fine.
        #expect(diag.bottleneck == .fine, "P24h-20 at HBR2 2-lane delivers enough for 75Hz, got \(diag.bottleneck)")
        #expect(diag.isWarning == false)
        // "Dp1.2" normalises to "DisplayPort 1.2" via branchDeviceLabel.
        #expect(diag.facts.branchDevice == "DisplayPort 1.2",
            "BranchDeviceID 'Dp1.2' must normalise to 'DisplayPort 1.2', got \(diag.facts.branchDevice ?? "nil")")
        // Lenovo P24h-20: DFP Type Description = "DP" (not HDMI/DVI/VGA), so sinkType is nil.
        #expect(diag.facts.sinkType == nil)
        #expect(diag.facts.lanes == 2)
        #expect(diag.facts.maxLanes == 2)
        #expect(diag.facts.monitorName == "LEN P24h-20")
    }

    // MARK: m2max_macos26.5.1 -- Apple Studio Display, HBR2 4/4 lanes, tunneled
    //
    // Ground truth:
    //   Monitor: Apple Studio Display (5K -- but EDID reports 3840x2160@60 preferred,
    //   no range-limits descriptor, max_pclk from DTD scan gives ~533 MHz)
    //   Link: 4 of 4 lanes, 5.4 Gbps (HBR2), tunneled=true
    //   Bandwidth: needed ~12.7 Gbps (from preferred DTD pclk 533 MHz), delivered=17.28 Gbps --> .fine
    //   Cable exonerated: tunneled=true.
    //   Note: the Studio Display's EDID describes 3840x2160 even though the panel is 5K;
    //   the EDID under-reports the native mode. Without a CoreGraphics live mode
    //   (not in probe data), the diagnostic works with what the EDID says.

    @Test("m2max_macos26.5.1: Apple Studio Display tunneled 4-lane HBR2 -- verdict fine, cable exonerated")
    func m2maxStudioDisplay() throws {
        guard let dp = Self.firstActiveDP(folder: "m2max_macos26.5.1", blockOffset: 1) else { return }
        guard let edid = Self.edidDataFromText(folder: "m2max_macos26.5.1", blockOffset: 1) else { return }

        guard let edidInfo = EDIDInfo(edid) else { return }
        let diag = try #require(DisplayDiagnostic(dp: dp, edid: edidInfo))
        // 4x5.4x0.8=17.28 Gbps delivered > ~12.7 Gbps needed for the EDID-described mode.
        #expect(diag.bottleneck == .fine, "Studio Display tunneled should be fine, got \(diag.bottleneck)")
        #expect(diag.isWarning == false)
        #expect(diag.cableAssessment == .unlikelyTheCable,
            "Tunneled link must exonerate the cable")
        #expect(diag.facts.lanes == 4)
        #expect(dp.link.tunneled == true)
        // Monitor name from the EDID.
        #expect(diag.facts.monitorName == "StudioDisplay")
    }

    // MARK: m3max_macos26.5_f block 1 -- Apple Studio Display (second machine, tunneled HBR2 4/4)
    //
    // Ground truth: same monitor class as m2max above (Studio Display, tunneled 4-lane HBR2).
    // Tests that the pattern holds across machines and validates the dual-display
    // machine correctly indexes its active blocks.

    @Test("m3max_macos26.5_f: Studio Display tunneled 4-lane HBR2 -- verdict fine")
    func m3maxStudioDisplay() throws {
        guard let dp = Self.firstActiveDP(folder: "m3max_macos26.5_f", blockOffset: 0) else { return }
        guard let edid = Self.edidDataFromText(folder: "m3max_macos26.5_f", blockOffset: 0) else { return }

        guard let edidInfo = EDIDInfo(edid) else { return }
        let diag = try #require(DisplayDiagnostic(dp: dp, edid: edidInfo))
        #expect(diag.bottleneck == .fine)
        #expect(diag.cableAssessment == .unlikelyTheCable, "Tunneled must exonerate cable")
        #expect(diag.facts.monitorName == "StudioDisplay")
    }

    // MARK: m3max_macos26.5_f block 2 -- Dell S2725QC, HBR3 4/4 lanes, direct DP
    //
    // Ground truth (second active block on the same machine):
    //   Monitor: DELL S2725QC (4K 27", up to 120Hz)
    //   Link: 4 of 4 lanes, 8.1 Gbps (HBR3), tunneled=false
    //   EDID: preferred 3840x2160@60, max_pclk=1190 MHz (from DTD)
    //   Bandwidth: needed=28.56 Gbps, delivered=25.92 Gbps, at ceiling (4/4 HBR3)
    //   Expected: .compressionPlausible -- the link is maxed, shortfall is
    //   likely DSC. Must NOT warn.

    @Test("m3max_macos26.5_f: Dell S2725QC 4K at HBR3 4-lane -- compressionPlausible (second display block)")
    func m3maxDellS2725QC() throws {
        guard let dp = Self.firstActiveDP(folder: "m3max_macos26.5_f", blockOffset: 1) else { return }
        guard let edid = Self.edidDataFromText(folder: "m3max_macos26.5_f", blockOffset: 1) else { return }

        guard let edidInfo = EDIDInfo(edid) else { return }
        let diag = try #require(DisplayDiagnostic(dp: dp, edid: edidInfo))
        // At ceiling (4/4 HBR3). Max_pclk from DTD 1190 MHz x 24bpp = 28.56 Gbps > 25.92.
        #expect(diag.bottleneck == .compressionPlausible,
            "S2725QC at HBR3 ceiling should be compressionPlausible, got \(diag.bottleneck)")
        #expect(diag.isWarning == false)
        #expect(diag.facts.lanes == 4)
        #expect(diag.facts.rateDescription == "8.1 Gbps (HBR3)")
        #expect(diag.facts.monitorName == "DELL S2725QC")
    }

    // MARK: m2pro_macos26.5_c -- Dell U2725QE, HBR2 4/4 lanes, tunneled, 120Hz max
    //
    // Ground truth:
    //   Monitor: DELL U2725QE (4K 27", max 120Hz, max_pclk 1100 MHz)
    //   Link: 4 of 4 lanes, 5.4 Gbps (HBR2), tunneled=true
    //   Bandwidth: needed=26.4 Gbps, delivered=17.28 Gbps, NOT at ceiling (HBR2 < 8.0)
    //   Expected: .belowMonitorMax (shortfall that could be mode selection vs link cap)
    //   Cable exoneration: tunneled=true, so cableAssessment=.unlikelyTheCable
    //   The detail copy must mention "tunnel" and "unlikely to be the cable".
    //
    // This is the key "tunneled but still belowMonitorMax" case: the cable is
    // exonerated on the tunnel evidence, but the link itself is genuinely below
    // what the monitor can do at 120Hz.

    @Test("m2pro_macos26.5_c: Dell U2725QE tunneled 4-lane HBR2 -- belowMonitorMax, cable exonerated via tunnel")
    func m2proDellU2725QE() throws {
        guard let dp = Self.firstActiveDP(folder: "m2pro_macos26.5_c", blockOffset: 1) else { return }
        guard let edid = Self.edidDataFromText(folder: "m2pro_macos26.5_c", blockOffset: 1) else { return }

        guard let edidInfo = EDIDInfo(edid) else { return }
        let diag = try #require(DisplayDiagnostic(dp: dp, edid: edidInfo))
        // 4x5.4x0.8=17.28 Gbps < 26.4 Gbps needed; NOT at ceiling (HBR2 per-lane < 8.0).
        #expect(diag.bottleneck == .belowMonitorMax,
            "U2725QE at HBR2 below 120Hz cap should be belowMonitorMax, got \(diag.bottleneck)")
        #expect(diag.isWarning == true)
        // The tunnel proves the cable isn't the bottleneck.
        #expect(diag.cableAssessment == .unlikelyTheCable,
            "Tunneled link must exonerate cable even when verdict is belowMonitorMax")
        #expect(diag.detail.lowercased().contains("tunnel"),
            "Detail must mention tunnel for the cable-exoneration wording")
        #expect(diag.detail.lowercased().contains("unlikely to be the cable"),
            "Detail must say cable is unlikely the cause when tunneled")
        #expect(diag.facts.monitorName == "DELL U2725QE")
    }

    // MARK: m1_macos26.5_o -- MSI MP273 FHD, HBR3 2/2 lanes, direct DP
    //
    // Ground truth:
    //   Monitor: MSI MP273 (1920x1080 FHD, max 75Hz)
    //   Link: 2 of 2 lanes, 8.1 Gbps (HBR3), tunneled=false
    //   EDID: preferred 1920x1080@60, max_pclk=180 MHz (75Hz)
    //   Bandwidth: needed=4.32 Gbps, delivered=2x8.1x0.8=12.96 Gbps --> .fine
    //   Note: this is 2 of 2 lanes at HBR3. maxLanes=2 (M1's single-port
    //   alt-mode exposes 2 lanes). The link delivers enough; verdict is .fine.
    //   (No ceiling guard fires: lanes==maxLanes and perLane>=8.0, but needed<delivered,
    //   so the .fine check triggers before the ceiling check.)

    @Test("m1_macos26.5_o: MSI MP273 FHD at HBR3 2-lane -- verdict fine (all lanes in use)")
    func m1MSI_MP273() throws {
        guard let dp = Self.firstActiveDP(folder: "m1_macos26.5_o") else { return }
        guard let edid = Self.edidDataFromText(folder: "m1_macos26.5_o") else { return }

        guard let edidInfo = EDIDInfo(edid) else { return }
        let diag = try #require(DisplayDiagnostic(dp: dp, edid: edidInfo))
        // 2x8.1x0.8=12.96 Gbps > 4.32 Gbps needed --> .fine.
        #expect(diag.bottleneck == .fine, "MSI MP273 at HBR3 2-lane should be fine, got \(diag.bottleneck)")
        #expect(diag.isWarning == false)
        #expect(diag.facts.lanes == 2)
        #expect(diag.facts.maxLanes == 2)
        #expect(diag.facts.monitorName == "MSI MP273")
    }

    // MARK: m2ultra_macos26.5 block 0 -- Dell P2219H FHD on the M2 Ultra Mac Studio's native HDMI port
    //
    // Ground truth (probe 33):
    //   Monitor: DELL P2219H (1920x1080 FHD, max 76Hz)
    //   Link: 4 of 4 lanes, 8.1 Gbps (HBR3), tunneled=false
    //   ParentPortType=6, ParentPortTypeDescription="HDMI", ParentPortNumber=2
    //     (the Mac Studio's native HDMI socket, issue #352)
    //   BranchDeviceID: "pHDMIg"; DFPType absent at top level
    //   EDID: preferred 1920x1080@60, max_pclk=170 MHz (76Hz)
    //   Bandwidth: needed=4.08 Gbps, delivered=25.92 Gbps --> .fine
    //   sinkType MUST be nil here: same reasoning as the m4max case above.

    @Test("m2ultra_macos26.5: Dell P2219H on native HDMI port at HBR3 4-lane -- verdict fine, no adapter blame")
    func m2ultraDellP2219H() throws {
        guard let dp = Self.firstActiveDP(folder: "m2ultra_macos26.5", blockOffset: 0) else { return }
        guard let edid = Self.edidDataFromText(folder: "m2ultra_macos26.5", blockOffset: 0) else { return }

        guard let edidInfo = EDIDInfo(edid) else { return }
        let diag = try #require(DisplayDiagnostic(dp: dp, edid: edidInfo))
        // 4x8.1x0.8=25.92 Gbps > 4.08 Gbps needed --> .fine
        #expect(diag.bottleneck == .fine, "Dell P2219H at HBR3 should be fine, got \(diag.bottleneck)")
        #expect(diag.isWarning == false)
        // Issue #352: M2 Ultra Mac Studio's native HDMI port (probe has
        // ParentPortType=6, ParentPortTypeDescription="HDMI", ParentPortNumber=2).
        // sinkType stays nil on the native HDMI path so the diagnostic can't
        // wrongly blame a USB-C-to-HDMI adapter that isn't there.
        #expect(diag.facts.sinkType == nil)
        #expect(diag.facts.branchDevice == "pHDMIg")
        #expect(diag.facts.monitorName == "DELL P2219H")
    }

    // MARK: m2ultra_macos26.5 block 1 -- Samsung U28H75x 4K, HBR2 4/4 lanes, direct DP
    //
    // Ground truth:
    //   Monitor: Samsung U28H75x (3840x2160 4K 28", max 75Hz)
    //   Link: 4 of 4 lanes, 5.4 Gbps (HBR2), tunneled=false
    //   EDID: preferred 3840x2160@60, max_pclk=600 MHz
    //   Bandwidth: needed=14.4 Gbps, delivered=4x5.4x0.8=17.28 Gbps --> .fine
    //   (This is the second display on the same M2 Ultra machine.)

    @Test("m2ultra_macos26.5: Samsung U28H75x 4K at HBR2 4-lane -- verdict fine (second display)")
    func m2ultraSamsungU28H75x() throws {
        guard let dp = Self.firstActiveDP(folder: "m2ultra_macos26.5", blockOffset: 1) else { return }
        guard let edid = Self.edidDataFromText(folder: "m2ultra_macos26.5", blockOffset: 1) else { return }

        guard let edidInfo = EDIDInfo(edid) else { return }
        let diag = try #require(DisplayDiagnostic(dp: dp, edid: edidInfo))
        // 4x5.4x0.8=17.28 Gbps > 14.4 Gbps needed --> .fine.
        #expect(diag.bottleneck == .fine, "Samsung U28H75x 4K at HBR2 should be fine, got \(diag.bottleneck)")
        #expect(diag.isWarning == false)
        #expect(diag.facts.lanes == 4)
        #expect(diag.facts.monitorName == "U28H75x")
    }

    // MARK: - Sweep: no active block silently returns nil

    @Test("Sweep: inactive DP blocks must not produce a diagnostic (active=false guard)")
    func inactiveBlocksProduceNoDiagnostic() {
        // Confirm that the `guard dp.link.active else { return nil }` in
        // DisplayDiagnostic.init fires correctly on real corpus data.
        // We sample all inactive blocks from our fixture machines and confirm nil.
        let machines = [
            "m4max_macos26.5.1_b", "m2pro_macos26.6", "m1_macos26.5_m",
            "m1_macos26.5_p", "m2max_macos26.5.1", "m3max_macos26.5_f",
            "m2pro_macos26.5_c", "m1_macos26.5_o", "m2ultra_macos26.5",
        ]
        var inactiveChecked = 0
        for folder in machines {
            guard let text = Self.loadProbe33(folder: folder) else { continue }
            let blocks = Self.parseDPNode33Blocks(text: text)
            for (i, props) in blocks.enumerated() {
                guard (props["Active"] as? NSNumber)?.boolValue == false else { continue }
                guard let update = Self.makeUpdate(props: props, id: UInt64(i)) else { continue }
                let dp = update.status
                // An inactive block must produce nil from DisplayDiagnostic.
                let diag = DisplayDiagnostic(dp: dp, edid: nil)
                #expect(diag == nil,
                    "Inactive DP block in \(folder) must yield nil diagnostic, but got non-nil")
                inactiveChecked += 1
            }
        }
        // Guard: at least some inactive blocks were checked (confirms the test ran).
        // Most machines have 1-3 inactive ports. If the files are absent (fresh clone),
        // inactiveChecked stays 0 and we skip the guard.
        if inactiveChecked > 0 {
            #expect(inactiveChecked >= 3,
                "Expected to check at least 3 inactive blocks across fixture machines; got \(inactiveChecked)")
        }
    }

    // MARK: - Sweep: BuiltInDisplayPort grouping over the real corpus (issue #352)

    /// Walk every probe-33 folder, parse each block through the same
    /// `makeUpdate` path the live watcher uses, and feed the resulting
    /// statuses to `BuiltInDisplayPort.group`. Any folder whose probe text
    /// contains `ParentPortTypeDescription = "HDMI"` for an active block
    /// MUST yield at least one `BuiltInDisplayPort` after grouping. Any
    /// folder with only USB-C / tunnelled parents MUST yield zero.
    ///
    /// This catches a class of bug where the grouping function gates on a
    /// field that isn't actually emitted by IOKit. The earlier draft used
    /// `parentPortBuiltIn` as a guard; 0 of 79 corpus HDMI blocks emit
    /// that field, so the feature would have shipped dead despite all
    /// synthesized unit tests passing.
    @Test("Sweep: BuiltInDisplayPort.group surfaces every native HDMI port in the corpus")
    func sweepBuiltInDisplayPortGrouping() throws {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(atPath: Self.probeRoot.path) else {
            return // fresh clone, corpus not synced; skip
        }
        var foldersWithProbe33 = 0
        var foldersWithHDMI = 0
        var foldersGroupedAsHDMI = 0
        var foldersOnlyUSBC = 0
        var foldersGroupedAsUSBC = 0
        for folder in folders {
            guard let text = Self.loadProbe33(folder: folder) else { continue }
            foldersWithProbe33 += 1
            let blocks = Self.parseDPNode33Blocks(text: text)
            // Build the live model the same way the watcher does.
            let statuses = blocks.enumerated().compactMap { i, props in
                Self.makeUpdate(props: props, id: UInt64(i))?.status
            }
            let groups = BuiltInDisplayPort.group(from: statuses)

            // Did the raw probe text claim any active HDMI parent?
            let hasActiveHDMI = blocks.contains { props in
                guard (props["Active"] as? NSNumber)?.boolValue == true else { return false }
                guard let type = props["ParentPortTypeDescription"] as? String else { return false }
                guard let tunneled = (props["Tunneled"] as? NSNumber)?.boolValue, !tunneled else { return false }
                return type.uppercased() == "HDMI"
            }
            let hasAnyUSBCOnly = blocks.allSatisfy { props in
                guard (props["Active"] as? NSNumber)?.boolValue == true else { return true }
                let type = (props["ParentPortTypeDescription"] as? String)?.uppercased()
                return type == "USB-C" || type == nil
            } && !hasActiveHDMI

            if hasActiveHDMI {
                foldersWithHDMI += 1
                if !groups.isEmpty {
                    foldersGroupedAsHDMI += 1
                } else {
                    Issue.record("\(folder) has an active HDMI parent in the probe but BuiltInDisplayPort.group returned empty")
                }
            } else if hasAnyUSBCOnly {
                foldersOnlyUSBC += 1
                if groups.isEmpty {
                    foldersGroupedAsUSBC += 1
                } else {
                    Issue.record("\(folder) has only USB-C / tunnelled active parents but BuiltInDisplayPort.group returned \(groups.count) entries")
                }
            }
        }
        // Guard against a silent skip (no corpus on disk in this checkout).
        if foldersWithHDMI > 0 {
            #expect(foldersGroupedAsHDMI == foldersWithHDMI,
                "Expected every folder with an HDMI parent (\(foldersWithHDMI)) to surface in grouping, got \(foldersGroupedAsHDMI)")
        }
        if foldersOnlyUSBC > 0 {
            #expect(foldersGroupedAsUSBC == foldersOnlyUSBC,
                "Expected every USB-C-only folder (\(foldersOnlyUSBC)) to yield no HDMI groups, got \(foldersOnlyUSBC - foldersGroupedAsUSBC) leaks")
        }
        // Floor: at minimum N HDMI-bearing folders must be in the sweep so
        // a future corpus that lost most of them (selective re-fetch, partial
        // sync) doesn't silently degrade this into a near-vacuous check.
        // Actual 23 such folders as of 2026-07 (up from 14). Native-HDMI is a
        // narrow, curated signal (only ~5-6% of the 410-folder corpus), so
        // unlike the broader per-probe floors elsewhere in this file the
        // usual ~85-90%-of-actual policy would leave almost no slack for
        // routine dedup/curation churn; 15 (~65% of actual, 3x the old stale
        // floor of 5) still catches a real regression without that risk.
        //
        // Two-tier reality: only 9 probe-33 files are git-tracked (the named
        // fixtures the other two tests in this file use directly), out of
        // ~240 with probe 33 on disk. Gate on a raw-corpus-presence threshold
        // (50) well above that 9-file fresh-clone case, so a fresh clone
        // SKIPS this floor instead of failing it, while the correctness
        // checks above (`foldersGroupedAsHDMI == foldersWithHDMI`,
        // `foldersGroupedAsUSBC == foldersOnlyUSBC`) keep running against
        // whatever data is present, tracked-only or full corpus alike.
        if foldersWithProbe33 >= 50 {
            #expect(foldersWithHDMI >= 15,
                "Only \(foldersWithHDMI) folder(s) with active HDMI parents found across the corpus; sweep is near-vacuous, restore HDMI fixtures")
        }
    }

    // MARK: - Sweep: every active block with a parseable EDID produces a non-nil diagnostic

    @Test("Sweep: every active block with readable EDID from fixtures produces a diagnostic")
    func allActiveBlocksWithEdidProduceDiagnostic() {
        let machines = [
            "m4max_macos26.5.1_b", "m2pro_macos26.6", "m1_macos26.5_m",
            "m1_macos26.5_p", "m2max_macos26.5.1", "m3max_macos26.5_f",
            "m2pro_macos26.5_c", "m1_macos26.5_o", "m2ultra_macos26.5",
        ]
        var checked = 0
        var withDiag = 0

        for folder in machines {
            guard let text = Self.loadProbe33(folder: folder) else { continue }
            let rawBlocks = text.components(separatedBy: "=== DisplayPort node")
            let parsedBlocks = Self.parseDPNode33Blocks(text: text)

            for (i, props) in parsedBlocks.enumerated() {
                guard (props["Active"] as? NSNumber)?.boolValue == true else { continue }
                guard let update = Self.makeUpdate(props: props, id: UInt64(i)) else { continue }
                let dp = update.status

                // Try to extract EDID from the raw text for this block.
                var edidInfo: EDIDInfo? = nil
                if i + 1 < rawBlocks.count {
                    let rawBlock = rawBlocks[i + 1]
                    if rawBlock.contains("Metadata.EDID = "),
                       let rangeStart = rawBlock.range(of: "Metadata.EDID = "),
                       let lineEnd = rawBlock[rangeStart.upperBound...].firstIndex(of: "\n") {
                        let rest = String(rawBlock[rangeStart.upperBound..<lineEnd])
                        if let anglEnd = rest.range(of: "> ") {
                            let hexStr = String(rest[anglEnd.upperBound...]).trimmingCharacters(in: .whitespaces)
                            if let data = Self.hexFromString(hexStr) {
                                edidInfo = EDIDInfo(data)
                            }
                        }
                    }
                }

                checked += 1
                let diag = DisplayDiagnostic(dp: dp, edid: edidInfo)
                #expect(diag != nil,
                    "Active DP block \(i) in \(folder) must produce a DisplayDiagnostic")
                if diag != nil { withDiag += 1 }
            }
        }

        // Guard: at least 9 active blocks checked (1 per fixture machine minimum).
        if checked > 0 {
            #expect(checked >= 9,
                "Expected at least 9 active DP blocks across fixture machines; got \(checked)")
            #expect(withDiag == checked,
                "Every active block must produce a diagnostic; got \(withDiag)/\(checked)")
        }
    }

    // MARK: - Corpus-level: no .belowMonitorMax warning on any "fine" machine

    @Test("Sweep: none of the fine-verdict fixture machines emits a warning")
    func fineVerdictMachinesDoNotWarn() {
        // These machines are confirmed .fine at their active link state.
        // They must not produce isWarning=true.
        let fineMachines: [(String, Int)] = [
            ("m4max_macos26.5.1_b", 0),  // Dell U4320Q
            ("m1_macos26.5_m", 0),        // Dell U3425WE
            ("m1_macos26.5_p", 0),        // Lenovo P24h-20
            ("m1_macos26.5_o", 0),        // MSI MP273
            ("m2ultra_macos26.5", 1),      // Samsung U28H75x
            ("m2ultra_macos26.5", 0),      // Dell P2219H
        ]

        for (folder, offset) in fineMachines {
            guard let dp = Self.firstActiveDP(folder: folder, blockOffset: offset) else { continue }
            guard let text = Self.loadProbe33(folder: folder) else { continue }

            // Extract EDID for the correct active block.
            var edidData: Data? = nil
            let rawBlocks = text.components(separatedBy: "=== DisplayPort node")
            var activeCount = 0
            for rawBlock in rawBlocks.dropFirst() {
                guard rawBlock.contains("Active = true") else { continue }
                if activeCount < offset {
                    activeCount += 1
                    continue
                }
                if rawBlock.contains("Metadata.EDID = "),
                   let rangeStart = rawBlock.range(of: "Metadata.EDID = "),
                   let lineEnd = rawBlock[rangeStart.upperBound...].firstIndex(of: "\n") {
                    let rest = String(rawBlock[rangeStart.upperBound..<lineEnd])
                    if let anglEnd = rest.range(of: "> ") {
                        let hexStr = String(rest[anglEnd.upperBound...]).trimmingCharacters(in: .whitespaces)
                        edidData = Self.hexFromString(hexStr)
                    }
                }
                break
            }

            guard let data = edidData, let edidInfo = EDIDInfo(data) else { continue }
            guard let diag = DisplayDiagnostic(dp: dp, edid: edidInfo) else { continue }

            #expect(diag.isWarning == false,
                "\(folder) offset=\(offset): expected no warning (fine verdict), got bottleneck=\(diag.bottleneck)")
        }
    }
}
