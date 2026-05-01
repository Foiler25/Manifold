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
// ─────────────────────────────────────────────────────────────────────
// PortGraphBuilder.swift
//
// Phase-2 transform: takes the flat `[USBDeviceSnapshot]` Phase 1
// produced and lifts it into the `[Host]` graph the rest of the app
// consumes. Per SPEC.md §6, the builder owns:
//
//   - PortID derivation from registry paths.
//   - parentID resolution from locationID nibbles.
//   - Display ↔ TB-port mapping (Phase 7 — out of Phase 2 scope).
//
// Why a struct, not a class: the builder is pure transformation —
// no mutable state, no IOKit calls, no actor isolation. Easy to
// unit-test against captured fixtures, easy to reason about. Future
// phases (TB walker, display resolver) get composed in via additional
// methods on the same type.
//
// Phase 2 scope: every USB device gets a host-rooted Port. Hub
// children (locationID nibbles 2+) are kept flat for now and
// re-hierarchised when Phase 7's `ThunderboltWalker` introduces
// downstream-tree handling. Documented as a Phase-2 simplification
// the Reviewer should sign off on.

import Foundation
import ManifoldKit

/// Extra info about the host that PortGraphBuilder needs to assemble
/// a `Host` value. Resolved by `DiscoveryService` from
/// `IOPlatformExpertDevice` properties.
struct HostMetadata: Sendable, Equatable {
    let id: HostID
    let name: String
    let model: String
}

struct PortGraphBuilder: Sendable {

    /// Build a single `Host` from the metadata + the flat list of
    /// captured USB devices. Phase 2 emits one root-level Port per
    /// device; hub-tree reconstruction lands in Phase 7 alongside the
    /// TB walker that produces the same shape.
    func buildHost(
        metadata: HostMetadata,
        usbDevices: [USBDeviceSnapshot],
        timestamp: Date = .now
    ) -> ManifoldKit.Host {
        let ports = usbDevices.enumerated().map { index, snapshot in
            makePort(from: snapshot, position: snapshot.portNum ?? (index + 1), timestamp: timestamp)
        }
        return ManifoldKit.Host(
            id: metadata.id,
            name: metadata.name,
            model: metadata.model,
            ports: ports
        )
    }

    // MARK: - Snapshot → Port / Device

    /// Lift one snapshot into a Port containing a Device, with
    /// negotiated link speed and computed power draw populated where
    /// the source data allows.
    private func makePort(
        from snapshot: USBDeviceSnapshot,
        position: Int,
        timestamp: Date
    ) -> ManifoldKit.Port {
        let device = makeDevice(from: snapshot, timestamp: timestamp)
        let linkSpeed = makeLinkSpeed(from: snapshot)
        let powerDraw = snapshot.requestedPowerMA
            .map { Watts.fromMilliamps($0, atVolts: USBBusVoltage.standard) }

        return ManifoldKit.Port(
            id: PortID(snapshot.registryPath),
            position: position,
            kind: .usbC,                   // Phase 2 default; Phase 7 refines from connector type
            parentID: nil,                 // Phase 2 keeps everything host-rooted; Phase 7 nests
            connectedDevice: device,
            negotiated: linkSpeed,
            powerDraw: powerDraw,
            children: []
        )
    }

    private func makeDevice(from snapshot: USBDeviceSnapshot, timestamp: Date) -> Device {
        let id = DeviceID.make(
            vendorID: snapshot.vendorID,
            productID: snapshot.productID,
            serial: snapshot.serial,
            registryPath: snapshot.registryPath
        )
        let resolvedName = snapshot.productName ?? "\(snapshot.vendorName ?? "Unknown") device"

        return Device(
            id: id,
            name: resolvedName,
            kind: .other,                              // Phase 2 default; Phase 5+ refines via CoreAudio/HID parent walks
            vendorID: snapshot.vendorID,
            productID: snapshot.productID,
            serial: snapshot.serial,
            usbVersion: deriveUSBVersion(from: snapshot.bcdUSB),
            displayInfo: nil,                          // Phase 7 populates for displays
            firstSeen: timestamp,
            lastSeen: timestamp
        )
    }

    private func makeLinkSpeed(from snapshot: USBDeviceSnapshot) -> LinkSpeed? {
        guard let speed = snapshot.speed else { return nil }
        return LinkSpeed(
            protocolName: USBDiscoveryConstants.speedName(for: speed),
            bitrate: Self.bitrate(forSpeedCode: speed)
        )
    }

    // MARK: - bcdUSB → USBVersion mapping

    /// Map the 16-bit BCD `bcdUSB` field to our typed `USBVersion`.
    /// Returns `.unknown` for recognised classes we don't have an enum
    /// case for, and `nil` only when the source had no bcdUSB at all.
    private func deriveUSBVersion(from bcd: UInt16?) -> USBVersion? {
        guard let bcd else { return nil }
        switch bcd {
        case 0x0200, 0x0210:        return .usb2_0
        case 0x0300, 0x0310:        return .usb3_0
        case 0x0320:                return .usb3_2
        case 0x0400...0x04FF:       return .usb4
        case 0x0500...0x05FF:       return .usb4_v2
        default:                    return .unknown
        }
    }

    // MARK: - IOKit Speed code → Bitrate

    /// Bitrate per IOKit speed enum value. Matches the labels in
    /// `USBDiscoveryConstants.speedName(for:)` so the protocolName and
    /// bitrate stay coherent. Static so it can be reused by tests
    /// without instantiating a builder.
    static func bitrate(forSpeedCode code: UInt32) -> Bitrate {
        switch code {
        case 0: return Bitrate(bitsPerSecond:    1_500_000)   // Low Speed
        case 1: return Bitrate(bitsPerSecond:   12_000_000)   // Full Speed
        case 2: return Bitrate(bitsPerSecond:  480_000_000)   // High Speed (USB 2.0)
        case 3: return Bitrate(bitsPerSecond:  5_000_000_000) // Super Speed (USB 3.0)
        case 4: return Bitrate(bitsPerSecond: 10_000_000_000) // Super Speed+ (USB 3.1 Gen 2)
        case 5: return Bitrate(bitsPerSecond: 20_000_000_000) // Super Speed++ (USB 3.2 Gen 2x2)
        default: return Bitrate(bitsPerSecond: 0)
        }
    }
}

// MARK: - USB bus voltage

/// USB bus voltage constant. Centralised because Phase 2 uses 5 V
/// (the standard USB-A / USB 2 / USB 3 bus voltage); Phase 5+ may
/// extend to USB-C PD-negotiated voltages once the CoreUSB framework
/// surfaces them on macOS 26.
enum USBBusVoltage {
    /// Standard USB bus voltage in volts. USB-PD negotiates higher
    /// rails (9, 12, 15, 20 V); for the requested-power → watts
    /// conversion in Phase 2 we use the conservative 5 V baseline.
    static let standard: Double = 5.0
}
