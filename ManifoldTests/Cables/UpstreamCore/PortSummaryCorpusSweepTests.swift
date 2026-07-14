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

/// Corpus-replay sweep for `PortSummary.init` (`Sources/WhatCableCore/Output/PortSummary.swift`),
/// the app's master per-port headline/status derivation. Before this file, nothing
/// in the corpus-replay suite exercised `PortSummary` directly against real
/// hardware data; every existing sweep (CIO, cable trust) feeds a narrower
/// downstream type instead.
///
/// This sweep builds the same inputs `ContentView`/`WidgetSnapshot` pass in
/// production, as far as a `WhatCableCoreTests`-only target can reconstruct
/// them from raw probe text:
///
/// - `port`: from probe 01's PD-tree walk (`AppleHPMInterface`, USB-C ports only).
/// - `identities`: SOP/SOP'/SOP'' entries from probe 01, matched to a port by
///   `parentPortNumber == port.portNumber`.
/// - `sources`: `PowerSource` built from probe 17/19's
///   `IOPortFeaturePowerSource` dash-style blocks, matched the same way.
///   `PowerSourceOptions` itself serialises as an opaque `<CFType 17>` in every
///   probe capture (never a decodable array), so `PowerSource.options` is
///   always empty here; only `winning` (the `WinningPowerSourceOption`
///   sub-dict) is real. `PortSummary`'s "Charger advertises up to NW" bullet
///   depends on `options`, so it never fires in this sweep; the "Currently
///   negotiated" bullet (which depends on `winning`) does.
/// - `cioCapability`: from probe 17/19's `IOPortTransportStateCIO` blocks,
///   filtered to `Active == true`, matched by the `portKey` derived the same
///   way `TRMTransportWatcher.parentPortIdentity` does (see the doc comment on
///   `DataLinkDiagnosticCIOCorpusTests`, which this file's CIO decode mirrors).
///
/// Not reconstructed (documented limitation, not faked): `devices` (USB device
/// to physical-port correlation needs live IOKit `controllerPortName`/`busIndex`
/// data that flat probe text doesn't carry (see `Probe38TreeWalkTests`'s and
/// `InternalHubPIDCorpusTests`'s doc comments for the same limitation on a
/// different type) and `thunderboltSwitches` (building an `IOThunderboltSwitch`
/// tree from probe 29 is a separate, much larger parser this file doesn't
/// attempt). Both default to empty, which only weakens the Thunderbolt-fabric
/// and device-listing bullets, not the core status/headline logic under test.
@Suite("PortSummary: corpus sweep", .disabled(if: !ProbeCorpus.isAvailable, "Customer-probe corpus is absent from the supplied upstream clone."))
struct PortSummaryCorpusSweepTests {

    // MARK: - Probe root / folder enumeration
    // Same resolution as the other WhatCableCoreTests corpus sweeps.

    private static let probeRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .deletingLastPathComponent().appendingPathComponent("research/customer-probes")
    }()

    private static func allFolders() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: probeRoot.path) else { return [] }
        return entries.filter { entry in
            var isDir: ObjCBool = false
            let path = probeRoot.appendingPathComponent(entry).path
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return isDir.boolValue
        }.sorted()
    }

    private static func loadProbeText(folder: String, probe: String) -> String? {
        let url = probeRoot.appendingPathComponent(folder).appendingPathComponent("\(probe).json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = root["output"] as? String
        else { return nil }
        return text
    }

    // MARK: - Probe 01: ports
    // Copied from DataLinkDiagnosticCIOCorpusTests.ProbePort / loadPorts (same
    // target) -- see that file's type-level doc comment for why this is a
    // deliberate copy (Swift `private` is file-scoped) rather than a shared
    // internal helper.

    private struct ProbePort {
        let serviceName: String
        let portTypeDescription: String?
        let portNumber: Int
        let transportsSupported: [String]
        let transportsActive: [String]
        let connectionActive: Bool

        var asAppleHPMInterface: AppleHPMInterface {
            AppleHPMInterface(
                id: UInt64(portNumber),
                serviceName: serviceName,
                className: "AppleHPMInterfaceType10",
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
        guard let text = loadProbeText(folder: folder, probe: "01_walk_pd_tree") else { return [] }

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

            let portType = parseQuoted(body, key: "PortTypeDescription")
            let serviceName = parseQuoted(body, key: "Description") ?? "Port-Unknown@0"
            let portNumber = parseInt(body, key: "PortNumber") ?? 0
            let supp = parseList(body, key: "TransportsSupported")
            let act = parseList(body, key: "TransportsActive")
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

    private static func parseQuoted(_ block: String, key: String) -> String? {
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

    private static func parseInt(_ block: String, key: String) -> Int? {
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

    private static func parseList(_ block: String, key: String) -> [String] {
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

    // MARK: - Probe 01: SOP identities
    // Copied from CableTrustProbeSweepTests.identities (same target) -- the
    // existing corpus parser that decodes real VDO bytes into USBPDSOP.

    private static func identities(folder: String) -> [USBPDSOP] {
        guard let text = loadProbeText(folder: folder, probe: "01_walk_pd_tree") else { return [] }

        var result: [USBPDSOP] = []
        let blocks = text.components(separatedBy: "=== ").dropFirst()
        for block in blocks {
            guard block.contains("CCUSBPDSOP") else { continue }

            let endpoint: USBPDSOP.Endpoint
            if let name = firstMatch(#"Name:\s+(\S+)"#, in: block) {
                switch name {
                case "SOP": endpoint = .sop
                case "SOP'": endpoint = .sopPrime
                case "SOP''": endpoint = .sopDoublePrime
                default: endpoint = .unknown
                }
            } else {
                continue
            }

            let portNumber = firstMatch(#"Description = "Port-USB-C@(\d+)/CC"#, in: block)
                .flatMap { Int($0) } ?? 0

            let vendorID = firstMatch(#"Vendor ID = \d+ \(0x([0-9a-fA-F]+)\)"#, in: block)
                .flatMap { Int($0, radix: 16) } ?? 0

            let vdos = allMatches(#"\[\d+\] <data 4 bytes: ([0-9a-fA-F ]+)>"#, in: block)
                .map { bytes -> UInt32 in
                    let parts = bytes.split(separator: " ").compactMap { UInt32($0, radix: 16) }
                    return parts.reversed().reduce(UInt32(0)) { ($0 << 8) | $1 }
                }

            result.append(USBPDSOP(
                id: UInt64(result.count),
                endpoint: endpoint,
                parentPortType: 0,
                parentPortNumber: portNumber,
                vendorID: vendorID,
                productID: 0,
                bcdDevice: 0,
                vdos: vdos,
                specRevision: 3
            ))
        }
        return result
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard
            let re = try? NSRegularExpression(pattern: pattern),
            let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            m.numberOfRanges > 1,
            let r = Range(m.range(at: 1), in: text)
        else { return nil }
        return String(text[r])
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    // MARK: - Probes 17/19: IOPortFeaturePowerSource -> PowerSource
    //
    // Uses `ProbeCorpus` (Support/ProbeCorpus.swift) directly rather than
    // copying its block/property parsing: that file exists specifically to be
    // shared across corpus sweeps in this target, unlike the probe-01 parsers
    // above (which live in files outside this target too, forcing a copy).

    private static func powerSources(folder: String) -> [PowerSource] {
        var result: [PowerSource] = []
        for probe in ["17_deep_property_dump", "19_pdo_decode_and_usb3_watch"] {
            guard let text = loadProbeText(folder: folder, probe: probe) else { continue }
            let blocks = ProbeCorpus.parseDashBlocks(text: text, classPrefix: "IOPortFeaturePowerSource")
            for (i, props) in blocks.enumerated() {
                guard let name = props["PowerSourceName"] as? String else { continue }
                let parentType = (props["ParentPortType"] as? NSNumber)?.intValue
                    ?? (props["ParentBuiltInPortType"] as? NSNumber)?.intValue ?? 2
                let parentNumber = (props["ParentPortNumber"] as? NSNumber)?.intValue
                    ?? (props["ParentBuiltInPortNumber"] as? NSNumber)?.intValue ?? 0
                // Only the dash-style ("--- ClassName[N] ---") flat-services
                // section is handled: that's where every corpus sample with a
                // WinningPowerSourceOption sub-dict was found. The rarer
                // "=== ClassName ===" HPM deep-dive section is skipped (see
                // the type doc comment); this is a documented gap, not faked
                // data.
                let winning = ProbeCorpus.parseWinningOption(
                    text: text, blockIndex: i, classPrefix: "IOPortFeaturePowerSource")
                let winningOption: PowerOption? = winning.map {
                    PowerOption(
                        voltageMV: $0["Voltage (mV)"] ?? 0,
                        maxCurrentMA: $0["Max Current (mA)"] ?? 0,
                        maxPowerMW: $0["Max Power (mW)"] ?? 0
                    )
                }
                result.append(PowerSource(
                    id: UInt64(2000 + result.count),
                    name: name,
                    parentPortType: parentType,
                    parentPortNumber: parentNumber,
                    options: [],
                    winning: winningOption
                ))
            }
        }
        return result
    }

    // MARK: - Probes 17/19: IOPortTransportStateCIO -> CIOCableCapability
    // CIO block extraction delegates to ProbeCorpus's generic block parsers
    // (className/classPrefix parameterised, so no duplication needed here).
    // The CIOCableCapability mapping itself is copied from
    // DataLinkDiagnosticCIOCorpusTests.cioCapability (same target) -- see
    // that file's doc comment for why (portKey derivation must exactly mirror
    // TRMTransportWatcher.parentPortIdentity, which lives in
    // WhatCableDarwinBackend, a target this one does not depend on).

    private static func cioCapabilities(folder: String) -> [(portNumber: Int, cio: CIOCableCapability)] {
        var result: [(Int, CIOCableCapability)] = []
        for probe in ["17_deep_property_dump", "19_pdo_decode_and_usb3_watch"] {
            guard let text = loadProbeText(folder: folder, probe: probe) else { continue }
            var blocks = ProbeCorpus.parseEqualsBlocks(text: text, className: "IOPortTransportStateCIO")
            blocks += ProbeCorpus.parseDashBlocks(text: text, classPrefix: "IOPortTransportStateCIO")
            for (i, props) in blocks.enumerated() {
                guard (props["Active"] as? NSNumber)?.boolValue == true else { continue }
                let cio = cioCapability(entryID: UInt64(3000 + result.count + i), props: props)
                let parts = cio.portKey.split(separator: "/")
                guard let portNumber = parts.last.flatMap({ Int($0) }) else { continue }
                result.append((portNumber, cio))
            }
        }
        return result
    }

    private static func cioCapability(entryID: UInt64, props: [String: Any]) -> CIOCableCapability {
        let type = (props["ParentBuiltInPortType"] as? NSNumber)?.intValue
            ?? (props["ParentPortType"] as? NSNumber)?.intValue
            ?? 0
        let number = (props["ParentBuiltInPortNumber"] as? NSNumber)?.intValue
            ?? (props["ParentPortNumber"] as? NSNumber)?.intValue
            ?? Int(((props["Priority"] as? NSNumber)?.uint64Value ?? 0) & 0xFF)

        return CIOCableCapability(
            id: entryID,
            portKey: "\(type)/\(number)",
            cableGeneration: (props["CableGeneration"] as? NSNumber)?.intValue,
            negotiatedLinkSpeed: (props["CableSpeed"] as? NSNumber)?.intValue,
            generation: (props["Generation"] as? NSNumber)?.intValue,
            asymmetricModeSupported: (props["AsymmetricModeSupported"] as? NSNumber)?.boolValue,
            legacyAdapter: (props["LegacyAdapter"] as? NSNumber)?.boolValue,
            linkTrainingMode: (props["LinkTrainingMode"] as? NSNumber)?.intValue
        )
    }

    // MARK: - One examined case per (folder, connected USB-C port)

    private struct Case {
        let folder: String
        let port: AppleHPMInterface
        let identities: [USBPDSOP]
        let sources: [PowerSource]
        let cio: CIOCableCapability?
    }

    nonisolated(unsafe) private static let cases: [Case] = computeCases()

    private static func computeCases() -> [Case] {
        var result: [Case] = []
        for folder in allFolders() {
            let ports = loadPorts(folder: folder)
            guard !ports.isEmpty else { continue }
            let ids = identities(folder: folder)
            let sources = powerSources(folder: folder)
            let cios = cioCapabilities(folder: folder)

            for port in ports where port.portTypeDescription == "USB-C" && port.connectionActive {
                let matchedIDs = ids.filter { $0.parentPortNumber == port.portNumber }
                let matchedSources = sources.filter { $0.parentPortNumber == port.portNumber }
                let matchedCIO = cios.first { $0.portNumber == port.portNumber }?.cio
                result.append(Case(
                    folder: folder,
                    port: port.asAppleHPMInterface,
                    identities: matchedIDs,
                    sources: matchedSources,
                    cio: matchedCIO
                ))
            }
        }
        return result
    }

    // MARK: - Coverage floor
    //
    // Measured directly from this Swift parser against the corpus snapshot at
    // the time this sweep was written (410 folders, full raw corpus
    // hard-linked into this worktree): the sweep produces 645 connected
    // USB-C port cases. Floor = 85% of 645, rounded down:
    // 645 * 0.85 = 548.25 -> 548.
    //
    // A worktree without the raw corpus (only 01_walk_pd_tree.json committed)
    // still has probe 01 (it's the one committed distillation), so this floor
    // does NOT skip on a fresh clone the way the CIO-specific sweeps do; it
    // only needs probe 01, which is always present.
    private static let coverageFloor = 548

    // MARK: - Tests

    @Test("Coverage: the corpus has enough connected USB-C port cases to exercise PortSummary")
    func coverageFloorHolds() {
        #expect(Self.cases.count >= Self.coverageFloor,
            "Expected at least \(Self.coverageFloor) connected USB-C port cases (85% of the 645 counted when this sweep was written); found \(Self.cases.count). A drop this large means the corpus shrank or the parsing regressed, not normal noise.")
    }

    @Test("No crash: PortSummary.init handles every real connected-port case in the corpus")
    func noCrashAcrossCorpus() {
        var examined = 0
        for c in Self.cases {
            _ = PortSummary(
                port: c.port,
                sources: c.sources,
                identities: c.identities,
                cioCapability: c.cio
            )
            examined += 1
        }
        // Reaching this line for every case means none of them crashed.
        #expect(examined == Self.cases.count)
    }

    @Test("Invariant: a connected port never reports the 'Nothing connected' status")
    func connectedPortNeverReadsEmpty() {
        var violations: [String] = []
        for c in Self.cases {
            let summary = PortSummary(
                port: c.port,
                sources: c.sources,
                identities: c.identities,
                cioCapability: c.cio
            )
            // Source: PortSummary.init's very first branch --
            // `if !connected { self.status = .empty; ... return }`. `connected`
            // here is `isConnectedOverride ?? (port.connectionActive == true)`;
            // every case in this sweep sets `port.connectionActive == true` and
            // passes no override, so `.empty` must never be reached.
            if summary.status == .empty {
                violations.append("\(c.folder) port \(c.port.serviceName)")
            }
            #expect(!summary.headline.isEmpty,
                "\(c.folder) port \(c.port.serviceName): headline must never be empty for a connected port")
        }
        #expect(violations.isEmpty,
            "\(violations.count) connected corpus port(s) reported .empty status: \(violations.prefix(5))")
    }

    @Test("Invariant: an e-marker response always produces at least one bullet")
    func emarkerResponseProducesBullet() {
        // Source: PortSummary.init, the "B. The cable" section --
        // `let hasEmarker = identities.contains { $0.endpoint == .sopPrime || $0.endpoint == .sopDoublePrime }`
        // followed unconditionally by `if hasEmarker { if emarkerRead { bullets.append(...) } else { bullets.append(...) } }`.
        // Whichever branch fires, at least one bullet is appended, so
        // `hasEmarker == true` must imply `bullets.count >= 1`.
        var examined = 0
        var violations: [String] = []
        for c in Self.cases {
            let hasEmarker = c.identities.contains {
                $0.endpoint == .sopPrime || $0.endpoint == .sopDoublePrime
            }
            guard hasEmarker else { continue }
            examined += 1
            let summary = PortSummary(
                port: c.port,
                sources: c.sources,
                identities: c.identities,
                cioCapability: c.cio
            )
            if summary.bullets.isEmpty {
                violations.append("\(c.folder) port \(c.port.serviceName)")
            }
        }
        if examined == 0 {
            Issue.record("No corpus case had a decodable SOP'/SOP'' e-marker; this invariant is untested by this sweep")
        }
        #expect(violations.isEmpty,
            "\(violations.count) case(s) had an e-marker response but produced no bullets: \(violations.prefix(5))")
    }

    @Test("Invariant: a decoded Cable VDO always produces a 'Cable speed' bullet")
    func decodedCableVDOProducesSpeedBullet() {
        // Source: PortSummary.init -- `if let cable = cableEmarker, let cv = cable.cableVDO { let speedLabel = cv.speed.label; bullets.append("Cable speed: \(speedLabel)") ... }`.
        // `cableEmarker` prefers a populated e-marker (`!$0.vdos.isEmpty`) over
        // an empty one, so whenever a port's e-marker has `vdos.count > 3`
        // (the precondition for `cableVDO` to decode, see USBPDSOP.cableVDO),
        // the resolved cableEmarker must be that populated one, and the
        // speed bullet must appear.
        var examined = 0
        var violations: [String] = []
        for c in Self.cases {
            guard c.identities.contains(where: {
                ($0.endpoint == .sopPrime || $0.endpoint == .sopDoublePrime) && $0.vdos.count > 3
            }) else { continue }
            examined += 1
            let summary = PortSummary(
                port: c.port,
                sources: c.sources,
                identities: c.identities,
                cioCapability: c.cio
            )
            if !summary.bullets.contains(where: { $0.hasPrefix("Cable speed:") }) {
                violations.append("\(c.folder) port \(c.port.serviceName)")
            }
        }
        if examined == 0 {
            Issue.record("No corpus case had a decodable Cable VDO; this invariant is untested by this sweep")
        }
        #expect(violations.isEmpty,
            "\(violations.count) case(s) had a decodable Cable VDO but no 'Cable speed' bullet: \(violations.prefix(5))")
    }
}
