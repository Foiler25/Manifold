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
public import Combine
import IOKit

@MainActor
public final class PowerTelemetryWatcher: ObservableObject {
    @Published public private(set) var latestSnapshot: PowerMonitorSnapshot?

    public let snapshots: AsyncStream<PowerMonitorSnapshot>

    private var continuation: AsyncStream<PowerMonitorSnapshot>.Continuation?
    private var pollTask: Task<Void, Never>?
    private var accumulator = RegressionAccumulator()
    private var cachedPortKeys: [String]?
    // Desktop per-port power lives in the SMC, not IOKit. The reader is opened
    // lazily on the first desktop refresh; the UUID map ties each SMC channel
    // to its physical port. Both are unused on laptops (battery present).
    private let smcReader = SMCPowerReader()
    private var cachedUUIDMap: [String: String]?

    public init() {
        var continuation: AsyncStream<PowerMonitorSnapshot>.Continuation?
        snapshots = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func start() {
        guard pollTask == nil else { return }
        cachedPortKeys = Self.hpmPortKeys()
        // Store nil (not an empty map) when the lookup comes back empty, so the
        // desktop path below re-fetches rather than negative-caching "no ports"
        // for the whole session.
        let uuidMap = HPMPortUUIDMap.current()
        cachedUUIDMap = uuidMap.isEmpty ? nil : uuidMap
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                refresh()
                // 1s for a snappier live monitor. Only runs while the Power
                // Monitor window (or `whatcable --monitor`) is open, so the
                // extra IOKit reads are bounded to that session.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        accumulator.reset()
        cachedPortKeys = nil
        cachedUUIDMap = nil
        smcReader.close()
        latestSnapshot = nil
    }

    /// Updates the cached UUID-to-portKey map from already-captured HPM port
    /// data. Call this whenever the `AppleHPMInterfaceWatcher` publishes a
    /// fresh port list so the telemetry watcher uses the live-captured UUIDs
    /// instead of performing a redundant IOKit sweep via `HPMPortUUIDMap.current()`.
    ///
    /// When the supplied ports carry UUIDs (M3+) the map is rebuilt from them.
    /// When no UUIDs are present (M1/M2 or empty list) the existing cached map
    /// is left untouched so a valid map captured at `start()` is not evicted.
    public func updatePorts(_ ports: [AppleHPMInterface]) {
        let map = HPMPortUUIDMap.from(ports: ports)
        if !map.isEmpty {
            cachedUUIDMap = map
        }
    }

    /// Discards the accumulated regression samples so the resistance estimate
    /// rebuilds from scratch. Call this when the charging cable changes outside
    /// of a PD renegotiation: the accumulator auto-resets on contract fingerprint
    /// change, but an explicit reset is provided for cases (e.g. the session
    /// monitor's cable-swap detection) where the caller needs the buffer cleared
    /// immediately. The next `refresh()` returns an `insufficient` estimate until
    /// enough new samples accumulate.
    public func resetResistanceBaseline() {
        accumulator.reset()
    }

    public func refresh() {
        let timestamp = Date()
        // Optional now: desktop Macs (Mac mini / Studio / Pro) may have no
        // AppleSmartBattery node at all. The old early-return on a missing node
        // is what left the Power Monitor spinning forever there (#285). We now
        // always emit a snapshot and fill per-port data from the SMC instead.
        let dict = Self.appleSmartBatteryProperties()
        let telemetry = wcDictionary(dict?["PowerTelemetryData"])
        // On a laptop this comes from the battery controller. On a desktop the
        // battery telemetry is absent, so every field is 0; the desktop branch
        // below overrides it from the SMC's DC-in rail.
        var system = PowerSample(
            timestamp: timestamp,
            systemVoltageIn: wcInt(telemetry["SystemVoltageIn"]),
            systemCurrentIn: wcInt(telemetry["SystemCurrentIn"]),
            systemPowerIn: wcInt(telemetry["SystemPowerIn"])
        )

        let portKeys = cachedPortKeys ?? []
        // The contracted per-port data is attributed from the self-keyed power
        // sources (IOPortFeaturePowerSource), which state the port outright.
        // PortControllerInfo (an unlabelled array inside AppleSmartBattery) only
        // enriches the decoded volts/amps, matched by watts; it never assigns a
        // port. The old code keyed it by array offset, which landed a charger's
        // watts on the wrong port's card.
        let sources = PowerSourceWatcher.readAllPowerSources()
        // Per-port power-out, live-first. Priority: live SMC channel (M3+) >
        // PowerOutDetails > contracted controller info. PowerOutDetails is the
        // AppleSmartBattery per-port array, and it is FROZEN under load on Apple
        // Silicon (confirmed M5 Pro 2026-06-15: an iPad charging on @1 held
        // PowerOutDetails at 6098 mW for 20 s while the SMC channel tracked the
        // real 6.6-7.5 W draw). So the live SMC value wins wherever a channel
        // resolves to a port by controller UUID; PowerOutDetails and the
        // source-attributed contract only fill ports the SMC did not resolve
        // (M1/M2, App Store sandbox, or a port with no SMC channel). The fill
        // happens after the SMC block below.
        var portSamples: [PortPowerSample] = []
        var coveredKeys = Set<String>()

        let batteryInstalled = wcBool(dict?["BatteryInstalled"])
        // ExternalConnected: bound once here and reused below (the system-input
        // override, the on-battery discharge gate, and the hasContract gate).
        // Defaults true so a desktop, which has no battery node, reads as plugged
        // in.
        let externalConnected = dict.map { wcBool($0["ExternalConnected"]) } ?? true

        // System power input (the charger / PSU feeding the logic board). The
        // telemetry SystemPowerIn built above comes from AppleSmartBattery, which
        // does not update under load on Apple Silicon (it sits stale). The SMC
        // DC-in rail (VD0R / ID0R / PDTR) is live (~1 Hz), so override with it
        // whenever externally powered: a desktop always is; a plugged-in laptop
        // too. On battery there is no input to show (the discharge figure below
        // drives the card instead). This also fixes the desktop input card, which
        // used to stay 0 and spin on "Negotiating…" forever (#291).
        if externalConnected, let input = smcReader.readSystemPowerInput() {
            system = Self.smcSystemSample(input, timestamp: timestamp)
        }

        // Per-port power-OUT from the SMC, tied to each physical port by
        // controller UUID (M3+). This runs on laptops and desktops alike: the
        // SMC is the only LIVE per-port source (PowerOutDetails is frozen, see
        // above). An empty UUID map (M1/M2, where the stable UUID is absent, or a
        // Mac Pro) skips this entirely: we never guess a positional mapping, we
        // fall through to PowerOutDetails below.
        //
        // The cache only ever holds a non-empty map (see start()), so a nil cache
        // means "not looked up yet, or last lookup was empty": re-fetch and cache
        // a non-empty result. On M1/M2 (no UUID) this stays empty and is
        // re-fetched each tick, which is cheap.
        let uuidMap: [String: String]
        if let cachedUUIDMap {
            uuidMap = cachedUUIDMap
        } else {
            uuidMap = HPMPortUUIDMap.current()
            if !uuidMap.isEmpty { cachedUUIDMap = uuidMap }
        }
        // Channels carry a UUID even when idle (present=false, 0 W). We only
        // declare per-port metering supported when at least one SMC channel
        // actually resolves to a known port via the UUID map. An empty map means
        // M1/M2 or Mac Pro (no resolvable per-port SMC channels). A non-empty map
        // with zero matching channels means the UUID map and SMC channel set
        // don't overlap, which should not happen on real hardware but guards
        // against the Power Monitor spinning on "Negotiating forever" (#291).
        // Empty map (M1/M2, Mac Pro) short-circuits the SMC read entirely.
        let channels = uuidMap.isEmpty ? [] : smcReader.readPortPowerChannels()
        var matchedChannels = 0
        for channel in channels {
            guard let key = uuidMap[channel.uuid] else { continue }
            matchedChannels += 1
            guard (channel.present || channel.watts > 0.001), !coveredKeys.contains(key) else { continue }
            portSamples.append(Self.smcPortSample(channel: channel, portKey: key))
            coveredKeys.insert(key)
        }
        // Supported only when SMC channels actually resolved to ports.
        let perPortMeteringSupported = matchedChannels > 0

        // Display fill: SMC won above, now PowerOutDetails fills the ports it did
        // not cover (frozen, but correct where nothing newer exists), then the
        // source-attributed contract (MagSafe and contracted ports), each on the
        // correct port. So the displayed list is SMC-first, then these two.
        let podSamples = Self.portPowerSamples(from: dict?["PowerOutDetails"], portKeys: portKeys)
        for sample in podSamples where !coveredKeys.contains(sample.portKey) {
            portSamples.append(sample)
            coveredKeys.insert(sample.portKey)
        }
        let controllerSamples = Self.portPowerSamplesFromControllerInfo(dict?["PortControllerInfo"], sources: sources)
        for sample in controllerSamples where !coveredKeys.contains(sample.portKey) {
            portSamples.append(sample)
            coveredKeys.insert(sample.portKey)
        }

        // The cable-resistance estimate is fed from the metered contract samples
        // (PowerOutDetails + contracted controller info), NOT the SMC-first
        // display list. The estimate regresses the cable's voltage drop
        // (ConfiguredVoltage - AdapterVoltage) against current, and only
        // PowerOutDetails carries that AdapterVoltage. An SMC sample has no
        // AdapterVoltage (0) so it yields no usable point, and its live-jittering
        // measured voltage would thrash the contract fingerprint each tick and
        // starve the estimate. Building this list POD-first (the pre-SMC merge)
        // keeps laptops working and removes SMC samples that desktops used to
        // feed in regardless.
        var meteredSamples = podSamples
        let meteredKeys = Set(podSamples.map(\.portKey))
        for sample in controllerSamples where !meteredKeys.contains(sample.portKey) {
            meteredSamples.append(sample)
        }
        accumulator.append(portSamples: meteredSamples)
        // Battery discharge, so the System Power card keeps tracking on battery.
        // Voltage is the pack voltage.
        let batteryVoltageMV = wcInt(dict?["Voltage"])
        let reportedBatteryPower = abs(wcInt(telemetry["BatteryPower"]))
        let gaugeBatteryPower = reportedBatteryPower != 0 ? reportedBatteryPower : wcInt(telemetry["SystemLoad"])
        // AppleSmartBattery's BatteryPower / SystemLoad do not update under load
        // on Apple Silicon (the fuel gauge holds a value for tens of seconds), so
        // a discharge figure read from there sits stale. The SMC battery rail
        // (PPBR) is live (updates ~1 Hz, tracks load), so prefer it when on
        // battery; fall back to the gauge when the SMC is unavailable or the key
        // is absent. `open()` inside the reader is lazy and idempotent.
        let onBattery = batteryInstalled && !externalConnected
        let liveBatteryPower = onBattery ? smcReader.readBatteryPowerMW() : nil
        let batteryPowerMW = liveBatteryPower ?? gaugeBatteryPower
        // Pack current. Apple Silicon usually reports 0 for Amperage /
        // InstantAmperage, and when we are on the live SMC power the gauge current
        // would be stale anyway, so derive current from the (live) power and pack
        // voltage: P = V x I, hence I[mA] = P[mW] x 1000 / V[mV]. Exact, and
        // consistent with the displayed P and V. Only when falling back to the
        // gauge do we use a non-zero measured current if the gauge reports one.
        let instant = wcInt(dict?["InstantAmperage"])
        let measuredCurrent = abs(instant != 0 ? instant : wcInt(dict?["Amperage"]))
        let derivedCurrent = batteryVoltageMV > 0 ? batteryPowerMW * 1000 / batteryVoltageMV : 0
        let batteryCurrentMA = (liveBatteryPower == nil && measuredCurrent != 0)
            ? measuredCurrent
            : derivedCurrent
        // hasContract is gated on a live connection (externalConnected, bound
        // above): a winning contract can linger for a moment after unplug on this
        // stack, and only means anything while a charger is actually plugged in.
        let snapshot = PowerMonitorSnapshot(
            timestamp: timestamp,
            systemSample: system,
            portSamples: portSamples,
            resistanceEstimate: resistanceEstimate(),
            externalConnected: externalConnected,
            batteryInstalled: batteryInstalled,
            batteryVoltageMV: batteryVoltageMV,
            batteryCurrentMA: batteryCurrentMA,
            batteryPowerMW: batteryPowerMW,
            hasContract: externalConnected && sources.contains { $0.winning != nil },
            perPortMeteringSupported: perPortMeteringSupported
        )
        latestSnapshot = snapshot
        continuation?.yield(snapshot)
    }

    /// Builds a live per-port sample from one SMC power channel, already tied to
    /// its physical port key by controller UUID. Marked `isSMCMeasured` so the
    /// UI trusts it as proof the port is live (desktops have no power-source
    /// tree to corroborate it).
    nonisolated static func smcPortSample(channel: SMCPortPowerChannel, portKey: String) -> PortPowerSample {
        let portNumber = Int(portKey.split(separator: "/").last.map(String.init) ?? "") ?? 0
        let voltageMV = Int((channel.volts * 1000).rounded())
        let currentMA = Int((channel.amps * 1000).rounded())
        let wattsMW = Int((channel.watts * 1000).rounded())
        return PortPowerSample(
            portIndex: portNumber,
            portKey: portKey,
            current: currentMA,
            watts: wattsMW,
            configuredVoltage: voltageMV,
            configuredCurrent: currentMA,
            adapterVoltage: 0,
            vconnCurrent: 0,
            vconnPower: 0,
            isSMCMeasured: true
        )
    }

    /// Converts an SMC DC-in reading (volts / amps / watts) into the System
    /// Power sample the UI expects, which is in mV / mA / mW. A static seam so
    /// the conversion is unit-testable without live IOKit.
    nonisolated static func smcSystemSample(_ input: SMCSystemPowerInput, timestamp: Date) -> PowerSample {
        PowerSample(
            timestamp: timestamp,
            systemVoltageIn: Int((input.volts * 1000).rounded()),
            systemCurrentIn: Int((input.amps * 1000).rounded()),
            systemPowerIn: Int((input.watts * 1000).rounded())
        )
    }

    private func resistanceEstimate() -> CableResistanceEstimate? {
        let samples = accumulator.samples.filter { $0.current > 0 }
        guard samples.count >= 10 else {
            return CableResistanceEstimate(
                milliohms: 0,
                sampleCount: samples.count,
                rSquared: 0,
                status: .insufficient
            )
        }

        let minCurrent = samples.map(\.current).min() ?? 0
        let maxCurrent = samples.map(\.current).max() ?? 0
        guard maxCurrent - minCurrent > 200 else {
            return CableResistanceEstimate(
                milliohms: 0,
                sampleCount: samples.count,
                rSquared: 0,
                status: .unreliable
            )
        }

        let count = Double(samples.count)
        let meanCurrent = samples.reduce(0) { $0 + $1.current } / count
        let meanDrop = samples.reduce(0) { $0 + $1.voltageDrop } / count
        let sxx = samples.reduce(0) { $0 + pow($1.current - meanCurrent, 2) }
        guard sxx > 0 else {
            return CableResistanceEstimate(
                milliohms: 0,
                sampleCount: samples.count,
                rSquared: 0,
                status: .unreliable
            )
        }

        let sxy = samples.reduce(0) { $0 + (($1.current - meanCurrent) * ($1.voltageDrop - meanDrop)) }
        let slope = sxy / sxx
        let intercept = meanDrop - slope * meanCurrent
        let total = samples.reduce(0) { $0 + pow($1.voltageDrop - meanDrop, 2) }
        let residual = samples.reduce(0) {
            let predicted = slope * $1.current + intercept
            return $0 + pow($1.voltageDrop - predicted, 2)
        }
        let rSquared = total > 0 ? max(0, 1 - residual / total) : 0
        let status: CableResistanceEstimate.Status
        if samples.count < 30 {
            status = .converging
        } else if rSquared >= 0.7 {
            status = .stable
        } else {
            status = .unreliable
        }

        return CableResistanceEstimate(
            milliohms: max(0, slope * 1000),
            sampleCount: samples.count,
            rSquared: rSquared,
            status: status
        )
    }

    // Internal (not private) so tests can call it directly without live IOKit.
    // The logic is pure: no IOKit, no MainActor. nonisolated so it is callable
    // from non-isolated test code without wrapping in a Task.
    nonisolated static func portPowerSamples(from value: Any?, portKeys: [String]) -> [PortPowerSample] {
        wcArray(value).enumerated().compactMap { offset, item in
            let dict = wcDictionary(item)
            guard !dict.isEmpty else { return nil }
            let rawPortIndex = wcInt(dict["PortIndex"])
            let effectiveIndex = rawPortIndex > 0 ? rawPortIndex : offset + 1
            // PowerOutDetails entries carry their own PortIndex. Match
            // against the number component of portKeys (the part after "/")
            // rather than using the array offset, because PowerOutDetails
            // order doesn't match HPM traversal order.
            // PowerOutDetails only contains USB-C ports, so default to "2/".
            let key: String
            if rawPortIndex > 0,
               let match = portKeys.first(where: { $0.hasSuffix("/\(rawPortIndex)") && !$0.hasPrefix("17/") }) {
                key = match
            } else if rawPortIndex > 0 {
                key = "2/\(rawPortIndex)"
            } else {
                key = "2/\(offset + 1)"
            }
            return PortPowerSample(
                portIndex: effectiveIndex,
                portKey: key,
                current: wcInt(dict["Current"]),
                watts: wcInt(dict["Watts"]),
                configuredVoltage: wcInt(dict["ConfiguredVoltage"]),
                configuredCurrent: wcInt(dict["ConfiguredCurrent"]),
                adapterVoltage: wcInt(dict["AdapterVoltage"]),
                vconnCurrent: wcInt(dict["VConnCurrent"]),
                vconnPower: wcInt(dict["VConnPower"]),
                filteredPower: wcInt(dict["FilteredPower"]),
                pdPowerMW: wcInt(dict["PDPowermW"]),
                vconnMaxCurrent: wcInt(dict["VConnMaxCurrent"]),
                accumulatedPower: wcInt(dict["AccumulatedPower"]),
                accumulatorCount: wcInt(dict["AccumulatorCount"]),
                accumulatorErrorCount: wcInt(dict["AccumulatorErrorCount"]),
                vconnAccumulatedPower: wcInt(dict["VConnAccumulatedPower"]),
                vconnAccumulatorCount: wcInt(dict["VConnAccumulatorCount"]),
                vconnAccumulatorErrorCount: wcInt(dict["VConnAccumulatorErrorCount"]),
                numLDCMCollisions: wcInt(dict["NumLDCMCollisions"]),
                usbSleepPoolPowerMW: wcInt(dict["USBSleepPoolPowermW"]),
                usbWakePoolPowerMW: wcInt(dict["USBWakePoolPowermW"]),
                powerState: wcInt(dict["PowerState"]),
                portType: wcInt(dict["PortType"])
            )
        }
    }

    /// Build one contracted power sample per port that has a winning power
    /// source. The port, watts, and a baseline voltage/current come from the
    /// self-keyed source (`IOPortFeaturePowerSource`), which states the port
    /// outright, so a contract can never land on the wrong port.
    ///
    /// `PortControllerInfo` (the unlabelled array inside `AppleSmartBattery`)
    /// is used only to *enrich* the decoded volts/amps. Its items carry no port
    /// id, so each is matched to its port by watts (`PowerControllerPortJoin`)
    /// and its PDO decode is preferred where present, because it recovers the
    /// exact negotiated tier even where the source's winning PDO is coarse
    /// (e.g. MagSafe). No match, or an ambiguous one, falls back to the
    /// source's own winning figures: never a guessed key.
    nonisolated static func portPowerSamplesFromControllerInfo(_ controllerInfo: Any?, sources: [PowerSource]) -> [PortPowerSample] {
        let items = wcArray(controllerInfo)
        let maxPowers = items.map { wcInt(wcDictionary($0)["PortControllerMaxPower"]) }
        let joinByIndex = PowerControllerPortJoin.portKeysByContent(
            controllerMaxPowerMW: maxPowers,
            sources: sources
        )

        return Dictionary(grouping: sources, by: \.portKey).compactMap { portKey, portSources -> PortPowerSample? in
            guard let source = PowerSource.preferredChargingSource(in: portSources) ?? portSources.first,
                  let winning = source.winning, winning.maxPowerMW > 0 else { return nil }

            var voltage = winning.voltageMV
            var current = winning.maxCurrentMA

            // Enrichment: the PortControllerInfo item watts-matched to this port
            // (if any) carries the precisely decoded contract. Prefer it; the
            // source's winning figures are the fallback.
            if let index = joinByIndex.first(where: { $0.value == portKey })?.key {
                let dict = wcDictionary(items[index])
                let rdo = UInt32(bitPattern: Int32(truncatingIfNeeded: wcInt(dict["PortControllerActiveContractRdo"])))
                // The operating-current field (bits 19:10, 10 mA units) is only
                // valid for Fixed/Variable PDOs. Battery PDOs encode power in
                // 250 mW units there; PPS/AVS APDOs encode output voltage. Pass 0
                // for non-Fixed contracts so the tie-breaker inside
                // decodeNegotiatedContract falls back to the highest-voltage pick
                // rather than matching a mis-scaled value.
                let selectedPdoType = rdoSelectedPdoType(rdo: rdo, pdoList: dict["PortControllerPortPDO"])
                let operatingCurrent = selectedPdoType == .fixedOrVariable ? Int((rdo >> 10) & 0x3FF) * 10 : 0
                if let negotiated = decodeNegotiatedContract(
                    pdoList: dict["PortControllerPortPDO"],
                    maxPowerMW: wcInt(dict["PortControllerMaxPower"]),
                    operatingCurrentMA: operatingCurrent
                ) {
                    voltage = negotiated.voltageMV
                    current = negotiated.currentMA
                }
            }

            let portNumber = Int(portKey.split(separator: "/").last.map(String.init) ?? "") ?? 0
            return PortPowerSample(
                portIndex: portNumber,
                portKey: portKey,
                current: current,
                watts: winning.maxPowerMW,
                configuredVoltage: voltage,
                configuredCurrent: current,
                adapterVoltage: 0,
                vconnCurrent: 0,
                vconnPower: 0,
                isContractedFallback: true
            )
        }
    }

    /// Decodes the negotiated fixed-supply PD contract from a port's source
    /// PDO list. Picks the fixed PDO whose power is closest to `maxPowerMW`
    /// (the authoritative contracted max), because the RDO object-position
    /// field is wrong for MagSafe. A charger can offer two PDOs at the same
    /// wattage (e.g. a 45W brick advertises both 15V/3A and 20V/2.25A); that
    /// tie is broken with the RDO operating current, then by preferring the
    /// higher voltage. Returns nil when there is no PDO list, no fixed PDO,
    /// or no usable max-power reference, so callers leave voltage at 0
    /// rather than inventing one.
    nonisolated static func decodeNegotiatedContract(
        pdoList: Any?,
        maxPowerMW: Int,
        operatingCurrentMA: Int
    ) -> (voltageMV: Int, currentMA: Int)? {
        guard maxPowerMW > 0 else { return nil }
        let pdos = wcArray(pdoList)
        guard !pdos.isEmpty else { return nil }

        var candidates: [(voltageMV: Int, currentMA: Int, deltaMW: Int)] = []
        for entry in pdos {
            let pdo = wcUInt32(entry)
            guard pdo != 0 else { continue }
            // Fixed-supply PDOs have bits 31:30 == 00. Battery, variable,
            // and augmented/PPS PDOs don't carry a plain fixed voltage.
            guard (pdo >> 30) & 0x3 == 0 else { continue }
            // Fixed PDO: voltage in 50 mV units (bits 19:10), max current
            // in 10 mA units (bits 9:0).
            let voltageMV = Int((pdo >> 10) & 0x3FF) * 50
            let currentMA = Int(pdo & 0x3FF) * 10
            guard voltageMV > 0, currentMA > 0 else { continue }
            let powerMW = voltageMV * currentMA / 1000
            candidates.append((voltageMV, currentMA, abs(powerMW - maxPowerMW)))
        }
        guard let minDelta = candidates.map(\.deltaMW).min() else { return nil }
        let tied = candidates.filter { $0.deltaMW == minDelta }
        if tied.count == 1 {
            return (tied[0].voltageMV, tied[0].currentMA)
        }
        // Tie: the RDO operating current pins the actual PDO (it matches the
        // selected PDO's max current). If that doesn't single one out, the
        // Mac negotiates the highest voltage tier at a given wattage.
        if operatingCurrentMA > 0,
           let match = tied.first(where: { $0.currentMA == operatingCurrentMA }) {
            return (match.voltageMV, match.currentMA)
        }
        // tied.count >= 2 here (count == 1 returned above), so max(by:) is
        // guaranteed to return a value; the guard is defensive documentation.
        guard let pick = tied.max(by: { $0.voltageMV < $1.voltageMV }) else { return nil }
        return (pick.voltageMV, pick.currentMA)
    }

    // Classifies the PDO type that an RDO selects, for safe field extraction.
    // The object position is bits 30:28 of the RDO; position 0 means no active
    // contract. Returns .fixedOrVariable when the position is out of range or
    // the PDO list is empty, since Fixed is the only type seen in captured data
    // and the Fixed path is always safe as a fallback.
    enum SelectedPdoType { case fixedOrVariable, battery, apdo }
    nonisolated static func rdoSelectedPdoType(rdo: UInt32, pdoList: Any?) -> SelectedPdoType {
        let position = Int((rdo >> 28) & 0x7)
        let idx = position - 1
        let pdos = wcArray(pdoList)
        guard idx >= 0, idx < pdos.count else { return .fixedOrVariable }
        let raw = wcUInt32(pdos[idx])
        switch (raw >> 30) & 0x3 {
        case 1: return .battery
        case 3: return .apdo
        default: return .fixedOrVariable
        }
    }

    // Walks HPM port-controller services in IOKit registry order and returns
    // a portKey ("portType/portNumber") for each. The order matches the
    // PortControllerInfo array in AppleSmartBattery because both are populated
    // from the same HPM controllers in the same traversal order.
    public nonisolated static func hpmPortKeys() -> [String] {
        let classes = [
            "AppleHPMInterfaceType10",
            "AppleHPMInterfaceType11",
            "AppleHPMInterfaceType12",
            "AppleHPMInterfaceType18",
            "AppleTCControllerType10",
            "AppleTCControllerType11",
        ]
        var keys: [String] = []
        for cls in classes {
            var iter: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &iter) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(iter) }
            while case let service = IOIteratorNext(iter), service != 0 {
                defer { IOObjectRelease(service) }
                func read(_ key: String) -> Any? {
                    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                }
                let portType = read("PortTypeDescription") as? String
                let isRealPort = (portType == "USB-C" || portType?.hasPrefix("MagSafe") == true)
                guard isRealPort else { continue }
                let portNumber = wcPortIndex(read: read, service: service)
                guard portNumber != 0 else { continue }
                let rawType: Int
                if portType?.hasPrefix("MagSafe") == true {
                    rawType = 0x11
                } else {
                    rawType = (read("PortType") as? Int) ?? 0x2
                }
                let key = "\(rawType)/\(portNumber)"
                if !keys.contains(key) {
                    keys.append(key)
                }
            }
        }
        return keys
    }

    public nonisolated static func appleSmartBatteryProperties() -> [String: Any]? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"), &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }

        while case let service = IOIteratorNext(iter), service != 0 {
            defer { IOObjectRelease(service) }
            // The bulk fetch is intentional: this function returns the entire raw
            // property dict to the diagnostics layer. The caller enumerates keys
            // it doesn't know in advance, so per-key reads are not feasible.
            // AppleSmartBattery is a persistent service; it is never being torn
            // down mid-read, so the IOCFUnserializeBinary crash path (issue #181)
            // does not apply here.
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else {
                continue
            }
            return dict
        }
        return nil
    }
}
