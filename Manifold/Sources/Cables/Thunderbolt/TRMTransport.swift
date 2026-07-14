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
public import Foundation

/// Trust and Restrict Management (TRM) state for one transport on a port.
///
/// Apple's TRM system controls whether USB accessories get full or limited
/// access to the Mac. Each transport (USB2, DisplayPort, etc.) carries its
/// own TRM state, so a single port can have USB2 restricted while
/// DisplayPort is unrestricted.
///
/// These IOKit services (`IOPortTransportStateUSB2`,
/// `IOPortTransportStateDisplayPort`, etc.) appear dynamically when a
/// device is connected and disappear on unplug, same as `USB3Transport`.
///
/// The watcher reads the `TRM_*` properties from each transport service.
/// The model correlates to ports via `portKey`, matching the pattern used
/// by `USB3Transport` and `PowerSource`.
public struct TRMTransport: Identifiable, Hashable, Sendable {
    public let id: UInt64
    /// Port correlation key matching `PowerSource.portKey`.
    /// Format: `"\(parentPortType)/\(parentPortNumber)"`.
    public let portKey: String
    /// Which transport this TRM state applies to, e.g. "USB2", "DisplayPort".
    public let transportType: String

    // MARK: - TRM state fields

    /// Overall TRM state: 0 = Full access, 2 = Limited. Nil when the
    /// transport doesn't carry a TRM_State property (e.g. DisplayPort
    /// might only have TRM_TransportSupervised).
    public let state: Int?
    /// Human-readable state label from IOKit, e.g. "Limited" or "Full".
    public let stateDescription: String?
    /// True when this transport is actively restricted by TRM.
    public let transportRestricted: Bool?
    /// True when TRM is supervising this transport (policy is active).
    public let transportSupervised: Bool?
    /// True when identification (USB descriptors, etc.) is restricted.
    public let identificationRestricted: Bool?
    /// True when the device is in a locked state.
    public let deviceLocked: Bool?
    /// True during the grace period where new accessories are allowed
    /// temporarily (e.g. right after unlocking the Mac).
    public let relaxedPeriod: Bool?
    /// Numeric reason code for the current grace period, if any.
    public let gracePeriodReason: Int?
    /// Human-readable grace period reason, e.g. "Device Unlocked".
    public let gracePeriodReasonDescription: String?
    /// TRM policy profile: 2 = "Ask for New Accessories", etc.
    public let profile: Int?
    /// Human-readable profile label from IOKit.
    public let profileDescription: String?
    /// True when the TRM cache missed for this accessory (first time seen).
    public let cacheMiss: Bool?
    /// HPM controller UUID captured by walking the IOKit parent chain.
    /// Internal join key only. Never serialised to JSON or text output.
    public let hpmControllerUUID: String?

    public init(
        id: UInt64,
        portKey: String,
        transportType: String,
        state: Int?,
        stateDescription: String?,
        transportRestricted: Bool?,
        transportSupervised: Bool?,
        identificationRestricted: Bool?,
        deviceLocked: Bool?,
        relaxedPeriod: Bool?,
        gracePeriodReason: Int?,
        gracePeriodReasonDescription: String?,
        profile: Int?,
        profileDescription: String?,
        cacheMiss: Bool?,
        hpmControllerUUID: String? = nil
    ) {
        self.id = id
        self.portKey = portKey
        self.transportType = transportType
        self.state = state
        self.stateDescription = stateDescription
        self.transportRestricted = transportRestricted
        self.transportSupervised = transportSupervised
        self.identificationRestricted = identificationRestricted
        self.deviceLocked = deviceLocked
        self.relaxedPeriod = relaxedPeriod
        self.gracePeriodReason = gracePeriodReason
        self.gracePeriodReasonDescription = gracePeriodReasonDescription
        self.profile = profile
        self.profileDescription = profileDescription
        self.cacheMiss = cacheMiss
        self.hpmControllerUUID = hpmControllerUUID
    }

    /// Canonical in-session join key: normalised UUID when captured, else portKey.
    /// Internal only; never expose in JSON or text output.
    public var canonicalJoinKey: String {
        if let uuid = hpmControllerUUID {
            let n = uuid.replacingOccurrences(of: "-", with: "").lowercased()
            if n.count == 32 { return n }
        }
        return portKey
    }

    /// True when this transport belongs to the same physical port as `port`.
    /// UUID-keyed when both sides have a UUID, portKey fallback otherwise.
    public func canonicallyMatches(port: AppleHPMInterface) -> Bool {
        guard let portKey = port.portKey else { return false }
        if let srcUUID = hpmControllerUUID, let portUUID = port.hpmControllerUUID {
            let sn = srcUUID.replacingOccurrences(of: "-", with: "").lowercased()
            let pn = portUUID.replacingOccurrences(of: "-", with: "").lowercased()
            if sn.count == 32 && pn.count == 32 { return sn == pn }
        }
        return self.portKey == portKey
    }

    /// True when this transport is in a restricted (limited) TRM state.
    public var isRestricted: Bool {
        transportRestricted == true || state == 2
    }

    /// User-facing summary label for this transport's TRM state.
    public var summaryLabel: String {
        if let desc = stateDescription {
            return "\(transportType): \(desc)"
        }
        if transportSupervised == true {
            return "\(transportType): Supervised"
        }
        return "\(transportType): Unknown"
    }
}
