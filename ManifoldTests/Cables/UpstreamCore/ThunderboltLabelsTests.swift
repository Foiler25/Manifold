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

/// Tests for the user-facing label helpers and topology walker.
/// These cover the rendering convention chosen for Phase 3:
///   - per-lane Gb/s x lane count, matching Apple's `system_profiler`
///   - hedge wording for unknown speed codes
///   - daisy-chain detection by `parentSwitchUID`
@Suite("Thunderbolt Labels")
struct ThunderboltLabelsTests {

    // MARK: - linkLabel

    @Test("Label for TB3 dual lane")
    func labelForTb3DualLane() {
        let port = makeLanePort(speed: .tb3, widthRaw: 0x2)
        #expect(ThunderboltLabels.linkLabel(for: port) == "Up to 10 Gb/s × 2")
    }

    @Test("Label for TB3 single lane")
    func labelForTb3SingleLane() {
        let port = makeLanePort(speed: .tb3, widthRaw: 0x1)
        #expect(ThunderboltLabels.linkLabel(for: port) == "Up to 10 Gb/s × 1")
    }

    @Test("Label for USB4 dual lane")
    func labelForUsb4DualLane() {
        let port = makeLanePort(speed: .usb4Tb4, widthRaw: 0x2)
        #expect(ThunderboltLabels.linkLabel(for: port) == "Up to 20 Gb/s × 2")
    }

    /// TB5 was confirmed against a real M5 Pro + UGreen JHL9580 dock
    /// sample on issue #52, so the renderer now emits the same per-lane
    /// label format as TB3 and TB4 / USB4.
    @Test("Label for TB5 dual lane")
    func labelForTb5DualLane() {
        let port = makeLanePort(speed: .tb5, widthRaw: 0x2)
        #expect(ThunderboltLabels.linkLabel(for: port) == "Up to 40 Gb/s × 2")
    }

    /// TB5 asymmetric 3 TX / 1 RX is the 120 Gb/s configuration reported
    /// by `system_profiler` on the M5 Pro + UGreen dock sample.
    @Test("Label for TB5 asymmetric")
    func labelForTb5Asymmetric() {
        let port = makeLanePort(speed: .tb5, widthRaw: 0x4)
        #expect(ThunderboltLabels.linkLabel(for: port) == "Up to 40 Gb/s (3 TX / 1 RX)")
    }

    @Test("Label for unknown generation is hedged")
    func labelForUnknownGenerationIsHedged() {
        let port = makeLanePort(speed: .unknown(rawSpeedCode: 0x1), widthRaw: 0x2)
        #expect(ThunderboltLabels.linkLabel(for: port) == "Unknown generation (raw speed code 0x1)")
    }

    @Test("Label nil for idle port")
    func labelNilForIdlePort() {
        let port = makeLanePort(speed: nil, widthRaw: 0)
        #expect(ThunderboltLabels.linkLabel(for: port) == nil)
    }

    @Test("Label for asymmetric link")
    func labelForAsymmetricLink() {
        // 3 TX / 1 RX. We have no real TB5 sample, but the model must
        // produce a sensible label if one ever lands.
        let port = makeLanePort(speed: .usb4Tb4, widthRaw: 0x4)
        #expect(ThunderboltLabels.linkLabel(for: port) == "Up to 20 Gb/s (3 TX / 1 RX)")
    }

    // MARK: - deviceName

    @Test("Device name ASUS")
    func deviceNameAsus() {
        let sw = makeSwitch(uid: 1, vendor: "ASUS-Display", model: "PA32QCV")
        #expect(ThunderboltLabels.deviceName(for: sw) == "ASUS-Display PA32QCV")
    }

    @Test("Device name missing fields falls back")
    func deviceNameMissingFieldsFallsBack() {
        let sw = makeSwitch(uid: 1, vendor: "", model: "")
        #expect(ThunderboltLabels.deviceName(for: sw) == "Unknown device")
    }

    @Test("Device name does not double a brand the model already carries")
    func deviceNameDoesNotDoubleBrand() {
        // DROM reported vendor "Ugreen" and model "Ugreen Storage Device"
        // (issue #392). The old code produced "Ugreen Ugreen Storage Device".
        let sw = makeSwitch(uid: 1, vendor: "Ugreen", model: "Ugreen Storage Device")
        #expect(ThunderboltLabels.deviceName(for: sw) == "Ugreen Storage Device")
    }

    @Test("Device name collapses when vendor equals model")
    func deviceNameCollapsesWhenVendorEqualsModel() {
        let sw = makeSwitch(uid: 1, vendor: "Ugreen", model: "Ugreen")
        #expect(ThunderboltLabels.deviceName(for: sw) == "Ugreen")
    }

    @Test("Device name dedup is case-insensitive")
    func deviceNameDedupCaseInsensitive() {
        let sw = makeSwitch(uid: 1, vendor: "UGREEN", model: "ugreen storage device")
        #expect(ThunderboltLabels.deviceName(for: sw) == "ugreen storage device")
    }

    @Test("Device name keeps vendor when model only shares a prefix word")
    func deviceNameKeepsVendorOnPartialWordPrefix() {
        // "Cal" must not collapse "Calibre X": the match is whole-word only.
        let sw = makeSwitch(uid: 1, vendor: "Cal", model: "Calibre X")
        #expect(ThunderboltLabels.deviceName(for: sw) == "Cal Calibre X")
    }

    // MARK: - Topology socket-ID parsing

    @Test("Socket ID extracted from at-suffix")
    func socketIDExtractedFromAtSuffix() {
        #expect(ThunderboltTopology.socketID(fromServiceName: "Port-USB-C@1") == "1")
        #expect(ThunderboltTopology.socketID(fromServiceName: "Port-USB-C@3") == "3")
    }

    @Test("Socket ID nil when no at-suffix")
    func socketIDNilWhenNoAtSuffix() {
        #expect(ThunderboltTopology.socketID(fromServiceName: "Port-USB-C") == nil)
    }

    // MARK: - Topology chain walking

    @Test("Chain single hop")
    func chainSingleHop() {
        let host = makeSwitch(uid: 100, depth: 0, parent: nil, ports: [
            makeLanePort(portNumber: 1, socketID: "1", speed: .usb4Tb4, widthRaw: 0x2)
        ])
        let device = makeSwitch(uid: 200, depth: 1, parent: 100, vendor: "ASUS-Display", model: "PA32QCV")
        let chain = ThunderboltTopology.chain(from: host, in: [host, device])
        #expect(chain.count == 2)
        #expect(chain.first?.id == 100)
        #expect(chain.last?.id == 200)
    }

    @Test("Chain daisy two hops")
    func chainDaisyTwoHops() {
        let host = makeSwitch(uid: 100, depth: 0, parent: nil, ports: [])
        let asus = makeSwitch(uid: 200, depth: 1, parent: 100, vendor: "ASUS-Display", model: "PA32QCV")
        let ts3 = makeSwitch(uid: 300, depth: 2, parent: 200, vendor: "CalDigit, Inc.", model: "TS3 Plus")
        let chain = ThunderboltTopology.chain(from: host, in: [host, asus, ts3])
        #expect(chain.map(\.id) == [100, 200, 300])
    }

    // MARK: - hostRoot lookup by Socket ID

    @Test("Host root matches by socket ID")
    func hostRootMatchesBySocketID() {
        let portA = makeLanePort(portNumber: 1, socketID: "1", speed: .usb4Tb4, widthRaw: 0x2)
        let portB = makeLanePort(portNumber: 2, socketID: "2", speed: nil, widthRaw: 0)
        let root1 = makeSwitch(uid: 100, depth: 0, parent: nil, ports: [portA])
        let root2 = makeSwitch(uid: 200, depth: 0, parent: nil, ports: [portB])
        let device = makeSwitch(uid: 999, depth: 1, parent: 100)
        let switches = [root1, root2, device]

        #expect(ThunderboltTopology.hostRoot(forSocketID: "1", in: switches)?.id == 100)
        #expect(ThunderboltTopology.hostRoot(forSocketID: "2", in: switches)?.id == 200)
        #expect(ThunderboltTopology.hostRoot(forSocketID: "3", in: switches) == nil)
    }

    // MARK: - activeDownstreamLanePort

    @Test("Active downstream lane port on host root")
    func activeDownstreamLanePortOnHostRoot() {
        let port1 = makeLanePort(portNumber: 1, socketID: "1", speed: .usb4Tb4, widthRaw: 0x2)
        let root = makeSwitch(uid: 100, depth: 0, parent: nil, ports: [port1])
        #expect(ThunderboltTopology.activeDownstreamLanePort(root)?.portNumber == 1)
    }

    /// On a downstream switch, the upstream lane port (matching
    /// `upstreamPortNumber`) faces the host. The downstream port is the
    /// one that goes toward the next-hop device.
    @Test("Active downstream lane port skips upstream on deep switch")
    func activeDownstreamLanePortSkipsUpstreamOnDeepSwitch() {
        let upPort = makeLanePort(portNumber: 1, socketID: nil, speed: .usb4Tb4, widthRaw: 0x2)
        let downPort = makeLanePort(portNumber: 4, socketID: nil, speed: .tb3, widthRaw: 0x1)
        let dock = makeSwitch(
            uid: 200, depth: 1, parent: 100,
            upstreamPortNumber: 1,
            ports: [upPort, downPort]
        )
        #expect(ThunderboltTopology.activeDownstreamLanePort(dock)?.portNumber == 4)
    }
}

// MARK: - Test helpers

private func makeLanePort(
    portNumber: Int = 1,
    socketID: String? = nil,
    speed: LinkGeneration?,
    widthRaw: UInt8
) -> IOThunderboltPort {
    IOThunderboltPort(
        portNumber: portNumber,
        socketID: socketID,
        adapterType: .lane,
        currentSpeed: speed,
        currentWidth: LinkWidth(rawValue: widthRaw),
        targetWidth: nil,
        rawTargetSpeed: nil,
        linkBandwidthRaw: nil
    )
}

private func makeSwitch(
    uid: Int64,
    depth: Int = 0,
    parent: Int64? = nil,
    upstreamPortNumber: Int = 0,
    vendor: String = "Apple Inc.",
    model: String = "iOS",
    ports: [IOThunderboltPort] = []
) -> IOThunderboltSwitch {
    IOThunderboltSwitch(
        id: uid,
        className: "IOIOThunderboltSwitchType7",
        vendorID: 1452,
        vendorName: vendor,
        modelName: model,
        routerID: 0,
        depth: depth,
        routeString: 0,
        upstreamPortNumber: upstreamPortNumber,
        maxPortNumber: 8,
        supportedSpeed: SupportedSpeedMask(rawValue: 12),
        ports: ports,
        parentSwitchUID: parent
    )
}
