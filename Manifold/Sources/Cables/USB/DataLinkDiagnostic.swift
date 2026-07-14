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

/// Compares what the Mac port, the cable, and the connected device can each
/// do for data, against the speed the link actually negotiated, and names
/// the weakest link. This is the data-speed sibling of `ChargingDiagnostic`
/// (which does the same job for power). Same shape on purpose: a failable
/// init that returns `nil` when there is nothing to judge, a `Bottleneck`
/// enum carrying the numbers, and plain-English `summary` / `detail`.
///
/// Phase 1 wording is deliberately NOT localised yet. The strings are under
/// review; once the verdict wording is approved they move to
/// `String(localized:)` against `_coreLocalizedBundle` in the UI phase,
/// matching `ChargingDiagnostic`.
public struct DataLinkDiagnostic {
    public enum Bottleneck: Hashable {
        /// Link is running at the fastest the parties support. Not a fault.
        case fine(activeGbps: Double)
        /// The cable is the binding constraint; host and device could go faster.
        case cableLimit(cableGbps: Double, capableGbps: Double)
        /// This Mac port is the slowest link.
        case hostLimit(hostGbps: Double, capableGbps: Double)
        /// The connected device itself is the cap (e.g. a USB 2.0 device).
        /// Normal, not actionable: not a cable fault.
        case deviceLimit(deviceGbps: Double)
        /// Everyone supports more than the active speed but no single
        /// culprit can be pinned. The honest answer to the case the old
        /// draft wrongly reported as "full speed".
        case degraded(activeGbps: Double, expectedGbps: Double)
        /// No e-marker and no controller data, so we cannot say whether the
        /// cable is the limit. Stated plainly rather than guessed. Also
        /// reused (issue #393) as a hedge when the only figure suggesting
        /// the link is "slower than expected" is an unverified e-marker
        /// claim above the CIO floor, with no independently-known host or
        /// device cap to corroborate it: a healthy link, not a fault, so
        /// we say what we can verify rather than guess a culprit.
        case unknownCable(activeGbps: Double)
        /// The cable's e-marker reports a speed meaningfully below the
        /// link's apparent active rate, and there is no controller (CIO)
        /// reading to break the tie. One of the two signals is wrong; we
        /// surface both numbers rather than silently picking a side
        /// (issue #195 follow-up: the old defence-in-depth floor would
        /// promote the cable to the active rate, which masked
        /// legitimately slow cables whenever the active reading was
        /// itself unreliable).
        case cableContradictsActive(cableGbps: Double, activeGbps: Double)
        /// macOS TRM (Trust and Restrict Management) has blocked data on this
        /// transport. The link is physically capable of `signaledGbps`, but
        /// macOS is withholding data until the user approves the accessory.
        /// Takes precedence over healthy/speed verdicts because the link is
        /// not actually passing data regardless of the signaled rate.
        case blockedBySecurity(signaledGbps: Double)
    }

    public let bottleneck: Bottleneck
    public let summary: String
    public let detail: String

    /// True for the cases worth flagging in the inline one-line verdict.
    /// `deviceLimit` and `unknownCable` are informational, not faults, so
    /// they do not warn (a USB 2.0 keyboard or an e-marker-less cable is
    /// normal). This is a deliberate deviation from `ChargingDiagnostic`,
    /// where only `.fine` is non-warning.
    public var isWarning: Bool {
        switch bottleneck {
        case .fine, .deviceLimit, .unknownCable: return false
        case .cableLimit, .hostLimit, .degraded, .cableContradictsActive, .blockedBySecurity: return true
        }
    }

    /// True when the cable's own e-marker disagrees with the Thunderbolt
    /// controller's view of the cable (issue #111: active TB4 cables that
    /// report "passive" / a low speed in their e-marker while the
    /// controller correctly negotiates the full rate). When true the
    /// controller's higher figure is used and `detail` says so.
    public let cableSignalConflict: Bool

    /// The resolved per-party figures behind the verdict, in Gbps. The
    /// inline one-line verdict uses `summary`; the Pro breakdown renders
    /// these so the user can see the receipts (cable claims X, device does
    /// Y, link negotiated Z). All optional except `activeGbps`, which is
    /// always known (the diagnostic returns nil without it).
    public struct Facts: Hashable {
        /// What this Mac port can do, if the caller resolved it.
        public let hostGbps: Double?
        /// Cable speed as claimed by its own USB-PD e-marker.
        public let cableEmarkerGbps: Double?
        /// The negotiated link rate as the Thunderbolt controller sees it
        /// (CIO). A floor on cable capability, never a cap.
        public let cableControllerGbps: Double?
        /// The cable figure actually used: agreement when both signals are
        /// the same tier; the controller's figure when it measured a
        /// higher, confirmed rate than the e-marker claims (issue #111);
        /// otherwise the e-marker's own claim, since the controller's
        /// negotiated-rate floor never caps what the cable itself can do
        /// (issue #393).
        public let cableGbps: Double?
        /// The fastest connected device's speed.
        public let deviceGbps: Double?
        /// Name of the device used for `deviceGbps`, for display in tiles.
        public let deviceName: String?
        /// The speed the link actually negotiated.
        public let activeGbps: Double
    }

    public let facts: Facts
}

extension DataLinkDiagnostic {
    /// - Parameters:
    ///   - port: the physical USB-C / MagSafe port. Used only to gate on
    ///     `connectionActive` (mirrors `ChargingDiagnostic`'s stale-port
    ///     guard: a disconnected port can keep cached state around).
    ///   - identities: USB-PD Discover Identity endpoints for this port.
    ///     The cable e-marker is the SOP' / SOP'' entry; the connected
    ///     device/charger is SOP. We read the cable's claimed speed here.
    ///   - devices: USB devices on this port. The fastest one is taken as
    ///     the representative device cap (the device the link is serving).
    ///   - usb3Transports: USB 3 SuperSpeed transports; the one matching
    ///     this port (by `portKey`) gives the negotiated USB 3 rate.
    ///   - cio: the Thunderbolt controller's own cable assessment for this
    ///     port, if a TB link is active. Ground truth for TB cables and can
    ///     legitimately disagree with the e-marker (issue #111).
    ///   - thunderboltSwitches: the host's TB switch graph. The port's
    ///     active downstream lane link gives the negotiated TB rate. The
    ///     correlation reuses the same `ThunderboltTopology` helpers
    ///     `PortSummary` uses, so the messy switch-tree walk stays in one
    ///     tested place.
    ///   - tbActiveGbps: explicit override for the active TB rate. When
    ///     `nil` it is resolved from `thunderboltSwitches`. Mainly a test
    ///     seam (mirrors `ChargingDiagnostic`'s defaulted `wattageSource`).
    ///   - hostMaxGbps: what this Mac port can do, resolved by the caller.
    ///     Optional: when `nil` the diagnostic tries to infer it from the
    ///     host root Thunderbolt switch's `supportedSpeed` mask. If that
    ///     also fails (non-TB port, switches not yet populated) the host
    ///     stays unknown and the diagnostic never blames it (degrades to
    ///     `unknownCable` / `degraded` instead).
    public init?(
        port: AppleHPMInterface,
        identities: [USBPDSOP],
        devices: [USBDevice],
        usb3Transports: [USB3Transport],
        cio: CIOCableCapability?,
        thunderboltSwitches: [IOThunderboltSwitch] = [],
        tbActiveGbps: Double? = nil,
        hostMaxGbps: Double? = nil
    ) {
        // Resolve the Mac port's capability. Explicit caller value wins
        // (mainly a test seam). Otherwise infer from the host root TB
        // switch's `supportedSpeed` mask. Nil for non-TB USB-C ports.
        let resolvedHostMaxGbps = hostMaxGbps
            ?? Self.hostMaxGbpsFromSwitches(port: port, switches: thunderboltSwitches)
        // Same guard as ChargingDiagnostic: an inactive port can still
        // expose stale link state. Don't diagnose a port that isn't live.
        guard port.connectionActive == true else { return nil }

        // Defence-in-depth (issue #195): refuse the diagnostic on any
        // port that can't host a data link, even if every downstream
        // socket-ID lookup is correctly gated. A future regression that
        // re-introduces an un-gated TB topology lookup would still be
        // caught here. Belt and braces against the same class of bug.
        guard port.carriesData else { return nil }

        // Pick the port's USB 3 transport. Match by identity (UUID-keyed via
        // canonicallyMatches, portKey fallback) so the transport binds to the
        // right physical port; fall back to the only entry if the caller
        // pre-filtered. Only trust the transport's speed when USB3 is in
        // `TransportsActive`: the HPM port controller can leave a stale USB3
        // transport service around when the negotiated link is only USB 2.0
        // (issue #187).
        let usb3 = port.transportsActive.contains("USB3")
            ? (usb3Transports.first { $0.canonicallyMatches(port: port) } ?? usb3Transports.first)
            : nil

        // The speed the link actually negotiated: the Thunderbolt link if
        // there is one, otherwise the USB 3 rate of the Mac-to-first-device
        // link. On a hub that uplink is the only link the cable verdict is
        // about, so we read the directly-attached (root) SuperSpeed device
        // and ignore the slower links living deeper inside the hub. Gated on
        // TransportsActive carrying USB3 (issue #187), mirroring the port
        // summary's own `usb3Speed` resolution.
        let usb3ActiveGbps = port.transportsActive.contains("USB3")
            ? Self.usb3ActiveGbps(usb3: usb3, devices: devices)
            : nil
        let activeGbps = tbActiveGbps
            ?? Self.activeTBGbps(port: port, switches: thunderboltSwitches)
            ?? usb3ActiveGbps

        // Without a known active speed there is no data-speed verdict to
        // give. Returning nil keeps this off ports that are charge-only or
        // where the link state isn't readable yet.
        guard let active = activeGbps else { return nil }

        // TRM (Trust and Restrict Management) short-circuit. When macOS has
        // blocked data on the USB3 transport, the transport's signaling rate
        // is still present (hence `active` is non-nil above) but no data
        // actually flows until the user approves the accessory. Reporting a
        // healthy "Running at X Gbps" verdict in this state is false
        // reassurance (DAR-134). The signaled rate goes into `signaledGbps`
        // so the verdict can say what the link *would* do once approved.
        // This check runs before the cable-speed resolution so it takes
        // precedence over all speed-based verdicts.
        if usb3?.transportRestricted == true,
           let signaledGbps = Self.usb3Gbps(usb3?.signaling) {
            self.cableSignalConflict = false
            self.facts = Facts(
                hostGbps: resolvedHostMaxGbps,
                cableEmarkerGbps: nil,
                cableControllerGbps: nil,
                cableGbps: nil,
                deviceGbps: nil,
                deviceName: nil,
                activeGbps: active
            )
            self.bottleneck = .blockedBySecurity(signaledGbps: signaledGbps)
            self.summary = String(localized: "Data blocked by macOS accessory security", bundle: _coreLocalizedBundle)
            self.detail = String(localized: "The link is capable of \(Self.label(signaledGbps)), but macOS is blocking data until you approve the accessory. Click Allow on the connection prompt, or check System Settings > Privacy & Security > Allow accessories to connect, then replug.", bundle: _coreLocalizedBundle)
            return
        }

        // The Thunderbolt controller's own read of the cable. This is the
        // NEGOTIATED link rate (min of host, cable, device), read from the
        // same lane state as `active`. It is a FLOOR on cable capability,
        // never a cap: a cable can legitimately be faster than the link it
        // happened to run at (issue #393: a genuine 80 Gbps CableMatters
        // TB5 cable between two 40 Gbps endpoints negotiates 40, but it is
        // still an 80 Gbps cable). Only the confirmed codes are mapped;
        // unknown codes stay nil rather than guess (mirrors
        // CIOCableCapability.speedLabel's conservatism).
        let cioGbps = Self.cioCableGbps(cio?.negotiatedLinkSpeed)

        // Cable's claimed speed from its e-marker (SOP' / SOP'').
        let cableIdentity = identities
            .first(where: { $0.endpoint == .sopPrime || $0.endpoint == .sopDoublePrime })
        var emarkerGbps = cableIdentity?.cableVDO?.speed.maxGbps
        // PD spec-revision ambiguity: the e-marker encoding "Gen3" means
        // 20 Gbps under PD 3.0 but 40 Gbps under PD 3.1, and the revision
        // is not readable from the e-marker fields, so the decoder
        // hardcodes 40 (see research/usb-spec-reference.md). When the
        // controller measured the link at 20, the PD 3.0 reading (a real
        // TB3-era 20 Gbps passive cable) is the one consistent with the
        // evidence; assuming 40 here would flag a healthy TB3 cable as
        // "running slower than expected". Resolve the ambiguous claim to
        // the floor's reading.
        if cableIdentity?.cableVDO?.speed == .usb4Gen3, cioGbps == 20 {
            emarkerGbps = 20
        }

        // The e-marker describes what the cable itself claims to support;
        // CIO describes what actually got negotiated. Resolve the two:
        //   - Same tier: agreement, no conflict, take the (equal) value.
        //   - CIO tier HIGHER than the e-marker: the link ran faster than
        //     the cable claims, so the controller has proven the cable
        //     does more than its own e-marker says (issue #111: an active
        //     TB4 cable whose e-marker under-reports as passive/low-speed).
        //     Conflict = true, the controller's higher, confirmed figure
        //     wins.
        //   - CIO tier LOWER than the e-marker: NOT a conflict. Both can
        //     be true at once (the cable claims 80, but only ran at 40
        //     because that's all the floor allowed). The e-marker's claim
        //     is the cable figure here; the negotiated rate already lives
        //     in `active`. (This direction used to be treated as "the
        //     controller always wins", on the theory that a higher
        //     e-marker claim must be a lying cable (issue #190). Issue
        //     #393 proved that assumption wrong for genuine cables: CIO
        //     is a floor, not a ceiling, so a claim above it is not by
        //     itself evidence of anything. Suspicion about a specific
        //     cable is CableTrust's job, not this tiebreak's.)
        //   - Only one signal present: use it, no conflict.
        //   - Neither present: unknown, no conflict.
        let conflict: Bool
        let cableMaxGbps: Double?
        // True when the resolved figure is an e-marker claim that beat a
        // lower CIO floor: an unverified claim, not something the
        // controller actually measured the link doing. Feeds the
        // unknown-endpoint guard further down, which stops that claim
        // alone from producing a false "degraded" verdict.
        let cableClaimAboveCIOFloor: Bool
        switch (emarkerGbps, cioGbps) {
        case let (e?, c?):
            if Self.sameTier(e, c) {
                conflict = false
                cableMaxGbps = max(e, c)
                cableClaimAboveCIOFloor = false
            } else if c > e {
                if Self.sameTier(e, active), !Self.sameTier(c, active) {
                    // Stale-controller guard (restored from the pre-#393
                    // tiebreak). CIO and the TB switch lane state come from
                    // two different IOKit services on two different watcher
                    // streams, so a transient can leave CIO reading higher
                    // than the link that is actually up. When the e-marker
                    // matches the live link and the higher CIO figure does
                    // not, the "controller measured more" story is not
                    // corroborated by the link itself: keep the e-marker's
                    // figure quietly rather than raise a confirmed-conflict
                    // banner from possibly stale data.
                    conflict = false
                    cableMaxGbps = e
                    cableClaimAboveCIOFloor = false
                } else {
                    conflict = true
                    cableMaxGbps = c
                    cableClaimAboveCIOFloor = false
                }
            } else {
                conflict = false
                cableMaxGbps = e
                cableClaimAboveCIOFloor = true
            }
        case let (e?, nil):
            conflict = false
            cableMaxGbps = e
            cableClaimAboveCIOFloor = false
        case let (nil, c?):
            conflict = false
            cableMaxGbps = c
            cableClaimAboveCIOFloor = false
        case (nil, nil):
            conflict = false
            cableMaxGbps = nil
            cableClaimAboveCIOFloor = false
        }
        // Cable / active-rate contradiction detection. When the resolved
        // cable speed is meaningfully below the active rate, one of the
        // two signals is wrong. The earlier silent promotion (issue #195
        // follow-up) assumed the cable e-marker must be the wrong one,
        // which masked legitimate slow cables whenever the active reading
        // was itself unreliable (e.g. a topology leak before the per-port
        // gating in this commit, or any future leak we miss). The honest
        // answer is to surface the contradiction.
        //
        // CIO-confirmed cases are already resolved upstream: whenever CIO
        // is present at all, it's read from the same lane state as
        // `active`, so `cableMaxGbps` can never end up meaningfully below
        // `active` on those cases (whether the CIO tier won on a cross-
        // tier disagreement, or the e-marker's above-floor claim won,
        // which is always >= `active`, never below it). The remaining
        // contradictions are exactly the ones where only the e-marker is
        // available and it disagrees with the active reading by more
        // than a tier.
        let cableContradiction: Bool
        if let c = cableMaxGbps, c < active, !Self.sameTier(c, active), cioGbps == nil {
            cableContradiction = true
        } else {
            cableContradiction = false
        }
        self.cableSignalConflict = conflict

        // The device cap. For a Thunderbolt partner (issue #190) the real
        // capability lives on the partner's own TB switch, not on whatever
        // USB devices happen to be enumerated behind it: a TB dock has an
        // internal USB hub IC at 5/10 Gbps that does NOT represent the
        // dock's actual speed, and a TB-only / SATA-only drive (e.g. LaCie
        // d2) enumerates no USB device at all. When a TB partner is
        // present, USB enumerations behind it are sub-components, so we
        // ignore them and use the partner's `supportedSpeed.maxTotalGbps`
        // mask. If that mask is missing or unrecognised, the active TB
        // link rate is a safe lower bound (the partner must support at
        // least the speed it actually negotiated). The USB device list is
        // consulted only when no TB partner switch is reachable.
        let partner = Self.partnerSwitch(port: port, switches: thunderboltSwitches)
        let fastestDevice = devices
            .filter { $0.speedRaw != nil }
            .max { (Self.deviceGbps($0.speedRaw) ?? 0) < (Self.deviceGbps($1.speedRaw) ?? 0) }
        let usbDeviceGbps = Self.deviceGbps(fastestDevice?.speedRaw)
        let deviceMaxGbps: Double?
        if let partner {
            deviceMaxGbps = partner.supportedSpeed.maxTotalGbps
                ?? Self.activeTBGbps(port: port, switches: thunderboltSwitches)
        } else {
            deviceMaxGbps = usbDeviceGbps
        }

        // Capture the resolved figures for the Pro breakdown. Every
        // constructed instance flows through here (the only earlier return
        // is the no-active-speed guard, which yields no instance).
        let deviceLabel: String?
        if let partner {
            deviceLabel = partner.modelName
        } else {
            deviceLabel = fastestDevice?.productName
        }

        self.facts = Facts(
            hostGbps: resolvedHostMaxGbps,
            cableEmarkerGbps: emarkerGbps,
            cableControllerGbps: cioGbps,
            cableGbps: cableMaxGbps,
            deviceGbps: deviceMaxGbps,
            deviceName: deviceLabel,
            activeGbps: active
        )

        let conflictNote = conflict
            ? " " + String(localized: "The cable's e-marker and the Thunderbolt controller disagree on its speed. The controller measured a higher, confirmed rate, so that figure is used.", bundle: _coreLocalizedBundle)
            : ""

        // Cable / active-rate contradiction short-circuit. When the
        // e-marker claims a speed meaningfully below the active rate and
        // CIO is not available to break the tie, report the contradiction
        // honestly rather than picking a side. Trying a known-good cable
        // is the only reliable way for the user to resolve it.
        if cableContradiction, let cableClaim = cableMaxGbps {
            self.bottleneck = .cableContradictsActive(cableGbps: cableClaim, activeGbps: active)
            self.summary = String(localized: "Cable says \(Self.label(cableClaim)), link reads \(Self.label(active))", bundle: _coreLocalizedBundle)
            self.detail = String(localized: "The cable's e-marker reports \(Self.label(cableClaim)), but the active link is reading \(Self.label(active)). One of those readings is wrong, and without a Thunderbolt controller cross-check we can't tell which. Trying a known-good cable will identify the culprit.", bundle: _coreLocalizedBundle)
            return
        }

        // Every capability we actually know about, tagged by party. The
        // link can never run faster than the slowest of these.
        var caps: [(party: String, value: Double)] = []
        if let c = cableMaxGbps         { caps.append((party: "cable",  value: c)) }
        if let h = resolvedHostMaxGbps  { caps.append((party: "host",   value: h)) }
        if let d = deviceMaxGbps        { caps.append((party: "device", value: d)) }

        guard let expected = caps.map(\.value).min() else {
            // We know the active speed but have nothing to compare it to:
            // no e-marker, no controller data, host unresolved, no device.
            // Don't guess a culprit.
            self.bottleneck = .unknownCable(activeGbps: active)
            self.summary = String(localized: "Running at \(Self.label(active))", bundle: _coreLocalizedBundle)
            self.detail = String(localized: "There's no cable e-marker or controller data, and no port or device capability to compare against, so we can't tell whether the cable is the limit.", bundle: _coreLocalizedBundle)
            return
        }

        if Self.meaningfullySlower(active, than: expected) {
            // Unknown-endpoint guard (issue #393 follow-up). `cableMaxGbps`
            // can now carry a high unverified e-marker claim (rule above)
            // while `active` is lower. If neither the host nor the device
            // is independently known to exceed the active rate, that
            // unverified claim is the ONLY thing making `expected` look
            // higher than what actually ran -- and blaming a "degraded"
            // link on an unverified claim alone would be a false alarm on
            // a perfectly healthy connection (a cable rated for more than
            // its endpoints negotiate is normal, not a fault). When the
            // host or device DOES independently exceed the active rate,
            // this guard does not apply: something demonstrably capable
            // of more really did come up slower, and the degraded verdict
            // below is honest.
            let hostExceedsActive = resolvedHostMaxGbps
                .map { Self.meaningfullySlower(active, than: $0) } ?? false
            let deviceExceedsActive = deviceMaxGbps
                .map { Self.meaningfullySlower(active, than: $0) } ?? false
            if cableClaimAboveCIOFloor, !hostExceedsActive, !deviceExceedsActive,
               let claim = cableMaxGbps {
                self.bottleneck = .unknownCable(activeGbps: active)
                self.summary = String(localized: "Running at \(Self.label(active))", bundle: _coreLocalizedBundle)
                self.detail = String(localized: "The cable claims \(Self.label(claim)), and the link has run at least \(Self.label(active)). There's no host or device data to compare against, so we can't tell if anything else is limiting it.", bundle: _coreLocalizedBundle)
                return
            }

            // Slower than even the slowest part we can see. Something
            // unidentified degraded it. If the cable is the unknown, it's
            // the honest suspect; otherwise it's an unattributed degrade.
            // Either way, never claim "full speed" here (the old draft bug).
            if cableMaxGbps == nil {
                self.bottleneck = .unknownCable(activeGbps: active)
                self.summary = String(localized: "Running at \(Self.label(active))", bundle: _coreLocalizedBundle)
                self.detail = String(localized: "This cable has no e-marker and no controller data, so we can't tell whether it is the limit.", bundle: _coreLocalizedBundle)
            } else {
                self.bottleneck = .degraded(activeGbps: active, expectedGbps: expected)
                self.summary = String(localized: "Running slower than expected (\(Self.label(active)))", bundle: _coreLocalizedBundle)
                self.detail = String(localized: "The parts we can see all support \(Self.label(expected)) or more, but the link came up slower. Reseating the cable or trying another port may help.", bundle: _coreLocalizedBundle) + conflictNote
            }
            return
        }

        // The link is running about as fast as the slowest known part
        // allows. If some other known part is faster, that slowest part is
        // holding it back. If everything known is the same tier, nothing is
        // being limited and the link is fine.
        let limiters = caps.filter { Self.sameTier($0.value, expected) }
        let fasterOthers = caps.filter { Self.meaningfullySlower(expected, than: $0.value) }

        guard !fasterOthers.isEmpty else {
            self.bottleneck = .fine(activeGbps: active)
            self.summary = String(localized: "Running at full data speed (\(Self.label(active)))", bundle: _coreLocalizedBundle)
            self.detail = String(localized: "Nothing is being held back: the parts we can see all support this speed.", bundle: _coreLocalizedBundle) + conflictNote
            return
        }

        // Name the binding part. When only one party is at the floor it is
        // the culprit. When multiple parties tie at the floor (e.g. a TB3
        // device on a TB3-rated cable, both 40 Gbps, with a TB5 host), the
        // priority decides which one we call out. Prefer the non-actionable
        // parts (device, then host) over the cable: if device or host is
        // also at the floor, replacing the cable would not unlock more
        // speed, so "Cable is limiting data speed" would be misleading.
        // The cable wins the call-out only when it is the unique floor.
        let capable = fasterOthers.map(\.value).min() ?? expected
        let priority = ["device", "host", "cable"]
        let culprit = priority.first { p in limiters.contains { $0.party == p } } ?? "device"

        switch culprit {
        case "cable":
            self.bottleneck = .cableLimit(cableGbps: expected, capableGbps: capable)
            self.summary = String(localized: "Cable is limiting data speed", bundle: _coreLocalizedBundle)
            self.detail = String(localized: "The Mac and device can do \(Self.label(capable)), but the cable only carries \(Self.label(expected)). A faster cable would unlock full speed.", bundle: _coreLocalizedBundle) + conflictNote
        case "host":
            self.bottleneck = .hostLimit(hostGbps: expected, capableGbps: capable)
            self.summary = String(localized: "This Mac port limits data speed", bundle: _coreLocalizedBundle)
            self.detail = String(localized: "The cable and device can do \(Self.label(capable)), but this port maxes out at \(Self.label(expected)).", bundle: _coreLocalizedBundle) + conflictNote
        default: // device
            self.bottleneck = .deviceLimit(deviceGbps: expected)
            self.summary = String(localized: "Device runs at \(Self.label(expected))", bundle: _coreLocalizedBundle)
            self.detail = String(localized: "This is the fastest the connected device supports. It is not a cable problem.", bundle: _coreLocalizedBundle) + conflictNote
        }
    }

    // MARK: - Speed resolution helpers

    /// The active Thunderbolt link rate for a port, resolved from the host
    /// switch graph. Reuses the same `ThunderboltTopology` correlation
    /// `PortSummary` uses (socket-ID match -> host root -> active
    /// downstream lane port). Returns `nil` when the port isn't on a TB
    /// link or no link is up.
    ///
    /// Gated on `transportsActive.contains("CIO")`: on Apple Silicon the
    /// internal root-to-downstream-switch lane is always reported as
    /// active even when no user cable is plugged in, so reading the lane
    /// state without a "this port is actually carrying TB" signal would
    /// attribute internal-link speed to the user's cable (issue #195
    /// follow-up: this is what produced the "40 Gbps" reading on a port
    /// holding a USB 2.0 cable). CIO in `transportsActive` is the
    /// authoritative "the user's cable is doing Thunderbolt" signal.
    static func activeTBGbps(
        port: AppleHPMInterface,
        switches: [IOThunderboltSwitch]
    ) -> Double? {
        guard port.transportsActive.contains("CIO"),
              !switches.isEmpty,
              let socketID = ThunderboltTopology.socketID(for: port),
              let root = ThunderboltTopology.hostRoot(forSocketID: socketID, in: switches),
              let hostPort = ThunderboltTopology.activeDownstreamLanePort(root),
              let gen = hostPort.currentSpeed else {
            return nil
        }
        return gen.totalGbps
    }

    /// The Mac port's maximum throughput, taken from the host root TB
    /// switch's `supportedSpeed` mask. This is what the chip can negotiate,
    /// not what is currently active. Returns `nil` for non-TB USB-C ports
    /// (no matching host root) or when the switch graph isn't loaded yet.
    ///
    /// Uses the specific lane port matching the user's socket ID when one
    /// is present, not the switch-level aggregate. On a hypothetical
    /// controller with per-port asymmetric capabilities (e.g. one port
    /// configured for TB5 and another for TB4), the switch aggregate would
    /// overstate the capability of any port that doesn't have every bit.
    /// The per-port mask avoids that. Falls back to the switch aggregate
    /// only when the matched port has no `supportedSpeed` of its own.
    static func hostMaxGbpsFromSwitches(
        port: AppleHPMInterface,
        switches: [IOThunderboltSwitch]
    ) -> Double? {
        guard !switches.isEmpty,
              let socketID = ThunderboltTopology.socketID(for: port),
              let root = ThunderboltTopology.hostRoot(forSocketID: socketID, in: switches) else {
            return nil
        }
        if let portMask = root.ports
            .first(where: { $0.adapterType.isLane && $0.socketID == socketID })?
            .supportedSpeed {
            return portMask.maxTotalGbps
        }
        return root.supportedSpeed.maxTotalGbps
    }

    /// The directly-connected Thunderbolt partner switch for this user-
    /// visible USB-C port, or `nil` when none is reachable.
    ///
    /// Per-port matching is what makes this safe on controllers that host
    /// more than one user-visible USB-C port on a single root switch
    /// (asymmetric M-class controllers, multi-port hubs, etc). The
    /// `parentSwitchUID` guard pins the partner to *this* root. The
    /// `routeString`-low-byte guard pins it to *this* lane port: each hop
    /// in a TB route is one byte; for a depth-1 partner the only hop is
    /// the parent's downstream port number. Matching against
    /// `upstreamPortNumber` would be wrong (that field is the *partner's
    /// own* port number for its upstream link, not the parent's port
    /// number; the Samsung C34J79x fixture in `ThunderboltLinkFromTests`
    /// is the canonical proof of that: parent port 1, partner upstream
    /// port 3).
    static func partnerSwitch(
        port: AppleHPMInterface,
        switches: [IOThunderboltSwitch]
    ) -> IOThunderboltSwitch? {
        guard !switches.isEmpty,
              let socketID = ThunderboltTopology.socketID(for: port),
              let root = ThunderboltTopology.hostRoot(forSocketID: socketID, in: switches),
              let hostLanePort = root.ports.first(where: {
                  $0.adapterType.isLane && $0.socketID == socketID
              }) else {
            return nil
        }
        return switches.first { sw in
            sw.parentSwitchUID == root.id
                && Int(sw.routeString & 0xFF) == hostLanePort.portNumber
        }
    }

    /// USB 3 signaling generation to Gbps. 1 = Gen 1 (5), 2 = Gen 2 (10).
    static func usb3Gbps(_ signaling: Int?) -> Double? {
        switch signaling {
        case 1: return 5
        case 2: return 10
        default: return nil
        }
    }

    /// The negotiated USB 3 rate of the Mac-to-first-device link, in Gbps.
    ///
    /// On a hub, the directly-attached (root) SuperSpeed device is the
    /// Mac-to-hub uplink, the only link the cable verdict is about. Slower
    /// SuperSpeed links deeper inside the hub (a secondary 5 Gbps hub, a
    /// card reader) are the hub's internal wiring, not the cable, so they
    /// must not set the port's headline speed. We therefore prefer the root
    /// device's enumerated speed, then fall back to the controller's USB3
    /// transport signaling, then the port-name-matched device, exactly
    /// matching the source order `JSONFormatter`/`PortSummary` use for
    /// `usb3Speed`, so the headline and the bullet can never disagree
    /// (issue #245).
    ///
    /// The caller gates on `TransportsActive` carrying USB3 (issue #187: the
    /// controller can leave a stale SuperSpeed transport/device registered
    /// on a link that is really USB 2.0); this helper assumes USB3 is live.
    static func usb3ActiveGbps(usb3: USB3Transport?, devices: [USBDevice]) -> Double? {
        if let root = USBDevice.rootSuperSpeed(in: devices),
           let gbps = Self.deviceGbps(root.speedRaw) {
            return gbps
        }
        if let signaled = Self.usb3Gbps(usb3?.signaling) {
            return signaled
        }
        if let matched = USBDevice.portMatchedSuperSpeed(in: devices),
           let gbps = Self.deviceGbps(matched.speedRaw) {
            return gbps
        }
        return nil
    }

    /// CIO controller cable-speed code to Gbps. Confirmed codes:
    /// 2 = TB3 / 20, 3 = TB4 / 40, 4 = TB5 / 80.
    static func cioCableGbps(_ code: Int?) -> Double? {
        switch code {
        case 2: return 20
        case 3: return 40
        case 4: return 80
        default: return nil
        }
    }

    /// USB device "Device Speed" enum to Gbps. Mirrors USBDevice.speedLabel.
    static func deviceGbps(_ speedRaw: UInt8?) -> Double? {
        switch speedRaw {
        case 0: return 0.0015   // Low Speed   1.5 Mbps
        case 1: return 0.012    // Full Speed  12 Mbps
        case 2: return 0.48     // High Speed  480 Mbps
        case 3: return 5        // SuperSpeed  5 Gbps
        case 4: return 10       // SuperSpeed+ 10 Gbps
        case 5: return 20       // Gen 2x2     20 Gbps
        default: return nil
        }
    }

    /// Speeds come in well-separated tiers (0.48 / 5 / 10 / 20 / 40 / 80),
    /// so a 10% band is plenty to absorb rounding without merging tiers.
    static func sameTier(_ a: Double, _ b: Double) -> Bool {
        guard a > 0, b > 0 else { return a == b }
        let ratio = a / b
        return ratio >= 0.9 && ratio <= 1.111
    }

    /// `a` is meaningfully slower than `b` (more than ~10% below it).
    static func meaningfullySlower(_ a: Double, than b: Double) -> Bool {
        a < b * 0.9
    }

    /// Human-readable speed: sub-1-Gbps as Mbps, whole numbers without ".0".
    static func label(_ gbps: Double) -> String {
        if gbps < 1 {
            return "\(Int((gbps * 1000).rounded())) Mbps"
        }
        if gbps.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(gbps)) Gbps"
        }
        return "\(gbps) Gbps"
    }
}
