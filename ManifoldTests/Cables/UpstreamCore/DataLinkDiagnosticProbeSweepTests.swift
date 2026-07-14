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

/// Property-style sweep over every customer probe under
/// `research/customer-probes/`. Validates the issue #195 fix against the
/// real-world IORegistry shapes we already have on file rather than
/// against a single hand-built fixture. Catches the within-controller
/// socket-ID collision class that the #159 verification pass missed.
@Suite("Data Link Diagnostic — customer probe sweep", .disabled(if: !ProbeCorpus.isAvailable, "Customer-probe corpus is absent from the supplied upstream clone."))
struct DataLinkDiagnosticProbeSweepTests {

    // MARK: - Probe loader

    /// Repo root, located via `#filePath` the same way LocalisationTests
    /// does. Tests read from the source tree so a new probe just needs
    /// to be dropped under `research/customer-probes/` to be picked up.
    private static let probeRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .deletingLastPathComponent().appendingPathComponent("research/customer-probes")
    }()

    /// One IOAccessoryManager entry extracted from a probe's PD-tree walk.
    /// Only the fields the diagnostic actually reads are populated; the
    /// rest stay nil/empty.
    private struct ProbePort {
        let probe: String
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

    /// Parse a single probe directory's 01_walk_pd_tree.json output.
    /// Returns every IOAccessoryManager block as a ProbePort. Robust to
    /// both `AppleTCControllerType*` (M1/M2) and `AppleHPMInterfaceType*`
    /// (M3+) naming.
    private static func loadPorts(probe: String) throws -> [ProbePort] {
        let url = probeRoot
            .appendingPathComponent(probe)
            .appendingPathComponent("01_walk_pd_tree.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = root["output"] as? String
        else { return [] }

        // Split the text on the IOAccessoryManager block header. Each
        // resulting chunk runs until the next `=== ` section header.
        // The block index varies (`[0]`, `[1]`, ...); split on the prefix
        // and trim the index/closing-bracket off the leading line of
        // each chunk.
        let rawChunks = text.components(separatedBy: "=== IOAccessoryManager[")
        guard rawChunks.count > 1 else { return [] }
        // Drop the prefix-only first chunk; for each remaining chunk,
        // strip everything up to the closing "===\n" of its own header.
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
            let serviceName = parseQuoted(body, key: "Description")
                ?? "Port-Unknown@0"
            let portNumber = parseInt(body, key: "PortNumber") ?? 0
            let supp = parseList(body, key: "TransportsSupported")
            let act = parseList(body, key: "TransportsActive")
            let conn = body.contains("ConnectionActive = true")

            ports.append(ProbePort(
                probe: probe,
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

    /// Returns [] when the corpus root itself is absent (e.g. a worktree that
    /// hasn't hard-linked the corpus in), the same guard shape
    /// TransportWatcherSweepTests.allProbeFolders() uses. Note this does NOT
    /// make this file's tests skip gracefully like that sibling's do: the
    /// three callers below still assert hard count floors (`probes.count >
    /// 20`, `rows >= 100`, etc.) that fail when the corpus is absent. The
    /// guard's only effect is turning what would otherwise be an uncaught
    /// thrown NSError (from `contentsOfDirectory` on a missing path) into a
    /// clean, readable failed #expect instead -- arguably clearer, but still
    /// a failure, not a skip.
    private static func allProbes() -> [String] {
        guard FileManager.default.fileExists(atPath: probeRoot.path) else { return [] }
        guard let entries = try? FileManager.default
            .contentsOfDirectory(atPath: probeRoot.path) else { return [] }
        return entries.filter { entry in
            var isDir: ObjCBool = false
            let path = probeRoot.appendingPathComponent(entry).path
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return isDir.boolValue
        }.sorted()
    }

    // MARK: - Field parsers (mirror the offline catalogue extractor)

    /// Line-based field parsers. The probe text uses a fixed
    /// `    KEY = VALUE` indentation; we walk lines looking for an exact
    /// `    \(key) = ` prefix. This avoids cross-field bleed where a
    /// non-anchored regex would pick up `PortDescription` for `Description`
    /// or `ParentBuiltInPortTypeDescription` for `PortTypeDescription`.
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

    // MARK: - Switch fixture

    /// A minimal host TB switch with one active lane port at the given
    /// socket suffix and the given supportedSpeed mask. Mirrors what the
    /// catch-22 case in #195 actually looked like on the real M2 MBA:
    /// MagSafe @1 colliding with USB-C @1, both finding a 40 Gbps lane
    /// on the same host root.
    private static func makeHostSwitch(socketID: String, supportedRaw: UInt8) -> IOThunderboltSwitch {
        let lane = IOThunderboltPort(
            portNumber: 1,
            socketID: socketID,
            adapterType: .lane,
            currentSpeed: .usb4Tb4,
            currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil,
            rawTargetSpeed: nil,
            linkBandwidthRaw: nil
        )
        return IOThunderboltSwitch(
            id: 100,
            className: "IOThunderboltSwitchType5",
            vendorID: 1452,
            vendorName: "Apple Inc.",
            modelName: "Mac",
            routerID: 0,
            depth: 0,
            routeString: 0,
            upstreamPortNumber: 0,
            maxPortNumber: 8,
            supportedSpeed: SupportedSpeedMask(rawValue: supportedRaw),
            ports: [lane],
            parentSwitchUID: nil
        )
    }

    // MARK: - Tests

    @Test("Every customer-probe MagSafe row returns nil (issue #195)")
    func everyMagSafeReturnsNil() throws {
        let probes = Self.allProbes()
        #expect(probes.count > 20, "Expected many customer probes; found \(probes.count)")

        var magSafeRowsExamined = 0
        var collisions = 0
        for probe in probes {
            let ports = try Self.loadPorts(probe: probe)
            let magSafePorts = ports.filter { $0.portTypeDescription == "MagSafe 3" }
            if magSafePorts.isEmpty { continue }

            for ms in magSafePorts {
                magSafeRowsExamined += 1

                // Suffix collision: every customer-probe MagSafe in the
                // dataset shares its @N with the first USB-C port.
                let suffix = String(ms.serviceName.split(separator: "@").last ?? "")
                let sharedSuffix = ports.contains { p in
                    p.portTypeDescription == "USB-C"
                        && p.serviceName.hasSuffix("@" + suffix)
                }
                if sharedSuffix { collisions += 1 }

                // Build the exact adversarial setup the old diagnostic
                // would have leaked through: a host TB switch for the
                // colliding socket suffix, with a 40 Gbps lane.
                let host = Self.makeHostSwitch(socketID: suffix, supportedRaw: 0xC)
                let diag = DataLinkDiagnostic(
                    port: ms.asAppleHPMInterface,
                    identities: [],
                    devices: [],
                    usb3Transports: [],
                    cio: nil,
                    thunderboltSwitches: [host]
                )
                #expect(diag == nil,
                    "Probe \(probe): MagSafe port \(ms.serviceName) should not produce a data-link verdict (carriesData gate)")
            }
        }

        #expect(magSafeRowsExamined >= 50,
            "Expected at least 50 MagSafe rows in the customer-probe set; found \(magSafeRowsExamined)")
        #expect(collisions == magSafeRowsExamined,
            "Every MagSafe row in the dataset shares an @N suffix with a USB-C port (\(magSafeRowsExamined) total); only \(collisions) collisions were observed, which would indicate the catalogue or the dataset has changed shape")
    }

    @Test("Every USB-C row in the probe set has carriesData true")
    func everyUSBCCarriesData() throws {
        // Symmetry check for the carriesData gate: every real USB-C port
        // in the dataset advertises at least one data transport in
        // TransportsSupported. If this ever fires, the gate would
        // over-refuse legitimate ports.
        let probes = Self.allProbes()
        var rows = 0
        for probe in probes {
            let ports = try Self.loadPorts(probe: probe)
            for p in ports where p.portTypeDescription == "USB-C" {
                rows += 1
                #expect(p.asAppleHPMInterface.carriesData,
                    "Probe \(probe): USB-C port \(p.serviceName) reports TransportsSupported=\(p.transportsSupported), which the carriesData gate would refuse")
            }
        }
        #expect(rows >= 100, "Expected at least 100 USB-C rows in the customer-probe set; found \(rows)")
    }

    @Test("Connected USB-C ports without USB3 or CIO transport do not produce a TB verdict")
    func usbOnlyPortsAbstainFromTBVerdict() throws {
        // Real-world coverage for the bigskookum-shape: a USB-C port
        // that's connected, has data capability, but isn't running USB3
        // or TB right now. The new activeTBGbps gate (requires
        // transportsActive.contains("CIO")) keeps the always-up internal
        // root lane from being attributed to the user's cable. Without
        // an honest active rate, the diagnostic should abstain.
        let probes = Self.allProbes()
        var examined = 0
        for probe in probes {
            let ports = try Self.loadPorts(probe: probe)
            for p in ports where p.portTypeDescription == "USB-C"
                              && p.connectionActive
                              && !p.transportsActive.contains("USB3")
                              && !p.transportsActive.contains("CIO") {
                examined += 1

                let suffix = String(p.serviceName.split(separator: "@").last ?? "")
                let host = Self.makeHostSwitch(socketID: suffix, supportedRaw: 0xC)
                let diag = DataLinkDiagnostic(
                    port: p.asAppleHPMInterface,
                    identities: [],
                    devices: [],
                    usb3Transports: [],
                    cio: nil,
                    thunderboltSwitches: [host]
                )
                #expect(diag == nil,
                    "Probe \(probe): USB-C port \(p.serviceName) is connected with TransportsActive=\(p.transportsActive) but no USB3/CIO; the diagnostic should not pick up a TB lane rate from the internal root lane")
            }
        }
        // Most probe captures will have at least one such port; if none
        // are present, the new gate is untested by this sweep but other
        // tests still cover it.
        if examined == 0 {
            Issue.record("No connected USB-C ports without USB3/CIO found in the probe set; the activeTBGbps gate is not exercised by this sweep")
        }
    }
}
