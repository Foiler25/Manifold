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
// Constants.swift (Discovery)
//
// Discovery-layer constants. Two reasons to centralise these:
//
//   1. IOKit class names and property keys are stringly-typed. A single
//      typo at a call site silently returns nil and the bug surfaces as
//      "the device just doesn't appear." Naming each key once eliminates
//      that class of bug.
//   2. Future phases extend the property set (Phase 7 adds Thunderbolt
//      keys, Phase 5 adds telemetry-time properties); having one home
//      for the namespace keeps additions discoverable.

import Foundation

/// USB-side discovery constants. Matches the property name strings IOKit
/// publishes on `IOUSBHostDevice` registry entries (BRIEF.md cheatsheet).
enum USBDiscoveryConstants {

    // MARK: Class names

    /// IOKit class matched to find each host's USB controllers. Walking
    /// from controllers downward gives us the controller→port→device
    /// hierarchy Phase 2's `PortGraphBuilder` will turn into `Host.ports`.
    static let hostControllerClassName = "AppleUSBHostController"

    /// IOKit class published once per connected USB device. Every entry
    /// the walker emits passes `IOObjectConformsTo` against this class.
    /// `IOUSBHostDevice` is the modern (macOS 10.11+) class; older code
    /// keyed on `IOUSBDevice`, which still works but produces duplicate
    /// entries on systems that publish both planes.
    static let hostDeviceClassName = "IOUSBHostDevice"

    // MARK: Property keys

    /// Stringly-typed IOKit property names. Keep these together so a
    /// `Cmd-F PropertyKey.` discovers everything we read.
    enum PropertyKey {
        static let idVendor         = "idVendor"
        static let idProduct        = "idProduct"
        static let bcdUSB           = "bcdUSB"
        static let speed            = "Speed"
        static let usbProductName   = "USB Product Name"
        static let usbVendorName    = "USB Vendor Name"
        static let requestedPower   = "Requested Power"
        static let portNum          = "PortNum"
        static let locationID       = "locationID"
        static let iSerialNumber    = "iSerialNumber"
    }

    // MARK: Fallback property-key chains (rev-3 / Phase 2 bullet)

    /// Per SPEC.md §18 Phase 2 (rev 3): canonical IOKit property names
    /// don't fire on every device under macOS 26 — Apple's M-series
    /// internal SSD, for example, returns nil for both `Speed` and
    /// `Requested Power`. The walker tries each alternate in order
    /// before giving up and producing nil. Order matters: the
    /// canonical keys come first so devices that publish them
    /// continue to work; the fallbacks add coverage for the cases
    /// that don't.
    enum FallbackKey {

        /// Tried in order when reading the negotiated link speed.
        ///
        /// - `Speed` (canonical IOUSBHostDevice property; covers most
        ///   external USB peripherals on macOS 14–26)
        /// - `Device Speed` (some pre-USB-3 drivers publish the link
        ///   speed under this key instead)
        /// - `USB Host Connect Speed` (the property name the
        ///   `kUSBHostPortPropertyConnectSpeed` constant resolves to —
        ///   used by macOS's newer USB stack on Apple Silicon)
        ///
        /// If every entry returns nil the walker falls back to deriving
        /// from `bcdUSB` (see `USBWalker.deriveSpeedFromBcd`) and
        /// finally to nil. Last-resort nil renders as "Unknown" in the
        /// popover row, which is the correct fallback rendering.
        static let speedAlternates: [String] = [
            "Speed",
            "Device Speed",
            "USB Host Connect Speed"
        ]

        /// Tried in order when reading the device's requested power.
        ///
        /// - `Requested Power` (canonical IOUSBHostDevice property,
        ///   value in milliamps)
        /// - `USB Power Required` (some legacy drivers expose it here)
        /// - `USBDeviceCurrent` (Apple T-series Mac internals
        ///   sometimes use this name)
        ///
        /// nil from every alternate means the device doesn't advertise
        /// power requirements (uncommon for self-powered storage; very
        /// common for built-in components).
        static let powerAlternates: [String] = [
            "Requested Power",
            "USB Power Required",
            "USBDeviceCurrent"
        ]

        /// Tried in order when reading the per-port available current
        /// budget (Phase 8 PowerDeficitRule consumer).
        ///
        /// - `Available Current` (canonical USB-A property)
        /// - `Port Power` (USB-C / TB-C ports often expose this
        ///   instead — already in milliamps, despite the name)
        ///
        /// nil from every alternate means the port doesn't advertise
        /// a budget; PowerDeficitRule treats absent budget as
        /// "infinite" and skips firing.
        static let availableCurrentAlternates: [String] = [
            "Available Current",
            "Port Power"
        ]
    }

    // MARK: Speed lookup

    /// Human-readable name for the IOKit `Speed` enum value. Codes
    /// match the values published by `AppleUSBHostDevice` on macOS 14+.
    /// Unknown codes get a `"USB ?" placeholder so the UI never shows
    /// the raw integer.
    ///
    /// Reference: `IOUSBHostFamily.framework`'s `IOUSBHostDeviceSpeed`.
    static func speedName(for raw: UInt32?) -> String {
        switch raw {
        case 0: return "USB Low Speed"     // 1.5 Mbps (USB 1.1)
        case 1: return "USB Full Speed"    // 12 Mbps (USB 1.1)
        case 2: return "USB High Speed"    // 480 Mbps (USB 2.0)
        case 3: return "USB Super Speed"   // 5 Gbps (USB 3.0)
        case 4: return "USB Super Speed+"  // 10 Gbps (USB 3.1 Gen 2)
        case 5: return "USB Super Speed++" // 20 Gbps (USB 3.2 Gen 2x2)
        case .none: return "Unknown"
        case .some(let value): return "USB ? (raw=\(value))"
        }
    }
}
