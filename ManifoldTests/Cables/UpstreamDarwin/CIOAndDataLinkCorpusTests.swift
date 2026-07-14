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

/// Corpus-back tests for CIO cable capability parsing and DataLink diagnostic
/// inputs from probes 17 and 19. Covers (DAR-138):
///
/// (a) CIO verdict-level assertions: per-machine CableSpeed values cross-checked
///     against `research/cio-value-mappings.md`. Only `cableSpeed` is asserted
///     against corpus-confirmed mappings; `cableGeneration`, `generation`, and
///     `linkTrainingMode` are confirmed-unstable/unconfirmed and are NOT asserted.
///
/// (b) DataLink diagnostic: USB3/TRM inputs from probes 17/19 joined with port
///     data from probe 01. Verifies that TRM-restricted ports do not produce a
///     `.fine` verdict (the DAR-134 regression class).
///
/// Helpers are file-private; no shared ProbeCorpus.swift dependency.
@Suite("CIO capability and DataLink input paths -- corpus sweep (DAR-138)", .disabled(if: !ProbeCorpus.isAvailable, "Customer-probe corpus is absent from the supplied upstream clone."))
struct CIOAndDataLinkCorpusTests {

    // MARK: - Probe root

    private static let probeRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableDarwinTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .deletingLastPathComponent().appendingPathComponent("research/customer-probes")
    }()

    // MARK: - Probe file loader

    /// Load the "output" text from a numbered probe JSON inside a folder.
    private static func loadProbeText(folder: String, probe: String) -> String? {
        let url = probeRoot
            .appendingPathComponent(folder)
            .appendingPathComponent("\(probe).json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = root["output"] as? String
        else { return nil }
        return text
    }

    // MARK: - Block parsers (file-private)

    /// Parse `=== ClassName ===` style blocks (4-space-indented properties).
    /// Used for CIO blocks in probe 17's HPM deep-dive section.
    private static func parseEqualsBlocks(text: String, className: String) -> [[String: Any]] {
        let header = "=== \(className) ==="
        var blocks: [[String: Any]] = []
        var searchFrom = text.startIndex
        while let range = text.range(of: header, range: searchFrom..<text.endIndex) {
            let bodyStart = range.upperBound
            let rest = String(text[bodyStart...])
            let body: String
            if let nextSection = rest.range(of: "\n=== ") ?? rest.range(of: "\n--- ") {
                body = String(rest[..<nextSection.lowerBound])
            } else {
                body = String(rest.prefix(2000))
            }
            blocks.append(parseProperties(body: body, indent: "    "))
            searchFrom = range.upperBound
        }
        return blocks
    }

    /// Parse `--- ClassName[N] ---` style blocks (2-space-indented properties).
    /// Used for USB2/USB3 blocks in probe 17's flat-services section,
    /// and USB3 blocks in probe 19.
    private static func parseDashBlocks(text: String, classPrefix: String) -> [[String: Any]] {
        let escapedPrefix = NSRegularExpression.escapedPattern(for: classPrefix)
        guard let regex = try? NSRegularExpression(
            pattern: "--- \(escapedPrefix)\\[\\d+\\] ---")
        else { return [] }
        let nsText = text as NSString
        let headerMatches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var blocks: [[String: Any]] = []
        for (i, match) in headerMatches.enumerated() {
            let bodyStart = match.range.upperBound
            let bodyEnd = i + 1 < headerMatches.count
                ? headerMatches[i + 1].range.lowerBound
                : nsText.length
            var body = nsText.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
            for sep in ["\n---", "\n==="] {
                if let r = body.range(of: sep) { body = String(body[..<r.lowerBound]) }
            }
            blocks.append(parseProperties(body: body, indent: "  "))
        }
        return blocks
    }

    /// Convert a block body to a property dict.
    /// Supports: `N (0xHEX)` -> Int, `"quoted"` -> String, true/false -> Bool.
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
            } else if let m = parseIntLiteral(valStr) {
                props[key] = NSNumber(value: m)
            }
        }
        return props
    }

    /// Parse `N (0xHEX)` or plain integer strings.
    private static func parseIntLiteral(_ s: String) -> Int? {
        if let spaceIdx = s.firstIndex(of: " ") {
            if let v = Int(s[..<spaceIdx]) { return v }
        }
        return Int(s)
    }

    // MARK: - Port loader (probe 01)

    /// One USB-C port extracted from a probe's 01_walk_pd_tree.json.
    private struct ProbePort {
        let serviceName: String
        let portTypeDescription: String?
        let portNumber: Int
        let transportsSupported: [String]
        let transportsActive: [String]
        let connectionActive: Bool

        var hpmInterface: AppleHPMInterface {
            AppleHPMInterface(
                id: UInt64(portNumber),
                serviceName: serviceName,
                className: portTypeDescription == "MagSafe 3"
                    ? "AppleTCControllerType11"
                    : "AppleTCControllerType10",
                portDescription: serviceName,
                portTypeDescription: portTypeDescription,
                portNumber: portNumber,
                connectionActive: connectionActive,
                activeCable: nil,
                opticalCable: nil,
                usbActive: nil,
                superSpeedActive: nil,
                usbModeType: nil,
                usbConnectString: nil,
                transportsSupported: transportsSupported,
                transportsActive: transportsActive,
                transportsProvisioned: [],
                plugOrientation: nil,
                plugEventCount: nil,
                connectionCount: nil,
                overcurrentCount: nil,
                pinConfiguration: [:],
                powerCurrentLimits: [],
                firmwareVersion: nil,
                bootFlagsHex: nil,
                rawProperties: [:]
            )
        }
    }

    private static func loadPorts(folder: String) -> [ProbePort] {
        let url = probeRoot
            .appendingPathComponent(folder)
            .appendingPathComponent("01_walk_pd_tree.json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = root["output"] as? String
        else { return [] }

        let rawChunks = text.components(separatedBy: "=== IOAccessoryManager[")
        guard rawChunks.count > 1 else { return [] }
        let parts: [String] = rawChunks.dropFirst().compactMap { chunk in
            guard let endOfHeader = chunk.range(of: "===\n") else { return nil }
            return String(chunk[endOfHeader.upperBound...])
        }
        var ports: [ProbePort] = []
        for raw in parts {
            let body: String
            if let endRange = raw.range(of: "\n=== ") {
                body = String(raw[..<endRange.lowerBound])
            } else {
                body = raw
            }
            guard body.contains("PortTypeDescription") else { continue }
            let portType = parseQuotedProp(body, key: "PortTypeDescription")
            let serviceName = parseQuotedProp(body, key: "Description") ?? "Port-Unknown@0"
            let portNumber = parseIntProp(body, key: "PortNumber") ?? 0
            let supp = parseListProp(body, key: "TransportsSupported")
            let act  = parseListProp(body, key: "TransportsActive")
            let conn = body.contains("ConnectionActive = true")
            ports.append(ProbePort(
                serviceName: serviceName,
                portTypeDescription: portType,
                portNumber: portNumber,
                transportsSupported: supp,
                transportsActive: act,
                connectionActive: conn
            ))
        }
        return ports
    }

    // Probe-01 field parsers (4-space indent in IOAccessoryManager blocks)
    private static func parseQuotedProp(_ block: String, key: String) -> String? {
        let prefix = "    \(key) = \""
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(prefix) {
                let after = line.dropFirst(prefix.count)
                guard let closing = after.firstIndex(of: "\"") else { return nil }
                return String(after[..<closing])
            }
        }
        return nil
    }

    private static func parseIntProp(_ block: String, key: String) -> Int? {
        let prefix = "    \(key) = "
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(prefix) {
                let after = line.dropFirst(prefix.count)
                let digits = after.prefix { $0.isNumber }
                return Int(digits)
            }
        }
        return nil
    }

    private static func parseListProp(_ block: String, key: String) -> [String] {
        let opener = "    \(key) = ["
        guard let openRange = block.range(of: opener) else { return [] }
        let afterOpen = block[openRange.upperBound...]
        guard let close = afterOpen.range(of: "\n    ]") else { return [] }
        let inside = afterOpen[..<close.lowerBound]
        return inside.split(separator: "\n").compactMap { line -> String? in
            guard let q1 = line.firstIndex(of: "\""),
                  let q2 = line.lastIndex(of: "\""), q1 != q2 else { return nil }
            return String(line[line.index(after: q1)..<q2])
        }
    }

    // MARK: - CIO block extractor

    /// Extract all CIO blocks from probe 17, combining both text styles
    /// (=== HPM deep-dive style and --- flat-services style).
    private static func extractCIOBlocks(text: String) -> [[String: Any]] {
        // The HPM section uses === style (4-space indent)
        var blocks = parseEqualsBlocks(text: text, className: "IOPortTransportStateCIO")
        // The flat "All IOPortTransportState* services" section uses --- style (2-space indent)
        blocks += parseDashBlocks(text: text, classPrefix: "IOPortTransportStateCIO")
        return blocks
    }

    // MARK: - Speed label validation

    /// Returns the expected speed label for a confirmed cableSpeed code,
    /// per cio-value-mappings.md. Only codes 2/3/4 are asserted.
    private static func confirmedSpeedLabel(for cableSpeed: Int) -> String? {
        switch cableSpeed {
        case 2: return "20 Gbps capable"   // TB3: one sample (M1 Max + Lenovo TB3 dock)
        case 3: return "40 Gbps capable"   // TB4: 19/27 data points in mapping doc
        case 4: return "80 Gbps capable"   // TB5: 7/27 data points in mapping doc
        default: return nil
        }
    }

    // MARK: - CIO Tests

    // MARK: (a1) CIO parse: every block produces a model, fields round-trip

    @Test("CIO parse: every block produces a model and cableSpeed round-trips (probe 17)")
    func cioEveryBlockProducesModel() {
        let machines = Self.cioFixtureMachines

        var totalBlocks = 0
        var totalModels = 0

        for machine in machines {
            guard let text = Self.loadProbeText(folder: machine, probe: "17_deep_property_dump")
            else {
                Issue.record("Missing probe 17 for fixture machine \(machine)")
                continue
            }

            let blocks = Self.extractCIOBlocks(text: text)
            for (i, props) in blocks.enumerated() {
                totalBlocks += 1
                let read: (String) -> Any? = { props[$0] }
                let model = TRMTransportWatcher.makeCIOCapability(
                    entryID: UInt64(1000 + i),
                    read: read,
                    hpmControllerUUID: nil
                )
                #expect(model != nil,
                    "Machine \(machine) CIO block \(i): makeCIOCapability should never return nil (no gate key)")
                guard let model else { continue }
                totalModels += 1

                // cableSpeed round-trips exactly
                if let speed = (props["CableSpeed"] as? NSNumber)?.intValue {
                    #expect(model.negotiatedLinkSpeed == speed,
                        "Machine \(machine) block \(i): cableSpeed round-trip: got \(model.negotiatedLinkSpeed ?? -1), expected \(speed)")
                }

                // cableGeneration round-trips (we don't assert semantic meaning here;
                // the mapping is not yet confirmed per cio-value-mappings.md)
                if let gen = (props["CableGeneration"] as? NSNumber)?.intValue {
                    #expect(model.cableGeneration == gen,
                        "Machine \(machine) block \(i): cableGeneration round-trip: got \(model.cableGeneration ?? -1), expected \(gen)")
                }

                // portKey is well-formed
                #expect(model.portKey.contains("/"),
                    "Machine \(machine) block \(i): portKey '\(model.portKey)' should contain '/'")
            }
        }

        #expect(totalBlocks >= 20,
            "Expected at least 20 CIO blocks across CIO fixtures; got \(totalBlocks)")
        #expect(totalModels == totalBlocks,
            "Every CIO block must produce a model: expected \(totalBlocks), got \(totalModels)")
    }

    // MARK: (a2) CIO speedLabel: confirmed mapping cross-check

    @Test("CIO speedLabel: confirmed codes map to the right Gbps label per cio-value-mappings.md")
    func cioSpeedLabelMapping() {
        // The cio-value-mappings.md mapping doc confirms:
        //   2 -> "20 Gbps capable" (TB3 class, 1 sample)
        //   3 -> "40 Gbps capable" (TB4 class, 19 samples)
        //   4 -> "80 Gbps capable" (TB5 class, 7 samples)
        // Unknown codes return nil. Assert only the confirmed range.
        #expect(CIOCableCapability.speedLabel(for: 2) == "20 Gbps capable")
        #expect(CIOCableCapability.speedLabel(for: 3) == "40 Gbps capable")
        #expect(CIOCableCapability.speedLabel(for: 4) == "80 Gbps capable")
        #expect(CIOCableCapability.speedLabel(for: 0) == nil)
        #expect(CIOCableCapability.speedLabel(for: 1) == nil)
        #expect(CIOCableCapability.speedLabel(for: 5) == nil)
    }

    // MARK: (a3) CIO per-machine: corpus-specific cableSpeed verdicts

    @Test("CIO per-machine: TB5 machines report cableSpeed=4, TB3 connection reports cableSpeed=2")
    func cioPerMachineSpeedExpectations() {
        // m5pro_macos26.5: CalDigit TS5 Plus (JHL9580), M5 Pro, Type7 host.
        // Per cio-value-mappings.md data point 9: CableSpeed=4 (TB5).
        assertCIOActiveSpeed(
            machine: "m5pro_macos26.5",
            expectedSpeed: 4,
            reason: "M5 Pro + CalDigit TS5 Plus (JHL9580) = TB5 link (data point 9 in mapping doc)"
        )

        // m4pro_macos26.5: Type7 host with TB5 CIO (our probe data shows speed=4)
        assertCIOActiveSpeed(
            machine: "m4pro_macos26.5",
            expectedSpeed: 4,
            reason: "M4 Pro + TB5 peer (Type7 host) = TB5 link"
        )

        // m4max_macos26.5_f block 1: speed=2 (TB3 class, JHL6540 Alpine Ridge equivalent).
        // This is the only TB3 speed=2 in our fixture set.
        assertCIOBlockContainsSpeed(
            machine: "m4max_macos26.5_f",
            requiredSpeed: 2,
            reason: "m4max_macos26.5_f has a TB3-class connection (CableSpeed=2) on one port"
        )

        // m4max_macos26.5_c block 1: speed=4 (TB5 port among mixed-speed blocks)
        assertCIOBlockContainsSpeed(
            machine: "m4max_macos26.5_c",
            requiredSpeed: 4,
            reason: "m4max_macos26.5_c has a TB5 port (CableSpeed=4) in its mixed-class setup"
        )
    }

    // MARK: (a4) CIO: legacyAdapter is always false across the corpus

    @Test("CIO legacyAdapter: always false across all fixture machines (mapping doc: never observed true)")
    func cioLegacyAdapterAlwaysFalse() {
        // Per cio-value-mappings.md: LegacyAdapter has been false on every
        // sampled connection including real TB3 docks. A true value would indicate
        // TB3-mode lane adapter; Apple Silicon apparently never sets it.
        for machine in Self.cioFixtureMachines {
            guard let text = Self.loadProbeText(folder: machine, probe: "17_deep_property_dump")
            else { continue }
            let blocks = Self.extractCIOBlocks(text: text)
            for (i, props) in blocks.enumerated() {
                let legacyRaw = props["LegacyAdapter"]
                // When present it must be false; when absent that is also expected
                if let legacy = (legacyRaw as? NSNumber)?.boolValue {
                    #expect(legacy == false,
                        "Machine \(machine) block \(i): LegacyAdapter should be false; mapping doc has never seen it true")
                }
            }
        }
    }

    // MARK: (a5) CIO: asymmetricModeSupported is a cable property (per-port variance)

    @Test("CIO asymmetricModeSupported: m3_macos26.5 reports false (cable does not support asymmetric)")
    func cioAsymmetricModePerCable() {
        // m3_macos26.5 probe shows AsymmetricModeSupported=false on the one CIO block.
        // Per cio-value-mappings.md, this is a cable-state property (PORT_CS_18.CSA)
        // populated per-connection from VDM exchange; it reflects the cable/link partner,
        // not the host port. Different machines with different cables can show different values.
        guard let text = Self.loadProbeText(folder: "m3_macos26.5", probe: "17_deep_property_dump")
        else {
            Issue.record("Missing probe 17 for m3_macos26.5")
            return
        }
        let blocks = Self.extractCIOBlocks(text: text)
        #expect(!blocks.isEmpty, "m3_macos26.5 should have at least one CIO block")

        var foundFalse = false
        for (i, props) in blocks.enumerated() {
            if let asym = (props["AsymmetricModeSupported"] as? NSNumber)?.boolValue, asym == false {
                let read: (String) -> Any? = { props[$0] }
                let model = TRMTransportWatcher.makeCIOCapability(
                    entryID: UInt64(i),
                    read: read,
                    hpmControllerUUID: nil
                )
                #expect(model?.asymmetricModeSupported == false,
                    "m3_macos26.5: parsed CIO model should carry asymmetricModeSupported=false")
                foundFalse = true
                break
            }
        }
        #expect(foundFalse,
            "m3_macos26.5: expected at least one CIO block with AsymmetricModeSupported=false")
    }

    // MARK: (a6) CIO: TRM-restricted CIO block (m3max_macos26.5 port @2)

    @Test("CIO TRM restricted: m3max_macos26.5 port @2 CIO block has transportRestricted=true")
    func cioTRMRestrictedBlock() {
        // m3max_macos26.5 inspection.md: 1 port restricted. Probe 17 shows
        // IOPortTransportStateCIO on port @2 with TRM_TransportRestricted=true
        // and CableSpeed=3 (TB4 class). The CIO model still parses correctly;
        // the restriction is surfaced through the TRM transport, not CIO.
        guard let text = Self.loadProbeText(folder: "m3max_macos26.5", probe: "17_deep_property_dump")
        else {
            Issue.record("Missing probe 17 for m3max_macos26.5")
            return
        }
        let blocks = Self.extractCIOBlocks(text: text)
        var foundRestrictedCIOBlock = false
        for (i, props) in blocks.enumerated() {
            let isRestricted = (props["TRM_TransportRestricted"] as? NSNumber)?.boolValue == true
            guard isRestricted else { continue }

            let read: (String) -> Any? = { props[$0] }
            let model = TRMTransportWatcher.makeCIOCapability(
                entryID: UInt64(i),
                read: read,
                hpmControllerUUID: nil
            )
            #expect(model != nil,
                "m3max_macos26.5: CIO block with TRM_TransportRestricted=true should still parse")
            // The speed is TB4 class regardless of restriction
            #expect(model?.negotiatedLinkSpeed == 3,
                "m3max_macos26.5: restricted CIO block should still read cableSpeed=3 (TB4)")
            foundRestrictedCIOBlock = true
        }
        #expect(foundRestrictedCIOBlock,
            "m3max_macos26.5: expected at least one CIO block with TRM_TransportRestricted=true")
    }

    // MARK: (a7) CIO: cableSpeed range across the corpus

    @Test("CIO cableSpeed: only values 2, 3, 4 appear across fixture machines")
    func cioCableSpeedRangeCheck() {
        var allSpeeds = Set<Int>()
        for machine in Self.cioFixtureMachines {
            guard let text = Self.loadProbeText(folder: machine, probe: "17_deep_property_dump")
            else { continue }
            for props in Self.extractCIOBlocks(text: text) {
                if let speed = (props["CableSpeed"] as? NSNumber)?.intValue {
                    allSpeeds.insert(speed)
                }
            }
        }
        // The mapping doc confirms only 2, 3, 4 are observed across 27 data points.
        let unexpected = allSpeeds.subtracting([2, 3, 4])
        #expect(unexpected.isEmpty,
            "Unexpected cableSpeed values in corpus: \(unexpected). The mapping doc only confirms 2, 3, 4.")
        // All three should appear across our fixture set
        #expect(allSpeeds.contains(2), "Expected cableSpeed=2 (TB3) in fixture set (m4max_macos26.5_f)")
        #expect(allSpeeds.contains(3), "Expected cableSpeed=3 (TB4) in fixture set")
        #expect(allSpeeds.contains(4), "Expected cableSpeed=4 (TB5) in fixture set")
    }

    // MARK: - DataLink Diagnostic Tests

    // MARK: (b1) TRM-restricted ports: DataLink must return .blockedBySecurity

    @Test("DataLink TRM-restricted: restricted USB3 ports yield .blockedBySecurity verdict (DAR-134)")
    func dataLinkTRMRestrictedBlockedBySecurity() {
        // DAR-134 fix: when macOS TRM blocks a port's USB3 transport,
        // DataLinkDiagnostic must now emit .blockedBySecurity instead of .fine.
        // USB3Transport now carries `transportRestricted` (from TRM_TransportRestricted)
        // and DataLinkDiagnostic short-circuits to the new verdict when it is true.
        //
        // Fixtures m1pro_macos26.5_d and m3_macos26.5_d have probe 19 data with
        // TRM_TransportRestricted=true on their restricted USB3 transport. These
        // were the machines that previously produced the false .fine verdict.

        let restrictedMachines: [(folder: String, restrictedPortKeys: Set<String>)] = [
            // m1pro_macos26.5_d: portKey 2/2 restricted (USB2+USB3)
            ("m1pro_macos26.5_d", ["2/2"]),
            // m3_macos26.5_d: portKey 2/2 restricted (USB2+USB3)
            ("m3_macos26.5_d", ["2/2"]),
        ]

        for (folder, restrictedKeys) in restrictedMachines {
            guard let text17 = Self.loadProbeText(folder: folder, probe: "17_deep_property_dump"),
                  let text19 = Self.loadProbeText(folder: folder, probe: "19_pdo_decode_and_usb3_watch")
            else {
                Issue.record("Missing probe 17/19 for \(folder)")
                continue
            }

            // Parse USB3 transports from probe 19 (now includes transportRestricted)
            let usb3Props = Self.parseDashBlocks(text: text19, classPrefix: "IOPortTransportStateUSB3")
            let usb3Transports: [USB3Transport] = usb3Props.enumerated().compactMap { (i, props) in
                let read: (String) -> Any? = { props[$0] }
                return USB3TransportWatcher.makeTransport(entryID: UInt64(2000 + i), read: read, hpmControllerUUID: nil)
            }

            // Parse CIO capabilities from probe 17
            let cioBlocks = Self.extractCIOBlocks(text: text17)
            let cioCapabilities: [CIOCableCapability] = cioBlocks.enumerated().compactMap { (i, props) in
                let read: (String) -> Any? = { props[$0] }
                return TRMTransportWatcher.makeCIOCapability(entryID: UInt64(1000 + i), read: read, hpmControllerUUID: nil)
            }

            // Load ports from probe 01
            let ports = Self.loadPorts(folder: folder)
            let usbCPorts = ports.filter { $0.portTypeDescription == "USB-C" }

            for port in usbCPorts {
                let suffix = String(port.serviceName.split(separator: "@").last ?? "")
                let portKey = "2/\(suffix)"
                guard restrictedKeys.contains(portKey) else { continue }

                let cio = cioCapabilities.first { $0.portKey == portKey }
                let usb3 = usb3Transports.filter { $0.portKey == portKey }

                let hpm = port.hpmInterface
                let diag = DataLinkDiagnostic(
                    port: hpm,
                    identities: [],
                    devices: [],
                    usb3Transports: usb3,
                    cio: cio,
                    thunderboltSwitches: []
                )

                if let diag {
                    // After the DAR-134 fix: restricted ports with a resolvable USB3
                    // signaling rate must produce .blockedBySecurity, not .fine.
                    guard case .blockedBySecurity = diag.bottleneck else {
                        Issue.record("Expected .blockedBySecurity on TRM-restricted port \(portKey) in \(folder), got \(diag.bottleneck)")
                        continue
                    }
                    #expect(diag.isWarning, "blockedBySecurity must be a warning verdict")
                }
                // nil is also acceptable: the diagnostic can abstain when there is
                // no USB3 transport to gate on (e.g. only USB2 restricted, no USB3).
            }
        }
    }

    // MARK: (b2) DataLink: connected USB-C ports with USB3 active produce a verdict

    @Test("DataLink inputs: connected USB3-active ports resolve a verdict from probe 17/19 inputs")
    func dataLinkConnectedUSB3ActivePorts() {
        // For each CIO fixture machine: find USB-C ports that were connected and
        // had USB3 in transportsActive at capture time. Build DataLink inputs from
        // the USB3 transports in probes 17/19. Expect the diagnostic to produce a
        // non-nil verdict (since there is a known active USB3 rate).
        let machines = Self.cioFixtureMachines + Self.trmFixtureMachines

        var examineCount = 0
        var gotVerdictCount = 0

        for machine in machines {
            guard let text17 = Self.loadProbeText(folder: machine, probe: "17_deep_property_dump"),
                  let text19 = Self.loadProbeText(folder: machine, probe: "19_pdo_decode_and_usb3_watch")
            else { continue }

            let usb3Props = Self.parseDashBlocks(text: text19, classPrefix: "IOPortTransportStateUSB3")
            let usb3Transports: [USB3Transport] = usb3Props.enumerated().compactMap { (i, props) in
                USB3TransportWatcher.makeTransport(entryID: UInt64(2000 + i), read: { props[$0] }, hpmControllerUUID: nil)
            }

            let cioBlocks = Self.extractCIOBlocks(text: text17)
            let cioCapabilities: [CIOCableCapability] = cioBlocks.enumerated().compactMap { (i, props) in
                TRMTransportWatcher.makeCIOCapability(entryID: UInt64(1000 + i), read: { props[$0] }, hpmControllerUUID: nil)
            }

            let ports = Self.loadPorts(folder: machine)
            for port in ports where port.portTypeDescription == "USB-C"
                                 && port.connectionActive
                                 && port.transportsActive.contains("USB3") {
                examineCount += 1
                let hpm = port.hpmInterface
                let suffix = String(port.serviceName.split(separator: "@").last ?? "")
                let portKey = "2/\(suffix)"
                let cio = cioCapabilities.first { $0.portKey == portKey }
                let usb3 = usb3Transports.filter { $0.portKey == portKey }

                let diag = DataLinkDiagnostic(
                    port: hpm,
                    identities: [],
                    devices: [],
                    usb3Transports: usb3,
                    cio: cio,
                    thunderboltSwitches: []
                )
                if diag != nil { gotVerdictCount += 1 }
            }
        }

        // We should examine at least a few such ports across the fixture set
        if examineCount > 0 {
            #expect(gotVerdictCount > 0,
                "Expected at least one DataLink verdict from connected USB3-active ports in the fixture set; got 0 out of \(examineCount) examined")
        }
    }

    // MARK: (b3) DataLink: CIO-active ports (CIO in transportsActive) resolve TB rate

    @Test("DataLink inputs: CIO-active ports require tbActiveGbps to produce a verdict")
    func dataLinkCIOActivePortsNeedTBRate() {
        // DataLinkDiagnostic.activeTBGbps() requires:
        //   (1) CIO in transportsActive, AND
        //   (2) a non-empty thunderboltSwitches array
        // Without (2), the diagnostic returns nil even for CIO-active ports.
        // This test confirms that without switch data, the diagnostic abstains.
        // With an explicit tbActiveGbps override it should produce a verdict.
        guard let text = Self.loadProbeText(folder: "m5pro_macos26.5", probe: "17_deep_property_dump")
        else {
            Issue.record("Missing probe 17 for m5pro_macos26.5")
            return
        }

        let cioBlocks = Self.extractCIOBlocks(text: text)
        let cio = cioBlocks.first.flatMap { props -> CIOCableCapability? in
            TRMTransportWatcher.makeCIOCapability(entryID: 1, read: { props[$0] }, hpmControllerUUID: nil)
        }
        #expect(cio != nil, "m5pro_macos26.5 should have a CIO capability model")
        #expect(cio?.negotiatedLinkSpeed == 4, "m5pro_macos26.5 should have cableSpeed=4 (TB5)")

        let ports = Self.loadPorts(folder: "m5pro_macos26.5")
        guard let cioPort = ports.first(where: { $0.transportsActive.contains("CIO") }) else {
            // Not all probe captures have CIO in TransportsActive even when CIO blocks exist
            // (the port may show USB3 as active while CIO is the TB-level transport).
            // This is expected; skip gracefully.
            return
        }
        let hpm = cioPort.hpmInterface

        // Without switch data: should abstain (can't resolve TB rate without switch graph)
        let diagNoSwitches = DataLinkDiagnostic(
            port: hpm,
            identities: [],
            devices: [],
            usb3Transports: [],
            cio: cio,
            thunderboltSwitches: []
        )
        #expect(diagNoSwitches == nil,
            "m5pro_macos26.5 CIO-active port without switch data should produce nil (no active rate)")

        // With explicit tbActiveGbps (test seam): should produce a verdict using CIO speed
        let diagWithRate = DataLinkDiagnostic(
            port: hpm,
            identities: [],
            devices: [],
            usb3Transports: [],
            cio: cio,
            thunderboltSwitches: [],
            tbActiveGbps: 80   // matches cableSpeed=4 -> 80 Gbps
        )
        #expect(diagWithRate != nil,
            "m5pro_macos26.5 CIO-active port with explicit tbActiveGbps should produce a verdict")
        if let diag = diagWithRate {
            #expect(diag.facts.activeGbps == 80,
                "m5pro_macos26.5: activeGbps should be 80 when tbActiveGbps=80")
            // With no cable e-marker or device data the verdict should be .unknownCable
            if case .unknownCable(let active) = diag.bottleneck {
                #expect(active == 80, "m5pro_macos26.5: unknownCable active rate should be 80")
            }
        }
    }

    // MARK: (b4) DataLink: CIO cable speed is used when both CIO and USB3 are available

    @Test("DataLink inputs: CIO cableGbps is preferred over USB3 signaling when TB link is active")
    func dataLinkCIOSpeedPreferredOverUSB3() {
        // m3max_macos26.5 port @1 (block 1): CIO active=true, cableSpeed=3 (40 Gbps, TB4).
        // The USB3 transport for the same port would give 5 or 10 Gbps.
        // With explicit tbActiveGbps=40, the facts should show cableControllerGbps=40.
        guard let text17 = Self.loadProbeText(folder: "m3max_macos26.5", probe: "17_deep_property_dump"),
              let text19 = Self.loadProbeText(folder: "m3max_macos26.5", probe: "19_pdo_decode_and_usb3_watch")
        else {
            Issue.record("Missing probe 17/19 for m3max_macos26.5")
            return
        }

        let cioBlocks = Self.extractCIOBlocks(text: text17)
        // Find the active CIO block (cableSpeed=3, portKey=2/1, active=true)
        var activeCIO: CIOCableCapability? = nil
        for (i, props) in cioBlocks.enumerated() {
            let isActive = (props["Active"] as? NSNumber)?.boolValue == true
            let speed = (props["CableSpeed"] as? NSNumber)?.intValue ?? 0
            guard isActive, speed == 3 else { continue }
            let read: (String) -> Any? = { props[$0] }
            activeCIO = TRMTransportWatcher.makeCIOCapability(entryID: UInt64(i), read: read, hpmControllerUUID: nil)
            break
        }
        #expect(activeCIO != nil, "m3max_macos26.5: should find an active CIO block with cableSpeed=3")
        #expect(activeCIO?.negotiatedLinkSpeed == 3, "m3max_macos26.5: active CIO block speed should be 3")

        // USB3 transports from probe 19
        let usb3Props = Self.parseDashBlocks(text: text19, classPrefix: "IOPortTransportStateUSB3")
        let usb3Transports: [USB3Transport] = usb3Props.enumerated().compactMap { (i, props) in
            USB3TransportWatcher.makeTransport(entryID: UInt64(2000 + i), read: { props[$0] }, hpmControllerUUID: nil)
        }

        // Get the port for portKey 2/1
        let ports = Self.loadPorts(folder: "m3max_macos26.5")
        guard let port = ports.first(where: { $0.serviceName.hasSuffix("@1") && $0.portTypeDescription == "USB-C" })
        else {
            // Accept gracefully -- probe may not expose the port we need
            return
        }
        let hpm = port.hpmInterface
        let usb3ForPort = usb3Transports.filter { $0.portKey == "2/1" }

        // With explicit tbActiveGbps=40, CIO should fill in cableControllerGbps
        let diag = DataLinkDiagnostic(
            port: hpm,
            identities: [],
            devices: [],
            usb3Transports: usb3ForPort,
            cio: activeCIO,
            thunderboltSwitches: [],
            tbActiveGbps: 40
        )
        #expect(diag != nil, "m3max_macos26.5 port @1: should produce a DataLink verdict")
        if let diag {
            #expect(diag.facts.cableControllerGbps == 40,
                "m3max_macos26.5: CIO cableControllerGbps should be 40 (cableSpeed=3 -> 40 Gbps)")
            #expect(diag.facts.activeGbps == 40,
                "m3max_macos26.5: activeGbps should be 40 (tbActiveGbps=40)")
        }
    }

    // MARK: (b5) DataLink: USB3 input from probe 19 produces correct signaling

    @Test("DataLink inputs: USB3 transport from probe 19 correctly resolves Gen1/Gen2 signaling")
    func dataLinkUSB3SignalingFromProbe19() {
        // m3_macos26.5_d probe 19: USB3 block with signaling=2 (10 Gbps, Gen 2).
        // m1pro_macos26.5_d probe 19: USB3 block with signaling=1 (5 Gbps, Gen 1).
        // Verify that USB3TransportWatcher.makeTransport parses signaling correctly
        // and that DataLinkDiagnostic uses the USB3 active rate.

        let cases: [(folder: String, expectedSignaling: Int, expectedGbps: Double)] = [
            ("m3_macos26.5_d", 2, 10),     // USB 3.2 Gen 2 (10 Gbps)
            ("m1pro_macos26.5_d", 1, 5),   // USB 3.2 Gen 1 (5 Gbps)
        ]

        for (folder, expectedSignaling, expectedGbps) in cases {
            guard let text19 = Self.loadProbeText(folder: folder, probe: "19_pdo_decode_and_usb3_watch")
            else {
                Issue.record("Missing probe 19 for \(folder)")
                continue
            }

            let usb3Props = Self.parseDashBlocks(text: text19, classPrefix: "IOPortTransportStateUSB3")
            let transports: [USB3Transport] = usb3Props.enumerated().compactMap { (i, props) in
                USB3TransportWatcher.makeTransport(entryID: UInt64(i), read: { props[$0] }, hpmControllerUUID: nil)
            }

            #expect(!transports.isEmpty,
                "\(folder): expected USB3 transport(s) from probe 19")

            // Find the transport with the expected signaling
            let matched = transports.first { $0.signaling == expectedSignaling }
            #expect(matched != nil,
                "\(folder): expected USB3 transport with signaling=\(expectedSignaling); got \(transports.map { $0.signaling ?? -1 })")

            // Build a minimal port with USB3 active (using portKey matching from the transport)
            if let t = matched {
                let parts = t.portKey.split(separator: "/")
                let portNum = Int(parts.last ?? "2") ?? 2
                let testPort = AppleHPMInterface(
                    id: UInt64(portNum),
                    serviceName: "Port-USB-C@\(portNum)",
                    className: "AppleTCControllerType10",
                    portDescription: "Port-USB-C@\(portNum)",
                    portTypeDescription: "USB-C",
                    portNumber: portNum,
                    connectionActive: true,
                    activeCable: nil,
                    opticalCable: nil,
                    usbActive: nil,
                    superSpeedActive: nil,
                    usbModeType: nil,
                    usbConnectString: nil,
                    transportsSupported: ["USB3", "USB2"],
                    transportsActive: ["USB3", "USB2"],
                    transportsProvisioned: [],
                    plugOrientation: nil,
                    plugEventCount: nil,
                    connectionCount: nil,
                    overcurrentCount: nil,
                    pinConfiguration: [:],
                    powerCurrentLimits: [],
                    firmwareVersion: nil,
                    bootFlagsHex: nil,
                    rawProperties: [:]
                )
                let diag = DataLinkDiagnostic(
                    port: testPort,
                    identities: [],
                    devices: [],
                    usb3Transports: [t],
                    cio: nil,
                    thunderboltSwitches: []
                )
                #expect(diag != nil,
                    "\(folder): DataLink should produce a verdict for a connected USB3-active port with signaling=\(expectedSignaling)")
                if let diag {
                    #expect(diag.facts.activeGbps == expectedGbps,
                        "\(folder): activeGbps should be \(expectedGbps) for signaling=\(expectedSignaling)")
                }
            }
        }
    }

    // MARK: - Fixture machine lists (file-private)

    private static let cioFixtureMachines: [String] = [
        "m4max_macos26.5_c",   // 4 CIO blocks, desktop M4 Max Type7, mixed TB3/TB4/TB5
        "m5pro_macos26.5",     // 1 CIO block, M5 Pro laptop, TB5 (speed=4)
        "m4pro_macos26.5",     // 1 CIO block, M4 Pro laptop Type7, TB5 (speed=4)
        "m3max_macos26.5",     // 2 CIO blocks, M3 Max laptop Type5, 1 restricted
        "m3_macos26.5",        // 1 CIO block, M3 base Type5, asymm=false
        "m3pro_macos26.5_d",   // 1 CIO block, M3 Pro Type5
        "m4_macos26.3",        // 1 CIO block, M4 Type5
        "m4_macos26.5_b",      // 3 CIO blocks, M4 Type5, mixed cableGeneration
        "m4max_macos26.5_f",   // 2 CIO blocks, M4 Max Type7, 1 TB3 (speed=2)
        "m5_macos26.4_b",      // 1 CIO block, M5 Type7, TRM-restricted
        "m5pro_macos26.5.1",   // 2 CIO blocks, M5 Pro Type7
        "m4max_macos15.7.7",   // 1 CIO block, M4 Max macOS 15 (older OS coverage)
    ]

    private static let trmFixtureMachines: [String] = [
        "m1pro_macos26.5_d",   // 2 restricted ports (USB2+USB3), zeroed VID cable
        "m3_macos26.5_d",      // 4 restricted ports (USB2+USB3)
        "m2pro_macos26.4.1",   // 3 restricted ports (USB3 on 2 ports)
    ]

    // MARK: - Assertion helpers (file-private)

    /// Assert that the machine's probe 17 contains exactly one active CIO block
    /// with the expected cableSpeed. Fails if the machine is missing or the
    /// speed doesn't match.
    private func assertCIOActiveSpeed(machine: String, expectedSpeed: Int, reason: String) {
        guard let text = Self.loadProbeText(folder: machine, probe: "17_deep_property_dump")
        else {
            Issue.record("Missing probe 17 for \(machine): \(reason)")
            return
        }
        let blocks = Self.extractCIOBlocks(text: text)
        // Look for an active block with the expected speed
        let activeMatches = blocks.filter { props in
            let isActive = (props["Active"] as? NSNumber)?.boolValue == true
            let speed = (props["CableSpeed"] as? NSNumber)?.intValue
            return isActive && speed == expectedSpeed
        }
        #expect(!activeMatches.isEmpty,
            "Machine \(machine): expected at least one active CIO block with cableSpeed=\(expectedSpeed). Reason: \(reason)")
    }

    /// Assert that the machine's probe 17 contains at least one CIO block
    /// (active or not) with the given cableSpeed.
    private func assertCIOBlockContainsSpeed(machine: String, requiredSpeed: Int, reason: String) {
        guard let text = Self.loadProbeText(folder: machine, probe: "17_deep_property_dump")
        else {
            Issue.record("Missing probe 17 for \(machine): \(reason)")
            return
        }
        let blocks = Self.extractCIOBlocks(text: text)
        let matched = blocks.filter { props in
            (props["CableSpeed"] as? NSNumber)?.intValue == requiredSpeed
        }
        #expect(!matched.isEmpty,
            "Machine \(machine): expected at least one CIO block with cableSpeed=\(requiredSpeed). Reason: \(reason)")
    }
}
