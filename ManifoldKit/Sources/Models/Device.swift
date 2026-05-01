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
// Device.swift
//
// One connected piece of hardware. Per SPEC.md §4.3.

public import Foundation

// MARK: - DeviceKind

/// Coarse device classification. Drives the popover's row icon and
/// Phase 8's per-kind diagnostic rules. Mapped from USB descriptor
/// class codes by the discovery layer; unknown class codes land in
/// `.other` rather than throwing.
public enum DeviceKind: String, Sendable, Codable, CaseIterable {
    case audio, display, input, storage, hub, video, networking, other
}

// MARK: - USBVersion

/// Device-side USB protocol version, parsed from the BCD `bcdUSB`
/// descriptor field. String raw values match the human-facing labels
/// the popover renders, so no separate display table is needed.
public enum USBVersion: String, Sendable, Codable {
    case usb2_0   = "USB 2.0"
    case usb3_0   = "USB 3.0"
    case usb3_1   = "USB 3.1"
    case usb3_2   = "USB 3.2"
    case usb4     = "USB4"
    case usb4_v2  = "USB4 v2"
    case unknown  = "Unknown"
}

// MARK: - Device

public struct Device: Identifiable, Hashable, Sendable, Codable {

    /// Composite VID:PID:serial (or VID:PID:registryPath fallback)
    /// per DECISIONS.md D9.
    public let id: DeviceID

    /// Resolved product name. Sourced from USB string descriptors,
    /// CoreAudio, or HID; falls back to "VID:PID" when the device
    /// publishes no strings (the fallback is computed at the UI layer,
    /// not here — `Device.name` is whatever the discovery layer
    /// resolved, even if empty).
    public let name: String

    /// Coarse classification — see `DeviceKind`.
    public let kind: DeviceKind

    /// USB Vendor ID (16-bit per spec). 0 is reserved and would mean
    /// "no vendor"; in practice the discovery walker rejects devices
    /// without a VID.
    public let vendorID: UInt16

    /// USB Product ID (16-bit per spec).
    public let productID: UInt16

    /// Serial number string from `iSerialNumber`. nil for devices
    /// that don't expose one. Used by `DeviceID.make` to produce a
    /// stable ID across replug events on different ports.
    public let serial: String?

    /// USB protocol version derived from `bcdUSB`. nil for non-USB
    /// devices (Thunderbolt-native, displays, …) where the field has
    /// no meaning.
    public let usbVersion: USBVersion?

    /// Display-specific metadata — only populated when `kind == .display`.
    public let displayInfo: DisplayInfo?

    /// First time we observed this DeviceID. Persisted to GRDB in
    /// Phase 10; for a freshly-discovered device this matches `lastSeen`.
    public let firstSeen: Date

    /// Most recent observation timestamp. Updated by Phase 3 events
    /// and Phase 5 telemetry samples.
    public let lastSeen: Date

    public init(
        id: DeviceID,
        name: String,
        kind: DeviceKind,
        vendorID: UInt16,
        productID: UInt16,
        serial: String?,
        usbVersion: USBVersion?,
        displayInfo: DisplayInfo?,
        firstSeen: Date,
        lastSeen: Date
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.vendorID = vendorID
        self.productID = productID
        self.serial = serial
        self.usbVersion = usbVersion
        self.displayInfo = displayInfo
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}
