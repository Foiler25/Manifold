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

/// Cable/link data from Apple's CIO (Thunderbolt) transport controller.
///
/// These properties come from `IOPortTransportStateCIO`, which appears
/// dynamically when a Thunderbolt link is active. Most fields in
/// `PORT_CS_18` are cable-state values populated per-connection from
/// VDM exchange during link bring-up, not static port capabilities.
///
/// `negotiatedLinkSpeed` is confirmed across TB3, TB4, and TB5 (see
/// `research/cio-value-mappings.md`); it is the negotiated rate, a
/// floor on cable capability, never a cap (issue #393). `asymmetricModeSupported` is
/// a cable property (Cable Asymmetric Support from PORT_CS_18.CSA).
/// The integer fields (`cableGeneration`, `generation`) are stored
/// raw; their meaning is not yet confirmed.
public struct CIOCableCapability: Identifiable, Hashable, Sendable {
    public let id: UInt64
    /// Port correlation key matching `PowerSource.portKey`.
    public let portKey: String

    /// Likely cable Gen 4 capability from `PORT_CS_18.CG4` (bit 21),
    /// populated via VDM during link bring-up. Working hypothesis:
    /// 1 = cable is Gen 3 only, 2 = cable supports Gen 4. Not yet
    /// confirmed by controlled cable swap. Known to be unstable on
    /// ~12% of sampled ports (different value in successive reads
    /// <1s apart). Do not derive any user-facing label from it yet.
    public let cableGeneration: Int?
    /// Negotiated link rate from `LANE_ADP_CS_1.CURRENT_SPEED`, a FLOOR
    /// on cable capability, never a cap. Confirmed: 2 = 20 Gbps (TB3),
    /// 3 = 40 Gbps (TB4), 4 = 80 Gbps (TB5). Reflects the lowest common
    /// denominator of host, cable, and downstream device: a cable can
    /// legitimately support more than this value if either endpoint is
    /// the one holding the link back (issue #393). Named
    /// `negotiatedLinkSpeed` rather than the raw IOKit key name
    /// (`CableSpeed`) so the "floor, not a cap" meaning survives at
    /// every call site; the JSON output key stays `"cableSpeed"` for
    /// schema stability (see `JSONFormatter`'s `CIOCableCapabilityDTO`).
    public let negotiatedLinkSpeed: Int?
    /// Raw CIO value of unknown meaning. NOT a USB4 Gen number and
    /// not a legacy-vs-native flag: probe data is mostly 2 across
    /// TB3, TB4, and TB5 (TB5 included), with occasional 3. Do not
    /// derive any label from it.
    public let generation: Int?
    /// Cable asymmetric-mode capability from `PORT_CS_18.CSA` (bit 22).
    /// This is a cable-state field populated per-connection from VDM
    /// exchange during link bring-up, not a static port capability.
    /// Different cables on the same port produce different values.
    /// Cleared to surface as "Cable supports asymmetric mode" (see
    /// `research/cio-value-mappings.md`), but not yet built into any UI
    /// as of 2026-07-03: it currently only reaches JSON output and the
    /// cable-report markdown.
    public let asymmetricModeSupported: Bool?
    /// Raw CIO flag. Observed `false` on every sampled connection,
    /// including a real TB3 dock (M1 Max + ThinkPad TB3). The earlier
    /// "true for TB3" reading is disproven; the meaning of a `true`
    /// value is unobserved. Do not rely on it.
    public let legacyAdapter: Bool?
    /// Link training mode reported by CIO. Meaning TBD.
    public let linkTrainingMode: Int?

    /// HPM controller UUID captured by walking the IOKit parent chain.
    /// Internal join key only. Never serialised to JSON or text output.
    public let hpmControllerUUID: String?

    public init(
        id: UInt64,
        portKey: String,
        cableGeneration: Int?,
        negotiatedLinkSpeed: Int?,
        generation: Int?,
        asymmetricModeSupported: Bool?,
        legacyAdapter: Bool?,
        linkTrainingMode: Int?,
        hpmControllerUUID: String? = nil
    ) {
        self.id = id
        self.portKey = portKey
        self.cableGeneration = cableGeneration
        self.negotiatedLinkSpeed = negotiatedLinkSpeed
        self.generation = generation
        self.asymmetricModeSupported = asymmetricModeSupported
        self.legacyAdapter = legacyAdapter
        self.linkTrainingMode = linkTrainingMode
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

    /// True when this capability record belongs to the same physical port as `port`.
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

    /// Human-readable speed label for a confirmed `negotiatedLinkSpeed`
    /// value, or `nil` when the code is unrecognised.
    ///
    /// Maps the CIO negotiated-link-rate codes confirmed by real probes
    /// spanning TB3, TB4, and TB5 (2 = 20 Gbps, 3 = 40 Gbps,
    /// 4 = 80 Gbps; see `research/cio-value-mappings.md`). Returns
    /// `nil` for unknown codes so callers can fall back to a generic
    /// bullet rather than leaking raw IOKit numbers into user-facing
    /// text.
    ///
    /// The input is the negotiated rate, a floor on cable capability,
    /// not a cap (issue #393). The "N Gbps capable" label is only valid
    /// as a floor/confirmation: it means the controller has actually
    /// seen the cable carry N Gbps, not that N Gbps is the cable's
    /// ceiling. Callers must not use this label when the cable's own
    /// e-marker claims a higher tier than this code confirms; see
    /// `PortSummary`'s confirm-vs-link-line split.
    public static func speedLabel(for cableSpeed: Int) -> String? {
        switch cableSpeed {
        case 2: return String(localized: "20 Gbps capable", bundle: _coreLocalizedBundle)
        case 3: return String(localized: "40 Gbps capable", bundle: _coreLocalizedBundle)
        case 4: return String(localized: "80 Gbps capable", bundle: _coreLocalizedBundle)
        default: return nil
        }
    }
}
