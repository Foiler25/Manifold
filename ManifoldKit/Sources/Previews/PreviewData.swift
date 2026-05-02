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
// PreviewData.swift
//
// Per SPEC.md §13.3: "Every non-trivial view file ends with a #Preview
// block using PreviewData.swift fixtures (lives in ManifoldKit so
// widget previews can use it too)."
//
// Public, read-only namespace of canonical sample values. Same shape
// as the production data so view code paths exercised in previews are
// identical to runtime. Values pinned here so screenshot regressions
// in Xcode previews surface as obvious diffs.
//
// Naming convention: each constant is `<Type>.preview<Variant>` —
// e.g. `Host.previewMacBook`, `Device.previewLogitechMouse`. The
// variant suffix lets a single preview file mix-and-match without
// repetitive setup.

public import Foundation

public enum PreviewData {

    /// Stable timestamp every preview value uses for `firstSeen`/
    /// `lastSeen`/`triggeredAt` — keeps preview snapshots reproducible.
    public static let timestamp = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Devices

    /// Logitech MX Master 3 wireless receiver. Low-power USB 2.0 input
    /// device — the canonical "boring peripheral" in previews.
    public static let logitechMouse = Device(
        id: DeviceID.make(vendorID: 0x046D, productID: 0xC52B, serial: nil, registryPath: "/preview/logitech"),
        name: "Logitech MX Master 3",
        kind: .input,
        vendorID: 0x046D,
        productID: 0xC52B,
        serial: nil,
        usbVersion: .usb2_0,
        displayInfo: nil,
        firstSeen: timestamp,
        lastSeen: timestamp
    )

    /// SanDisk Extreme Pro USB 3.2 SSD. Bulk storage, high power draw.
    public static let sandiskSSD = Device(
        id: DeviceID.make(vendorID: 0x0781, productID: 0x55A2, serial: "0123456789ABCDEF", registryPath: "/preview/sandisk"),
        name: "SanDisk Extreme Pro",
        kind: .storage,
        vendorID: 0x0781,
        productID: 0x55A2,
        serial: "0123456789ABCDEF",
        usbVersion: .usb3_2,
        displayInfo: nil,
        firstSeen: timestamp,
        lastSeen: timestamp
    )

    /// Apple Studio Display. Display-class device with `displayInfo`
    /// populated — exercises the display-row code path Phase 7+ will
    /// extend.
    public static let studioDisplay = Device(
        id: DeviceID.make(vendorID: 0x05AC, productID: 0x1130, serial: "F2LXDAAAJK3M", registryPath: "/preview/studio-display"),
        name: "Studio Display",
        kind: .display,
        vendorID: 0x05AC,
        productID: 0x1130,
        serial: "F2LXDAAAJK3M",
        usbVersion: .usb3_2,
        displayInfo: DisplayInfo(
            resolution: CGSize(width: 5120, height: 2880),
            refreshHz: 60,
            panelType: "Retina 5K",
            isMain: false,
            isBuiltIn: false,
            supportsHDR: false
        ),
        firstSeen: timestamp,
        lastSeen: timestamp
    )

    // MARK: - Ports

    /// Empty USB-C port. Exercises the "no device" rendering path.
    public static let emptyUSBCPort = Port(
        id: PortID("/preview/empty-usbc"),
        position: 1,
        kind: .usbC,
        parentID: nil,
        connectedDevice: nil,
        negotiated: nil,
        powerDraw: nil,
        children: []
    )

    /// USB-C port with the Logitech mouse attached. USB 2 link, low draw.
    public static let logitechPort = Port(
        id: PortID("/preview/logitech-port"),
        position: 1,
        kind: .usbC,
        parentID: nil,
        connectedDevice: logitechMouse,
        negotiated: LinkSpeed(protocolName: "USB 2.0", bitrate: Bitrate(bitsPerSecond: 480_000_000)),
        powerDraw: Watts.fromMilliamps(98, atVolts: 5.0),
        children: []
    )

    /// USB-C port with the SanDisk SSD. USB 3.2 Gen 2x2 link, high draw.
    public static let sandiskPort = Port(
        id: PortID("/preview/sandisk-port"),
        position: 2,
        kind: .usbC,
        parentID: nil,
        connectedDevice: sandiskSSD,
        negotiated: LinkSpeed(protocolName: "USB 3.2", bitrate: Bitrate(bitsPerSecond: 10_000_000_000)),
        powerDraw: Watts.fromMilliamps(896, atVolts: 5.0),
        children: []
    )

    /// USB-C port with the Studio Display.
    public static let studioDisplayPort = Port(
        id: PortID("/preview/studio-display-port"),
        position: 3,
        kind: .usbC,
        parentID: nil,
        connectedDevice: studioDisplay,
        negotiated: LinkSpeed(protocolName: "USB 3.2", bitrate: Bitrate(bitsPerSecond: 10_000_000_000)),
        powerDraw: Watts.fromMilliamps(500, atVolts: 5.0),
        children: []
    )

    // MARK: - Hosts

    /// Sample Mac with the three preview ports. Sized so the popover
    /// previews show realistic content without needing a scroll.
    public static let macBook = Host(
        id: HostID("PREVIEW-MAC-UUID"),
        name: "MacBook Pro",
        model: "Mac15,9",
        ports: [logitechPort, sandiskPort, studioDisplayPort]
    )

    /// Empty host — useful for the popover empty-state preview.
    public static let emptyMacBook = Host(
        id: HostID("PREVIEW-EMPTY-MAC-UUID"),
        name: "MacBook Pro",
        model: "Mac15,9",
        ports: []
    )

    // MARK: - Diagnostics

    /// "Running @ USB 2.0" warning targeting the SanDisk port. Used by
    /// the host header preview to render the diagnostic-count badge.
    public static let runningAtUSB2Warning = Diagnostic(
        target: sandiskPort.id,
        severity: .warning,
        ruleIdentifier: "running-at-usb-2",
        title: "Running @ USB 2.0",
        detail: "Device supports USB 3.0 but is on a USB 2.0 link.",
        triggeredAt: timestamp
    )
}
