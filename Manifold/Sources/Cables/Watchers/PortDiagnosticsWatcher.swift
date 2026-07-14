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
public final class PortDiagnosticsWatcher: ObservableObject {
    public struct PortDiagnosticsSnapshot: Codable, Sendable, Equatable {
        public let timestamp: Date
        public let healthCounters: [String: PortHealthCounters]
        public let contracts: [String: PDContract]
        public let eventTraces: [String: PDEventTrace]
    }

    @Published public private(set) var latestSnapshot: PortDiagnosticsSnapshot?

    public let snapshots: AsyncStream<PortDiagnosticsSnapshot>

    private var continuation: AsyncStream<PortDiagnosticsSnapshot>.Continuation?
    private var notifyPort: IONotificationPortRef?
    private var matchIterator: io_iterator_t = 0
    private var cachedPortKeys: [String] = []

    public init() {
        var continuation: AsyncStream<PortDiagnosticsSnapshot>.Continuation?
        snapshots = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func start() {
        guard notifyPort == nil else { return }
        cachedPortKeys = PowerTelemetryWatcher.hpmPortKeys()
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let cb: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<PortDiagnosticsWatcher>.fromOpaque(refcon).takeUnretainedValue()
            // Capture weakly so that if the watcher is torn down before this
            // task runs, it becomes a no-op rather than touching freed memory.
            Task { @MainActor [weak watcher] in
                guard let watcher else { return }
                while case let service = IOIteratorNext(iterator), service != 0 {
                    IOObjectRelease(service)
                }
                watcher.refresh()
            }
        }

        if IOServiceAddMatchingNotification(
            port,
            kIOMatchedNotification,
            IOServiceMatching("AppleSmartBattery"),
            cb,
            selfPtr,
            &matchIterator
        ) == KERN_SUCCESS {
            while case let service = IOIteratorNext(matchIterator), service != 0 {
                IOObjectRelease(service)
            }
            refresh()
        }
    }

    public func stop() {
        if matchIterator != 0 {
            IOObjectRelease(matchIterator)
            matchIterator = 0
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        cachedPortKeys = []
        latestSnapshot = nil
    }

    public func refresh() {
        guard let dict = PowerTelemetryWatcher.appleSmartBatteryPropertiesForDiagnostics() else { return }
        let entries = wcArray(dict["PortControllerInfo"]).map(wcDictionary)
        var counters: [String: PortHealthCounters] = [:]
        var contracts: [String: PDContract] = [:]
        var traces: [String: PDEventTrace] = [:]

        // Read the live self-keyed power sources so watts-based join can anchor
        // entries that have an active contract to the correct port key.
        let liveSources = PowerSourceWatcher.readAllPowerSources()
        let keyMap = Self.portKeyMap(entries: entries, portKeys: cachedPortKeys, sources: liveSources)

        for (offset, entry) in entries.enumerated() {
            guard let key = keyMap[offset] else { continue }
            counters[key] = Self.healthCounters(from: entry)
            contracts[key] = Self.contract(from: entry)
            traces[key] = Self.eventTrace(from: entry)
        }

        let snapshot = PortDiagnosticsSnapshot(
            timestamp: Date(),
            healthCounters: counters,
            contracts: contracts,
            eventTraces: traces
        )
        latestSnapshot = snapshot
        continuation?.yield(snapshot)
    }

    /// Map each `PortControllerInfo` array index to a port key.
    ///
    /// `PortControllerInfo` entries carry no port identifier (no `PortIndex` or
    /// similar key). The reliable signal for entries that have an active charge
    /// contract is `PortControllerMaxPower`: `PowerControllerPortJoin` matches
    /// that wattage to the self-keyed `IOPortFeaturePowerSource` that owns the
    /// port, so entries with live contracts land on the right key regardless of
    /// array order.
    ///
    /// For entries with zero `PortControllerMaxPower` (idle or disconnected
    /// ports), no watts signal is available, so the positional fallback is
    /// unavoidable. The `portKeys` array comes from `hpmPortKeys()`, which walks
    /// the same HPM controller services in the same IOKit traversal order that
    /// Apple uses to build `PortControllerInfo`. On machines with contiguous port
    /// numbering this is correct. On a machine whose HPM traversal order differs
    /// from the `PortControllerInfo` order (non-contiguous or re-numbered ports),
    /// idle-port data may appear on the wrong port key. This is accepted because:
    /// (1) only idle ports are affected (no contract, zero watts), and (2) no
    /// stable identifier is available to do better.
    nonisolated static func portKeyMap(
        entries: [[String: Any]],
        portKeys: [String],
        sources: [PowerSource]
    ) -> [Int: String] {
        let maxPowers = entries.map { wcInt($0["PortControllerMaxPower"]) }
        // Watts-based join from PowerControllerPortJoin. Returns only the
        // indices that unambiguously match a self-keyed source port. Idle-port
        // entries (zero max power) are always absent from this map.
        let wattsMap = PowerControllerPortJoin.portKeysByContent(
            controllerMaxPowerMW: maxPowers,
            sources: sources
        )

        var result: [Int: String] = [:]
        for (offset, _) in entries.enumerated() {
            if let key = wattsMap[offset] {
                // Unambiguous watts match: this entry belongs to the port that
                // owns the active charge contract.
                result[offset] = key
            } else if offset < portKeys.count {
                // No watts signal (idle port). Fall back to the positional HPM
                // traversal order, which matches PortControllerInfo on machines
                // with contiguous port numbering. See comment above.
                result[offset] = portKeys[offset]
            } else {
                // More entries than known HPM ports (unexpected). Use a best-
                // effort 1-based index key so data still surfaces rather than
                // being silently dropped.
                result[offset] = "2/\(offset + 1)"
            }
        }
        return result
    }

    private static func contract(from dict: [String: Any]) -> PDContract {
        let rawPDOs = wcArray(dict["PortControllerPortPDO"]).map(wcUInt32)
        let pdoCount = wcInt(dict["PortControllerNPDOs"])
        let decoded = rawPDOs.prefix(pdoCount > 0 ? pdoCount : rawPDOs.count).map(PDO.decode(rawValue:))
        return PDContract(
            activeRdo: wcUInt32(dict["PortControllerActiveContractRdo"]),
            pdoList: decoded,
            pdoCount: pdoCount,
            maxPower: wcInt(dict["PortControllerMaxPower"]),
            capMismatch: wcBool(dict["PortControllerCapMismatch"]),
            srcTypes: wcInt(dict["PortControllerSrcTypes"])
        )
    }

    private static func healthCounters(from dict: [String: Any]) -> PortHealthCounters {
        PortHealthCounters(
            attachCount: wcInt(dict["PortControllerAttachCount"]),
            detachCount: wcInt(dict["PortControllerDetachCount"]),
            hardResetCount: wcInt(dict["PortControllerHardResetCount"]),
            shortDetectCount: wcInt(dict["PortControllerShortDetectCount"]),
            i2cErrCount: wcInt(dict["PortControllerI2cErrCount"]),
            dataRoleSwapCount: wcInt(dict["PortControllerDataRoleSwapCount"]),
            dataRoleSwapFailCount: wcInt(dict["PortControllerDataRoleSwapFailCount"]),
            pwrRoleSwapCount: wcInt(dict["PortControllerPwrRoleSwapCount"]),
            pwrRoleSwapFailCount: wcInt(dict["PortControllerPwrRoleSwapFailCount"]),
            vdoFailCount: wcInt(dict["PortControllerVdoFailCount"]),
            fetEnableFailCount: wcInt(dict["PortControllerInpFetEnFailCount"]),
            fetStatus: wcUInt8(dict["PortControllerFetStatus"]),
            pdState: wcUInt8(dict["PortControllerPDst"]),
            dnState: wcUInt8(dict["PortControllerDnSt"])
        )
    }

    private static func eventTrace(from dict: [String: Any]) -> PDEventTrace {
        let raw = wcData(dict["PortControllerEvtBuffer"]) ?? Data(wcArray(dict["PortControllerEvtBuffer"]).map(wcUInt8))
        let filtered = raw.filter { $0 != 0x00 }
        let events = filtered.map(PDEvent.init(rawValue:))
        return PDEventTrace(rawBuffer: filtered, events: events)
    }
}

extension PowerTelemetryWatcher {
    nonisolated static func appleSmartBatteryPropertiesForDiagnostics() -> [String: Any]? {
        appleSmartBatteryProperties()
    }
}
