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

/// Snapshot of the other watchers `PowerSourceWatcher.refresh()` needs in
/// order to attempt `PowerSourceSynthesis` (issue #401: M1 Pro/Max/Ultra
/// never publish a real `IOPortFeaturePowerSource` node for USB-C). Built by
/// whichever owner constructs this watcher alongside a port watcher and an
/// identity watcher; supplied via `PowerSourceWatcher.synthesisContext`.
public struct PowerSourceSynthesisContext {
    public let ports: [AppleHPMInterface]
    public let identities: [USBPDSOP]
    /// Port keys in HPM traversal order, matching the order Apple builds
    /// `PortControllerInfo` in. See `PowerTelemetryWatcher.hpmPortKeys()`.
    ///
    /// Lazy on purpose: `hpmPortKeys()` walks six IOKit service classes, so
    /// it must only run on the rare tick that's actually about to attempt
    /// synthesis, not on every `refresh()` call. `synthesizeIfNeeded` only
    /// evaluates this closure right before calling
    /// `PowerSourceSynthesis.synthesizedSource`, after every cheaper gate
    /// has already passed.
    public let positionalPortKeys: () -> [String]

    public init(ports: [AppleHPMInterface], identities: [USBPDSOP], positionalPortKeys: @escaping () -> [String]) {
        self.ports = ports
        self.identities = identities
        self.positionalPortKeys = positionalPortKeys
    }
}

/// Watches `IOPortFeaturePowerSource` services. These appear under each port's
/// `Power In` feature when something that advertises PD is connected.
@MainActor
public final class PowerSourceWatcher: ObservableObject {
    @Published public private(set) var sources: [PowerSource] = []

    /// Injected by the owner (`CableDarwinProvider`) so
    /// `refresh()` can synthesize a per-port source when macOS publishes none
    /// (M1 Pro/Max/Ultra USB-C, issue #401). Returns nil when the owner has
    /// no port/identity watchers to draw from, in which case `refresh()`
    /// skips synthesis entirely and behaves exactly as before.
    public var synthesisContext: (() -> PowerSourceSynthesisContext?)?

    /// Live charger-in wattage for the menu bar readout. Recomputed on the hub's
    /// poll cadence (1 Hz while a UI surface is visible, 30 s idle) and on each
    /// system power-source change notification, so the number stays fresh between
    /// idle polls without a separate per-second timer. 0 on battery or when
    /// nothing is readable. Only populated while ``readsChargerInputWatts`` is on.
    @Published public private(set) var chargerInputWatts: Int = 0

    /// The connected charger's rated wattage (its maximum, e.g. 70), used as the
    /// denominator for the menu bar power bar. 0 on battery or when the adapter
    /// doesn't report a rating. Published alongside `chargerInputWatts` on the
    /// same cadence and gate.
    @Published public private(set) var chargerRatedWatts: Int = 0

    /// Whether each refresh should also read the live charger-in wattage. Off by
    /// default, so the common case (menu bar watts readout disabled) does no
    /// SMC / battery read at all. The app turns this on only while the readout is
    /// shown. Flipping it on computes once immediately so the label paints without
    /// waiting for the next poll; flipping it off clears the value.
    public var readsChargerInputWatts = false {
        didSet {
            guard readsChargerInputWatts != oldValue else { return }
            if readsChargerInputWatts {
                startPowerSourceNotification()
                refreshChargerInputWatts()
            } else {
                stopPowerSourceNotification()
                if chargerInputWatts != 0 { chargerInputWatts = 0 }
                if chargerRatedWatts != 0 { chargerRatedWatts = 0 }
            }
        }
    }

    /// Reads the live SMC DC-in rail. Held once and reused (its `open()` is lazy
    /// and idempotent) so the per-tick read doesn't churn the AppleSMC user client.
    private let smcReader = SMCPowerReader()

    private var notifyPort: IONotificationPortRef?
    private var addedIter: io_iterator_t = 0
    private var removedIter: io_iterator_t = 0

    /// System power-source change notification. Fires the watts recompute on a
    /// real charging change (charge ramp near full, charger swap) so the menu bar
    /// number stays fresh between the hub's idle (30 s) polls without a 1 Hz
    /// timer. Only registered while ``readsChargerInputWatts`` is on, so the
    /// readout-off majority schedules nothing.
    private var powerSourceRunLoopSource: CFRunLoopSource?

    public init() {}

    public func start() {
        guard notifyPort == nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let added: IOServiceMatchingCallback = { refcon, iter in
            guard let refcon else { return }
            let w = Unmanaged<PowerSourceWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak w] in w?.handleAdded(iter) }
        }
        let removed: IOServiceMatchingCallback = { refcon, iter in
            guard let refcon else { return }
            let w = Unmanaged<PowerSourceWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak w] in w?.handleRemoved(iter) }
        }

        let matching = IOServiceMatching("IOPortFeaturePowerSource")
        if IOServiceAddMatchingNotification(port, kIOMatchedNotification, matching, added, selfPtr, &addedIter) == KERN_SUCCESS {
            handleAdded(addedIter)
        }

        let matching2 = IOServiceMatching("IOPortFeaturePowerSource")
        if IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matching2, removed, selfPtr, &removedIter) == KERN_SUCCESS {
            handleRemoved(removedIter)
        }

        // Reconcile the power-source notification to the flag: stop() tears the
        // source down but leaves readsChargerInputWatts as-is, so a stop/start
        // cycle must re-register it here rather than silently lose it.
        if readsChargerInputWatts { startPowerSourceNotification() }
    }

    public func stop() {
        if addedIter != 0 { IOObjectRelease(addedIter); addedIter = 0 }
        if removedIter != 0 { IOObjectRelease(removedIter); removedIter = 0 }
        if let p = notifyPort { IONotificationPortDestroy(p); notifyPort = nil }
        stopPowerSourceNotification()
        sources.removeAll()
    }

    // MARK: - Charger-in watts notification

    /// Register the system power-source change notification on the main run loop.
    /// The callback fires on a charging-state change, which recomputes the watts
    /// without polling. Idempotent.
    private func startPowerSourceNotification() {
        guard powerSourceRunLoopSource == nil else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let w = Unmanaged<PowerSourceWatcher>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak w] in w?.handlePowerSourceNotification() }
        }
        guard let unmanaged = IOPSNotificationCreateRunLoopSource(callback, selfPtr) else { return }
        let source = unmanaged.takeRetainedValue()
        // .commonModes so the callback still fires while the run loop is in a
        // tracking/modal mode (e.g. a menu open), not only the default mode.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSourceRunLoopSource = source
    }

    private func stopPowerSourceNotification() {
        guard let source = powerSourceRunLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        powerSourceRunLoopSource = nil
    }

    private func handlePowerSourceNotification() {
        guard readsChargerInputWatts else { return }
        refreshChargerInputWatts()
    }

    public func refresh() {
        // Build the new list locally and assign once. Mutating the published
        // `sources` in place (removeAll then re-append) emits a transient empty
        // value that downstream subscribers see as "everything disconnected,"
        // which made NotificationManager fire a charger-connect/disconnect pair
        // on every poll tick. See issue #227.
        var rebuilt = Self.readAllPowerSources()
        if let synthesized = synthesizeIfNeeded(realSources: rebuilt) {
            rebuilt.append(synthesized)
        }
        if rebuilt != sources { sources = rebuilt }
        if readsChargerInputWatts { refreshChargerInputWatts() }
    }

    /// Attempt `PowerSourceSynthesis` (issue #401). Gated cheap-first so
    /// healthy machines (a real node exists) and idle machines (no active
    /// uncovered USB-C port) never pay for the extra `AppleSmartBattery`
    /// read: only once both checks below pass do we read the battery
    /// property dictionary at all.
    private func synthesizeIfNeeded(realSources: [PowerSource]) -> PowerSource? {
        // Cheapest check first: needs only the sources this tick's
        // readAllPowerSources() already read, no context and no extra IOKit
        // work. Not `PowerSource.hasLiveChargingContract(in:)`: that only
        // inspects the first source named "USB-PD" in the array, which is
        // correct for every existing caller (they all pass an already-
        // per-port-filtered array) but wrong here, where `realSources` spans
        // every port. See the matching comment in
        // `PowerSourceSynthesis.synthesizedSource` (gate 2) for the corpus
        // evidence.
        let anyRealSourceHasLiveContract = realSources.contains { source in
            guard let winning = source.winning else { return false }
            return winning.maxPowerMW > 0
        }
        guard !anyRealSourceHasLiveContract else { return nil }

        guard let context = synthesisContext?() else { return nil }

        // context.ports is a cheap read of an already-published property, no
        // IOKit call. USB-C is required explicitly (portKey prefix "2/"),
        // not just "not MagSafe": A18 Pro ("MacBook Neo") corpus machines
        // have Port-Inductive ports, and other non-USB-C, non-MagSafe port
        // types may exist that we've never seen. Positive match only.
        let hasUncoveredActivePort = context.ports.contains { port in
            port.portKey?.hasPrefix("2/") == true
                && port.connectionActive == true
                && realSources.filter({ $0.canonicallyMatches(port: port) }).isEmpty
        }
        guard hasUncoveredActivePort else { return nil }

        // Only past this point do we pay for the AppleSmartBattery read.
        // A desktop Mac has no AppleSmartBattery service at all, so there is
        // no PortControllerInfo to synthesize from; returning nil here is
        // correct, not a fallback default.
        guard let dict = PowerTelemetryWatcher.appleSmartBatteryProperties() else { return nil }
        // The dict exists here (the guard above already returned for a
        // missing one); a dict without the ExternalConnected flag itself
        // still reads as connected, same defaulting refreshChargerInputWatts() uses.
        let externalConnected = (dict["ExternalConnected"] as? NSNumber)?.boolValue ?? true
        let entries = wcArray(dict["PortControllerInfo"]).map(wcDictionary).enumerated().map { offset, entry in
            let pdoCount = wcInt(entry["PortControllerNPDOs"])
            let rawPDOs = wcArray(entry["PortControllerPortPDO"]).map(wcUInt32)
            let trimmed = Array(rawPDOs.prefix(pdoCount > 0 ? pdoCount : rawPDOs.count))
            return PowerSourceSynthesis.ContractEntry(
                index: offset,
                rawPDOs: trimmed,
                activeRdo: wcUInt32(entry["PortControllerActiveContractRdo"]),
                maxPowerMW: wcInt(entry["PortControllerMaxPower"])
            )
        }

        return PowerSourceSynthesis.synthesizedSource(
            realSources: realSources,
            ports: context.ports,
            identities: context.identities,
            entries: entries,
            // Evaluated here, right before the call that needs it: this is
            // the one point in the whole gate chain where the IOKit walk in
            // hpmPortKeys() actually runs.
            positionalPortKeys: context.positionalPortKeys(),
            externalConnected: externalConnected
        )
    }

    /// Read the live charger-in wattage and publish it when the rounded value
    /// changes. Same source order the menu bar has always shown: the live SMC
    /// DC-in rail first, then `AppleSmartBattery`'s coarse `SystemPowerIn`, then
    /// the rated adapter. Runs on the hub's poll cadence, not a private timer.
    private func refreshChargerInputWatts() {
        let dict = PowerTelemetryWatcher.appleSmartBatteryProperties()
        // No battery dict at all means a desktop: treat as always externally
        // powered. A dict without the flag also reads as connected.
        let externalConnected = dict.map { ($0["ExternalConnected"] as? Bool) ?? true } ?? true
        // On battery there is nothing to show. Return before the SMC user-client
        // and adapter reads so those run only while a charger is attached (the
        // same short-circuit the old menu-bar read had).
        guard externalConnected else {
            if chargerInputWatts != 0 { chargerInputWatts = 0 }
            if chargerRatedWatts != 0 { chargerRatedWatts = 0 }
            return
        }

        let smcWatts = smcReader.readSystemPowerInput()?.watts
        let telemetry = dict?["PowerTelemetryData"] as? [String: Any]
        let systemPowerInMilliwatts = telemetry?["SystemPowerIn"] as? Int
        let adapterWatts = SystemPower.currentAdapter()?.watts

        let watts = Self.selectChargerInputWatts(
            externalConnected: externalConnected,
            smcWatts: smcWatts,
            systemPowerInMilliwatts: systemPowerInMilliwatts,
            adapterWatts: adapterWatts
        )
        if watts != chargerInputWatts { chargerInputWatts = watts }

        // The adapter's rated maximum, the denominator for the power bar.
        let rated = adapterWatts ?? 0
        if rated != chargerRatedWatts { chargerRatedWatts = rated }
    }

    /// Pure watts-selection policy, testable without IOKit. Returns 0 on battery
    /// (`externalConnected == false`) or when no source reports a usable figure.
    /// Prefers the live SMC rail, then the battery gauge (milliwatts, rounded to
    /// the nearest watt), then the rated adapter wattage.
    nonisolated static func selectChargerInputWatts(
        externalConnected: Bool,
        smcWatts: Double?,
        systemPowerInMilliwatts: Int?,
        adapterWatts: Int?
    ) -> Int {
        guard externalConnected else { return 0 }
        if let smcWatts, smcWatts > 0 { return Int(smcWatts.rounded()) }
        if let systemPowerInMilliwatts, systemPowerInMilliwatts > 0 {
            return (systemPowerInMilliwatts + 500) / 1000
        }
        if let adapterWatts, adapterWatts > 0 { return adapterWatts }
        return 0
    }

    /// Enumerate every `IOPortFeaturePowerSource` once and parse it into the
    /// self-keyed `PowerSource` model. Shared with `PowerTelemetryWatcher`,
    /// which needs the keyed contract to attribute `PortControllerInfo` detail
    /// to the right port (instead of array-offset guessing).
    public nonisolated static func readAllPowerSources() -> [PowerSource] {
        var rebuilt: [PowerSource] = []
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPortFeaturePowerSource"), &iter) == KERN_SUCCESS {
            while case let service = IOIteratorNext(iter), service != 0 {
                if let s = makeSource(from: service), !rebuilt.contains(where: { $0.id == s.id }) {
                    rebuilt.append(s)
                }
                IOObjectRelease(service)
            }
            IOObjectRelease(iter)
        }
        return rebuilt
    }

    private func handleAdded(_ iter: io_iterator_t) {
        var addedRealUSBCSource = false
        while case let service = IOIteratorNext(iter), service != 0 {
            if let s = Self.makeSource(from: service), !sources.contains(where: { $0.id == s.id }) {
                sources.append(s)
                if s.parentPortType == 2 { addedRealUSBCSource = true }
            }
            IOObjectRelease(service)
        }
        // A real USB-C-parented node just arrived: gate 2b in
        // PowerSourceSynthesis means synthesis must stop for this machine
        // from now on, so drop any synthesized entry immediately rather than
        // leaving it in `sources` until the next refresh() tick clears it.
        if addedRealUSBCSource {
            sources.removeAll { $0.isSynthesized }
        }
    }

    private func handleRemoved(_ iter: io_iterator_t) {
        while case let service = IOIteratorNext(iter), service != 0 {
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS {
                sources.removeAll { $0.id == entryID }
            }
            IOObjectRelease(service)
        }
    }

    // MARK: - IOKit wrapper (package-internal)

    nonisolated static func makeSource(from service: io_service_t) -> PowerSource? {
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return nil }

        // Read keys individually rather than fetching the full property
        // dictionary. The bulk fetch (IORegistryEntryCreateCFProperties)
        // can abort the process from inside IOCFUnserializeBinary when
        // the kernel returns a malformed serialised properties blob,
        // typically when the service is being torn down mid-read. The
        // per-key call has no such failure path. See issue #181.
        func read(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        // Walk the parent chain to get the HPM controller UUID. This is the
        // same UUID stored on the AppleHPMInterface node two levels above, so
        // matching by UUID ties a power source to its port with no @N guessing.
        let uuid = wcHPMControllerUUID(for: service)
        return makeSource(entryID: entryID, read: read, hpmControllerUUID: uuid)
    }

    // MARK: - Parse function (internal, testable)

    /// Parse a power source from a property-read closure. The `hpmControllerUUID`
    /// is passed in so the caller can walk the parent chain once and tests can
    /// supply nil without IOKit.
    nonisolated static func makeSource(
        entryID: UInt64,
        read: (String) -> Any?,
        hpmControllerUUID: String?
    ) -> PowerSource? {
        let name = (read("PowerSourceName") as? String) ?? "Unknown"
        let parent = parentPortIdentity(read: read)

        let options: [PowerOption] = parseOptions(read("PowerSourceOptions"))
        let winning: PowerOption? = parseOption(read("WinningPowerSourceOption"))

        return PowerSource(
            id: entryID,
            name: name,
            parentPortType: parent.type,
            parentPortNumber: parent.number,
            options: options,
            winning: winning,
            hpmControllerUUID: hpmControllerUUID
        )
    }

    nonisolated static func parentPortIdentity(read: (String) -> Any?) -> (type: Int, number: Int) {
        let type = (read("ParentBuiltInPortType") as? NSNumber)?.intValue
            ?? (read("ParentPortType") as? NSNumber)?.intValue
            ?? 0
        let number = (read("ParentBuiltInPortNumber") as? NSNumber)?.intValue
            ?? (read("ParentPortNumber") as? NSNumber)?.intValue
            ?? Int(((read("Priority") as? NSNumber)?.uint64Value ?? 0) & 0xFF)
        return (type, number)
    }

    nonisolated static func parseOptions(_ value: Any?) -> [PowerOption] {
        // IOKit publishes PowerSourceOptions as an __NSCFSet (CF set), not
        // an NSArray. ioreg renders it as "[{...}]" which looks like an
        // array, but the actual CF type is a set. Handle both.
        let items: [Any]
        if let set = value as? NSSet {
            items = set.allObjects
        } else if let arr = value as? NSArray {
            items = arr.compactMap { $0 }
        } else {
            return []
        }
        return items.compactMap { parseOption($0) }
            .sorted { $0.maxPowerMW > $1.maxPowerMW }
    }

    nonisolated static func parseOption(_ value: Any?) -> PowerOption? {
        let dict: [String: Any]?
        if let d = value as? [String: Any] {
            dict = d
        } else if let nsd = value as? NSDictionary {
            var converted: [String: Any] = [:]
            for case let (key, val) as (String, Any) in nsd {
                converted[key] = val
            }
            dict = converted
        } else {
            dict = nil
        }
        guard let dict else { return nil }
        let v = (dict["Voltage (mV)"] as? NSNumber)?.intValue ?? 0
        let i = (dict["Max Current (mA)"] as? NSNumber)?.intValue ?? 0
        let p = (dict["Max Power (mW)"] as? NSNumber)?.intValue ?? (v * i / 1000)
        guard v > 0 else { return nil }
        return PowerOption(voltageMV: v, maxCurrentMA: i, maxPowerMW: p)
    }
}

extension PowerSourceWatcher {
    /// All power sources attached to a given port.
    /// Uses UUID-based matching when available (M3+), else portKey fallback.
    public func sources(for port: AppleHPMInterface) -> [PowerSource] {
        return sources.filter { $0.canonicallyMatches(port: port) }
    }
}
