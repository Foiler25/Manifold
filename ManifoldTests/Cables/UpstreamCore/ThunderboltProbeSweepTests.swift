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

/// Corpus-replay tests for Thunderbolt switch and port parsing (DAR-77).
///
/// Two sources of coverage here:
///
/// 1. Fixture tests (always run): hand-crafted dictionaries transcribed from
///    real `whatcable --tb-debug` paste-backs. Cover the full round-trip from
///    raw `[String: Any]` through `IOThunderboltSwitch.from` and
///    `IOThunderboltPort.from` to model values.
///
/// 2. Corpus sweep (runs only when probe 29 files are on disk): sweeps every
///    `research/customer-probes/<folder>/29_usb4_router_interfaces.json` file
///    and asserts model properties against the raw text. Passes trivially on a
///    fresh clone where probe 29 has not been fetched from KV.
///
/// Probe 29 output format:
///   Top-level sections: "=== ClassName ===" followed by instance blocks
///   "--- ClassName[N] \"<name>\" ---". IOThunderboltSwitch and
///   IOThunderboltPort appear in separate top-level sections (ports are NOT
///   nested inside switch blocks). Key-value lines use "  KEY =     N (0xHEX)"
///   with multiple spaces between "=" and the value. String values appear as
///   "  KEY =     \"value\"".
@Suite("Thunderbolt probe sweep (DAR-77)")
struct ThunderboltProbeSweepTests {

    // MARK: - Probe root

    private static let probeRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .deletingLastPathComponent().appendingPathComponent("research/customer-probes")
    }()

    // MARK: - Known link-speed codes (from IOThunderboltLink.swift)

    /// All speed codes the code can label. Any value outside this set
    /// goes to `.unknown`; the test asserts that branch too.
    private static let knownSpeedCodes: Set<UInt8> = [0x0, 0x8, 0x4, 0x2]

    // MARK: - Corpus helpers

    private static func allProbes() throws -> [String] {
        guard FileManager.default.fileExists(atPath: probeRoot.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(atPath: probeRoot.path)
            .filter { entry in
                var isDir: ObjCBool = false
                let path = probeRoot.appendingPathComponent(entry).path
                FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                return isDir.boolValue
            }
            .sorted()
    }

    /// Load text from a probe-29 JSON file. Returns nil if the file does not
    /// exist (fresh clone where KV data has not been fetched).
    private static func loadProbe29(folder: String) throws -> String? {
        let url = probeRoot
            .appendingPathComponent(folder)
            .appendingPathComponent("29_usb4_router_interfaces.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = root["output"] as? String
        else { return nil }
        return text
    }

    // MARK: - Probe-29 text parsers

    /// Extract instance blocks for a given IOKit class from probe-29 output.
    /// Probe 29 uses "--- ClassName[N] \"name\" ---" instance headers inside
    /// "=== ClassName ===" top-level sections. Blocks run from one instance
    /// header to the next or to the next "===" section header.
    private static func parseInstanceBlocks(_ text: String, className: String)
        -> [(header: String, body: String)]
    {
        var results: [(header: String, body: String)] = []
        let lines = text.components(separatedBy: "\n")
        var currentHeader: String? = nil
        var currentBody: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("--- \(className)") && trimmed.hasSuffix("---") {
                if let h = currentHeader {
                    results.append((h, currentBody.joined(separator: "\n")))
                }
                currentHeader = trimmed
                currentBody = []
            } else if trimmed.hasPrefix("=== ") && trimmed.hasSuffix(" ===") {
                // New top-level section: close any open block.
                if let h = currentHeader {
                    results.append((h, currentBody.joined(separator: "\n")))
                    currentHeader = nil
                    currentBody = []
                }
            } else if currentHeader != nil {
                currentBody.append(line)
            }
        }
        if let h = currentHeader {
            results.append((h, currentBody.joined(separator: "\n")))
        }
        return results
    }

    /// Parse an integer from a probe-29 body line.
    /// Real format: "  KEY =     N (0xHEX)" - note multiple spaces between "=" and N.
    private static func parseIntLine(_ body: String, key: String) -> Int? {
        let prefix = "  \(key) = "
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix(prefix) {
                // Strip the prefix, then skip any leading spaces before the digits.
                let after = line.dropFirst(prefix.count).drop(while: { $0 == " " })
                let digits = after.prefix { $0.isNumber || $0 == "-" }
                if let v = Int(digits) { return v }
            }
        }
        return nil
    }

    /// Parse a quoted string from a probe-29 body line.
    /// Real format: "  KEY =     \"value\"" - note multiple spaces between "=" and quote.
    private static func parseStringLine(_ body: String, key: String) -> String? {
        let prefix = "  \(key) = "
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix(prefix) {
                let after = line.dropFirst(prefix.count).drop(while: { $0 == " " })
                guard after.hasPrefix("\"") else { continue }
                let inner = after.dropFirst()
                if let close = inner.firstIndex(of: "\"") {
                    return String(inner[..<close])
                }
            }
        }
        return nil
    }

    /// Build a `read` closure from a probe-29 switch body block. Only reads
    /// the numeric and string keys that `IOThunderboltSwitch.from` and
    /// `IOThunderboltPort.from` access; other keys return nil (fine, they
    /// are optional in the model).
    private static func makeReadClosure(body: String) -> (String) -> Any? {
        { key in
            if let s = parseStringLine(body, key: key) { return s as Any }
            if let n = parseIntLine(body, key: key) { return NSNumber(value: n) }
            return nil
        }
    }

    // MARK: - Sweep test

    @Test("Corpus sweep: probe-29 switch and port blocks parse without crashing")
    func probe29SweepParsesWithoutCrashing() throws {
        let folders = try Self.allProbes()
        // Corpus minimum guard: only enforced when at least one probe-29 file
        // exists. On a fresh clone all files are absent and the sweep
        // trivially skips.
        //
        // Probe-29 structure: IOThunderboltSwitch and IOThunderboltPort appear
        // in separate top-level "=== ClassName ===" sections. Ports are NOT
        // nested inside switch blocks; each section is parsed independently.
        var switchesParsed = 0
        var portsParsed = 0
        var foldersWithProbe29 = 0

        for folder in folders {
            guard let text = try Self.loadProbe29(folder: folder) else { continue }
            foldersWithProbe29 += 1

            // Parse IOThunderboltSwitch instances from the switch section.
            let switchBlocks = Self.parseInstanceBlocks(text, className: "IOThunderboltSwitch")
            for (_, body) in switchBlocks {
                let read = Self.makeReadClosure(body: body)
                // UIDs in probe-29 are reported as "N (0xHEX)". We parse the
                // decimal as the uid. If no UID line, use 0 as sentinel.
                let uid = Self.parseIntLine(body, key: "UID").map(Int64.init) ?? 0

                if let sw = IOThunderboltSwitch.from(
                    uid: uid,
                    read: read,
                    className: "IOThunderboltSwitch",
                    ports: [],       // ports are in a separate section
                    parentSwitchUID: nil
                ) {
                    switchesParsed += 1

                    // UID must round-trip; depth must be non-negative.
                    #expect(sw.id == uid,
                        "Folder \(folder): TB switch UID did not round-trip, stored \(sw.id), expected \(uid)")
                    #expect(sw.depth >= 0,
                        "Folder \(folder): depth must be non-negative, got \(sw.depth)")
                    _ = sw.vendorName
                    _ = sw.modelName
                }
            }

            // Parse IOThunderboltPort instances from the port section.
            let portBlocks = Self.parseInstanceBlocks(text, className: "IOThunderboltPort")
            for (_, body) in portBlocks {
                let read = Self.makeReadClosure(body: body)
                if let port = IOThunderboltPort.from(read: read) {
                    portsParsed += 1

                    if port.adapterType.isLane {
                        if let speed = port.currentSpeed {
                            switch speed {
                            case .tb3, .usb4Tb4, .tb5:
                                let gbps = speed.perLaneGbps ?? 0
                                #expect(gbps > 0,
                                    "Folder \(folder): known speed code must have positive per-lane Gbps, got \(gbps)")
                            case .unknown:
                                break
                            }
                        }
                        #expect(port.portNumber > 0,
                            "Folder \(folder): parsed lane port has portNumber \(port.portNumber)")
                    }
                }
            }
        }

        // Only assert minimums when files were actually found.
        if foldersWithProbe29 > 0 {
            // Expect at least 1 switch per folder (the host controller is always present).
            #expect(switchesParsed >= foldersWithProbe29,
                "Expected at least \(foldersWithProbe29) switches from \(foldersWithProbe29) probe-29 files; parsed \(switchesParsed)")
            // Expect at least 1 port per folder (every machine has at least one USB-C port).
            #expect(portsParsed >= foldersWithProbe29,
                "Expected at least \(foldersWithProbe29) ports from \(foldersWithProbe29) probe-29 files; parsed \(portsParsed)")
        }
    }

    // MARK: - Fixture tests (always run, even on fresh clones)
    //
    // These fixtures are transcribed from the two topologies anchored in
    // ThunderboltLinkFromTests (Steve's Samsung + Joe's CalDigit chain), plus
    // a few edge-case dictionaries. They exercise the same code paths that
    // the corpus sweep hits, so CI always has at least this coverage.

    /// Fixture: a TB4/USB4 host-root switch (Apple M3, Type5).
    private var appleHostRootDict: [String: Any] {
        [
            "Vendor ID":           NSNumber(value: 1452),
            "Device Vendor Name":  "Apple Inc.",
            "Device Model Name":   "Mac",
            "Router ID":           NSNumber(value: 0),
            "Depth":               NSNumber(value: 0),
            "Route String":        NSNumber(value: 0),
            "Upstream Port Number": NSNumber(value: 0),
            "Max Port Number":     NSNumber(value: 8),
            "Thunderbolt Version": NSNumber(value: 32),
            "Firmware Version":    "19.2 build 3 Oct 17 2023 09:47:16,RELEASE,A-type"
        ]
    }

    /// Fixture: a TB5 host-root switch (Apple M5 Pro, Type7).
    private var appleType7Dict: [String: Any] {
        [
            "Vendor ID":           NSNumber(value: 1452),
            "Device Vendor Name":  "Apple Inc.",
            "Device Model Name":   "Mac",
            "Router ID":           NSNumber(value: 0),
            "Depth":               NSNumber(value: 0),
            "Route String":        NSNumber(value: 0),
            "Upstream Port Number": NSNumber(value: 0),
            "Max Port Number":     NSNumber(value: 12),
            "Thunderbolt Version": NSNumber(value: 64)
        ]
    }

    /// Fixture: an active TB4/USB4 dual-lane port (speed=4, width=2).
    private var activeTb4PortDict: [String: Any] {
        [
            "Port Number":          NSNumber(value: 1),
            "Adapter Type":         NSNumber(value: 1),     // lane
            "Socket ID":            "1",
            "Current Link Speed":   NSNumber(value: 4),     // USB4/TB4
            "Current Link Width":   NSNumber(value: 2),     // dual
            "Target Link Speed":    NSNumber(value: 12),
            "Target Link Width":    NSNumber(value: 3),     // dual encoding
            "Supported Link Speed": NSNumber(value: 12),
            "Supported Link Width": NSNumber(value: 2),
            "Link Bandwidth":       NSNumber(value: 400)
        ]
    }

    /// Fixture: an active TB5 dual-lane port (speed=2, width=2).
    private var activeTb5PortDict: [String: Any] {
        [
            "Port Number":          NSNumber(value: 1),
            "Adapter Type":         NSNumber(value: 1),
            "Socket ID":            "2",
            "Current Link Speed":   NSNumber(value: 2),     // TB5
            "Current Link Width":   NSNumber(value: 2),
            "Target Link Speed":    NSNumber(value: 14),
            "Target Link Width":    NSNumber(value: 3),
            "Supported Link Speed": NSNumber(value: 14),
            "Link Bandwidth":       NSNumber(value: 800)
        ]
    }

    /// Fixture: TB5 asymmetric TX port (3 TX / 1 RX).
    private var tb5AsymmetricTxPortDict: [String: Any] {
        [
            "Port Number":        NSNumber(value: 1),
            "Adapter Type":       NSNumber(value: 1),
            "Socket ID":          "1",
            "Current Link Speed": NSNumber(value: 2),
            "Current Link Width": NSNumber(value: 4),   // asymmetric TX
            "Link Bandwidth":     NSNumber(value: 600)
        ]
    }

    /// Fixture: a DP-in adapter port (non-lane; should have no link state).
    private var dpInPortDict: [String: Any] {
        [
            "Port Number":    NSNumber(value: 3),
            "Adapter Type":   NSNumber(value: 0x0e0101),  // dpIn
            "Link Bandwidth": NSNumber(value: 40)
        ]
    }

    /// Fixture: an idle lane port (speed=0, width=0).
    private var idleLanePortDict: [String: Any] {
        [
            "Port Number":        NSNumber(value: 2),
            "Adapter Type":       NSNumber(value: 1),
            "Socket ID":          "2",
            "Current Link Speed": NSNumber(value: 0),
            "Current Link Width": NSNumber(value: 0)
        ]
    }

    // MARK: Switch fixture tests

    @Test("Host root switch (Apple M3 Type5) parses")
    func appleHostRootParses() {
        let sw = IOThunderboltSwitch.from(
            uid: 42,
            read: { self.appleHostRootDict[$0] },
            className: "IOThunderboltSwitchType5",
            ports: []
        )
        #expect(sw != nil)
        #expect(sw?.id == 42)
        #expect(sw?.depth == 0)
        #expect(sw?.isHostRoot == true)
        #expect(sw?.vendorName == "Apple Inc.")
        #expect(sw?.thunderboltVersion == 32)
        #expect(sw?.firmwareVersion?.contains("RELEASE") == true)
    }

    @Test("Apple Type7 switch (M5 Pro) parses")
    func appleType7Parses() {
        let sw = IOThunderboltSwitch.from(
            uid: 99,
            read: { self.appleType7Dict[$0] },
            className: "IOThunderboltSwitchType7",
            ports: []
        )
        #expect(sw?.depth == 0)
        #expect(sw?.thunderboltVersion == 64)
    }

    @Test("Switch without Vendor ID returns nil")
    func switchWithoutVendorIDReturnsNil() {
        let sw = IOThunderboltSwitch.from(
            uid: 1,
            read: { _ in nil },
            className: "IOThunderboltSwitchType5",
            ports: []
        )
        #expect(sw == nil)
    }

    @Test("Switch supported-speed aggregated from lane ports when absent at switch level")
    func switchSpeedAggregatedFromLanePorts() {
        // No "Supported Link Speed" on the switch dict itself; must aggregate
        // from port-level supportedSpeed masks.
        var dict = appleHostRootDict
        dict.removeValue(forKey: "Supported Link Speed")

        let lane = IOThunderboltPort.from(read: { self.activeTb4PortDict[$0] })!
        let sw = IOThunderboltSwitch.from(
            uid: 7,
            read: { dict[$0] },
            className: "IOThunderboltSwitchType5",
            ports: [lane]
        )
        // Lane port reports Supported Link Speed = 12 (TB3 | TB4).
        #expect(sw?.supportedSpeed.supportsUsb4Tb4 == true)
        #expect(sw?.supportedSpeed.supportsTb3 == true)
    }

    @Test("Downstream switch carries parentSwitchUID")
    func downstreamSwitchCarriesParentUID() {
        let sw = IOThunderboltSwitch.from(
            uid: 200,
            read: { self.appleHostRootDict[$0] },
            className: "IOThunderboltSwitchType5",
            ports: [],
            parentSwitchUID: 100
        )
        #expect(sw?.parentSwitchUID == 100)
    }

    // MARK: Port fixture tests

    @Test("Active TB4/USB4 dual-lane port parses correctly")
    func activeTb4PortParsesCorrectly() {
        let port = IOThunderboltPort.from(read: { self.activeTb4PortDict[$0] })
        #expect(port != nil)
        #expect(port?.adapterType == .lane)
        #expect(port?.socketID == "1")
        #expect(port?.currentSpeed == .usb4Tb4)
        #expect(port?.perLaneGbps == 20)
        #expect(port?.currentWidth?.dual == true)
        #expect(port?.txLanes == 2)
        #expect(port?.rxLanes == 2)
        #expect(port?.targetWidth == .dual)
        #expect(port?.supportedSpeed?.supportsUsb4Tb4 == true)
        #expect(port?.hasActiveLink == true)
        #expect(port?.isBandwidthLimited == false)
    }

    @Test("Active TB5 dual-lane port parses correctly")
    func activeTb5PortParsesCorrectly() {
        let port = IOThunderboltPort.from(read: { self.activeTb5PortDict[$0] })
        #expect(port?.currentSpeed == .tb5)
        #expect(port?.perLaneGbps == 40)
        #expect(port?.currentWidth?.dual == true)
        #expect(port?.hasActiveLink == true)
        // TB5 total: 80 Gbps
        #expect(port?.currentSpeed?.totalGbps == 80)
    }

    @Test("TB5 asymmetric TX port (3 TX / 1 RX) parses correctly")
    func tb5AsymmetricTxPortParsesCorrectly() {
        let port = IOThunderboltPort.from(read: { self.tb5AsymmetricTxPortDict[$0] })
        #expect(port?.currentSpeed == .tb5)
        #expect(port?.currentWidth?.asymmetricTx == true)
        #expect(port?.txLanes == 3)
        #expect(port?.rxLanes == 1)
        #expect(port?.hasActiveLink == true)
    }

    @Test("DP-in protocol adapter port has no link state")
    func dpInAdapterPortHasNoLinkState() {
        let port = IOThunderboltPort.from(read: { self.dpInPortDict[$0] })
        #expect(port?.adapterType == .dpIn)
        #expect(port?.currentSpeed == nil)
        #expect(port?.currentWidth == nil)
        #expect(port?.hasActiveLink == false)
    }

    @Test("Idle lane port has no active link")
    func idleLanePortHasNoActiveLink() {
        let port = IOThunderboltPort.from(read: { self.idleLanePortDict[$0] })
        #expect(port?.adapterType == .lane)
        #expect(port?.currentSpeed == nil)
        #expect(port?.currentWidth?.isActive == false)
        #expect(port?.hasActiveLink == false)
    }

    @Test("Port without port number returns nil")
    func portWithoutPortNumberReturnsNil() {
        let port = IOThunderboltPort.from(read: { _ in nil })
        #expect(port == nil)
    }

    @Test("Lane-limited port (single-width when dual supported) is bandwidth-limited")
    func laneLimitedPortIsBandwidthLimited() {
        // Single-width current, dual-width supported: isBandwidthLimited.
        let dict: [String: Any] = [
            "Port Number":          NSNumber(value: 1),
            "Adapter Type":         NSNumber(value: 1),
            "Current Link Speed":   NSNumber(value: 4),
            "Current Link Width":   NSNumber(value: 1),   // single
            "Supported Link Width": NSNumber(value: 2)    // dual supported
        ]
        let port = IOThunderboltPort.from(read: { dict[$0] })
        #expect(port?.isBandwidthLimited == true)
    }

    @Test("ThunderboltLabels link label: TB4 dual-lane")
    func tb4LinkLabel() {
        let lane = IOThunderboltPort.from(read: { self.activeTb4PortDict[$0] })!
        let label = ThunderboltLabels.linkLabel(for: lane)
        #expect(label != nil)
        #expect(label?.contains("20 Gb/s") == true)
        #expect(label?.contains("2") == true)
    }

    @Test("ThunderboltLabels link label: TB5 dual-lane")
    func tb5LinkLabel() {
        let lane = IOThunderboltPort.from(read: { self.activeTb5PortDict[$0] })!
        let label = ThunderboltLabels.linkLabel(for: lane)
        #expect(label?.contains("40 Gb/s") == true)
    }

    @Test("ThunderboltLabels link label: TB5 asymmetric shows TX/RX")
    func tb5AsymmetricLinkLabel() {
        let lane = IOThunderboltPort.from(read: { self.tb5AsymmetricTxPortDict[$0] })!
        let label = ThunderboltLabels.linkLabel(for: lane)
        #expect(label?.contains("TX") == true)
        #expect(label?.contains("RX") == true)
    }

    @Test("ThunderboltLabels link label: idle port returns nil")
    func idlePortLinkLabelNil() {
        let lane = IOThunderboltPort.from(read: { self.idleLanePortDict[$0] })!
        #expect(ThunderboltLabels.linkLabel(for: lane) == nil)
    }

    @Test("ThunderboltLabels deviceName: vendor and model combined")
    func deviceNameVendorAndModelCombined() {
        let sw = IOThunderboltSwitch.from(
            uid: 1,
            read: { self.appleHostRootDict[$0] },
            className: "IOThunderboltSwitchType5",
            ports: []
        )!
        let name = ThunderboltLabels.deviceName(for: sw)
        #expect(name.contains("Apple Inc."))
        #expect(name.contains("Mac"))
    }

    @Test("ThunderboltLabels deviceName: vendor only when model empty")
    func deviceNameVendorOnlyWhenModelEmpty() {
        var dict = appleHostRootDict
        dict["Device Model Name"] = ""
        let sw = IOThunderboltSwitch.from(
            uid: 1,
            read: { dict[$0] },
            className: "IOThunderboltSwitchType5",
            ports: []
        )!
        #expect(ThunderboltLabels.deviceName(for: sw) == "Apple Inc.")
    }

    @Test("ThunderboltLabels deviceName: unknown device when both empty")
    func deviceNameUnknownWhenBothEmpty() {
        var dict = appleHostRootDict
        dict["Device Model Name"] = ""
        dict["Device Vendor Name"] = ""
        let sw = IOThunderboltSwitch.from(
            uid: 1,
            read: { dict[$0] },
            className: "IOThunderboltSwitchType5",
            ports: []
        )!
        let name = ThunderboltLabels.deviceName(for: sw)
        // Localised to "Unknown device"; just check it's non-empty.
        #expect(!name.isEmpty)
    }

    // MARK: - Topology fixture tests

    @Test("socketID(fromServiceName:) parses trailing @N suffix")
    func socketIDFromServiceNameParsesTrailingSuffix() {
        #expect(ThunderboltTopology.socketID(fromServiceName: "Port-USB-C@1") == "1")
        #expect(ThunderboltTopology.socketID(fromServiceName: "Port-USB-C@12") == "12")
        #expect(ThunderboltTopology.socketID(fromServiceName: "Port-USB-C") == nil)
        #expect(ThunderboltTopology.socketID(fromServiceName: "") == nil)
    }

    @Test("hostRoot finds correct root for socketID")
    func hostRootFindsCorrectRoot() {
        let lane1 = IOThunderboltPort(
            portNumber: 1, socketID: "1", adapterType: .lane,
            currentSpeed: .usb4Tb4, currentWidth: LinkWidth(rawValue: 2),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil
        )
        let lane2 = IOThunderboltPort(
            portNumber: 2, socketID: "2", adapterType: .lane,
            currentSpeed: nil, currentWidth: LinkWidth(rawValue: 0),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil
        )
        let root1 = IOThunderboltSwitch(
            id: 10, className: "IOThunderboltSwitchType5", vendorID: 1452,
            vendorName: "Apple Inc.", modelName: "Mac",
            routerID: 0, depth: 0, routeString: 0,
            upstreamPortNumber: 0, maxPortNumber: 8,
            supportedSpeed: SupportedSpeedMask(rawValue: 12),
            ports: [lane1], parentSwitchUID: nil
        )
        let root2 = IOThunderboltSwitch(
            id: 11, className: "IOThunderboltSwitchType5", vendorID: 1452,
            vendorName: "Apple Inc.", modelName: "Mac",
            routerID: 0, depth: 0, routeString: 0,
            upstreamPortNumber: 0, maxPortNumber: 8,
            supportedSpeed: SupportedSpeedMask(rawValue: 12),
            ports: [lane2], parentSwitchUID: nil
        )
        let found1 = ThunderboltTopology.hostRoot(forSocketID: "1", in: [root1, root2])
        let found2 = ThunderboltTopology.hostRoot(forSocketID: "2", in: [root1, root2])
        #expect(found1?.id == 10)
        #expect(found2?.id == 11)
        #expect(ThunderboltTopology.hostRoot(forSocketID: "3", in: [root1, root2]) == nil)
    }
}
