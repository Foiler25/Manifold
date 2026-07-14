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

/// Watches `IOPortTransportState*` services for TRM (Trust and Restrict
/// Management) properties and CIO cable capability data. These transport
/// services appear dynamically when a USB-C accessory is connected and
/// disappear on unplug.
///
/// Each transport (USB2, DisplayPort, etc.) can carry its own TRM state,
/// so a single port might have USB2 restricted while DisplayPort is not.
///
/// CIO transports additionally carry cable capability fields
/// (`CableGeneration`, `CableSpeed`, etc.) that represent the TB
/// controller's assessment of the cable, independent of the USB-PD
/// e-marker. These are published separately as `CIOCableCapability`.
@MainActor
public final class TRMTransportWatcher: ObservableObject {
    @Published public private(set) var transports: [TRMTransport] = []
    @Published public private(set) var cioCapabilities: [CIOCableCapability] = []

    // Transport state classes that carry TRM properties. USB2 and
    // DisplayPort are the ones confirmed to have meaningful TRM data.
    // USB3 and CIO may also carry TRM state when those transports are
    // active, so we watch them too.
    nonisolated static let watchedClasses = [
        "IOPortTransportStateUSB2",
        "IOPortTransportStateDisplayPort",
        "IOPortTransportStateUSB3",
        "IOPortTransportStateCIO",
    ]

    private var notifyPort: IONotificationPortRef?
    private var addedIters: [io_iterator_t] = []
    private var removedIters: [io_iterator_t] = []

    public init() {}

    public func start() {
        guard notifyPort == nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let added: IOServiceMatchingCallback = { refcon, iter in
            guard let refcon else { return }
            let w = Unmanaged<TRMTransportWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak w] in w?.handleAdded(iter) }
        }
        let removed: IOServiceMatchingCallback = { refcon, iter in
            guard let refcon else { return }
            let w = Unmanaged<TRMTransportWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak w] in w?.handleRemoved(iter) }
        }

        for cls in Self.watchedClasses {
            var addIter: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, kIOMatchedNotification,
                                                 IOServiceMatching(cls),
                                                 added, selfPtr, &addIter) == KERN_SUCCESS {
                addedIters.append(addIter)
                handleAdded(addIter)
            }

            var rmIter: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                                                 IOServiceMatching(cls),
                                                 removed, selfPtr, &rmIter) == KERN_SUCCESS {
                removedIters.append(rmIter)
                handleRemoved(rmIter)
            }
        }
    }

    public func stop() {
        for iter in addedIters { IOObjectRelease(iter) }
        addedIters.removeAll()
        for iter in removedIters { IOObjectRelease(iter) }
        removedIters.removeAll()
        if let p = notifyPort { IONotificationPortDestroy(p); notifyPort = nil }
        transports.removeAll()
        cioCapabilities.removeAll()
    }

    public func refresh() {
        // Build both lists locally and assign once. Mutating the published
        // properties in place (removeAll then re-append) emits a transient
        // empty value that downstream subscribers see as "everything gone."
        // See issue #227.
        var rebuiltTransports: [TRMTransport] = []
        var rebuiltCIO: [CIOCableCapability] = []
        for cls in Self.watchedClasses {
            var iter: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &iter) == KERN_SUCCESS {
                while case let service = IOIteratorNext(iter), service != 0 {
                    defer { IOObjectRelease(service) }

                    var entryID: UInt64 = 0
                    guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { continue }

                    func read(_ key: String) -> Any? {
                        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                    }

                    var classBuf = [CChar](repeating: 0, count: 128)
                    guard IOObjectGetClass(service, &classBuf) == KERN_SUCCESS else { continue }
                    let className = String(cString: classBuf)
                    let transportType = Self.transportType(from: className)

                    if let t = makeTRMTransport(entryID: entryID, service: service, read: read, transportType: transportType),
                       !rebuiltTransports.contains(where: { $0.id == t.id }) {
                        rebuiltTransports.append(t)
                    }

                    if transportType == "CIO",
                       let c = makeCIOCapability(entryID: entryID, service: service, read: read),
                       !rebuiltCIO.contains(where: { $0.id == c.id }) {
                        rebuiltCIO.append(c)
                    }
                }
                IOObjectRelease(iter)
            }
        }
        if rebuiltTransports != transports { transports = rebuiltTransports }
        if rebuiltCIO != cioCapabilities { cioCapabilities = rebuiltCIO }
    }

    private func handleAdded(_ iter: io_iterator_t) {
        while case let service = IOIteratorNext(iter), service != 0 {
            defer { IOObjectRelease(service) }

            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { continue }

            // Read keys individually rather than fetching the full property
            // dictionary. The bulk fetch (IORegistryEntryCreateCFProperties)
            // can abort the process from inside IOCFUnserializeBinary when
            // the kernel returns a malformed serialised properties blob,
            // typically when the service is being torn down mid-read. The
            // per-key call has no such failure path. See issue #181.
            func read(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }

            var classBuf = [CChar](repeating: 0, count: 128)
            guard IOObjectGetClass(service, &classBuf) == KERN_SUCCESS else { continue }
            let className = String(cString: classBuf)
            let transportType = Self.transportType(from: className)

            if let t = makeTRMTransport(entryID: entryID, service: service, read: read, transportType: transportType),
               !transports.contains(where: { $0.id == t.id }) {
                transports.append(t)
            }

            if transportType == "CIO",
               let c = makeCIOCapability(entryID: entryID, service: service, read: read),
               !cioCapabilities.contains(where: { $0.id == c.id }) {
                cioCapabilities.append(c)
            }
        }
    }

    private func handleRemoved(_ iter: io_iterator_t) {
        while case let service = IOIteratorNext(iter), service != 0 {
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS {
                transports.removeAll { $0.id == entryID }
                cioCapabilities.removeAll { $0.id == entryID }
            }
            IOObjectRelease(service)
        }
    }

    // MARK: - IOKit wrapper (private)

    private func makeTRMTransport(entryID: UInt64, service: io_service_t, read: (String) -> Any?, transportType: String) -> TRMTransport? {
        let uuid = wcHPMControllerUUID(for: service)
        return Self.makeTRMTransport(entryID: entryID, read: read, transportType: transportType, hpmControllerUUID: uuid)
    }

    private func makeCIOCapability(entryID: UInt64, service: io_service_t, read: (String) -> Any?) -> CIOCableCapability? {
        let uuid = wcHPMControllerUUID(for: service)
        return Self.makeCIOCapability(entryID: entryID, read: read, hpmControllerUUID: uuid)
    }

    // MARK: - Parse functions (internal, testable)

    /// Parse a TRM transport from a property-read closure. The `hpmControllerUUID`
    /// is passed in rather than looked up here so the caller (an IOKit wrapper)
    /// can walk the parent chain once and tests can supply nil without IOKit.
    ///
    /// Gate: returns nil when TRM_State is absent (no TRM data on this service).
    nonisolated static func makeTRMTransport(
        entryID: UInt64,
        read: (String) -> Any?,
        transportType: String,
        hpmControllerUUID: String?
    ) -> TRMTransport? {
        // Use TRM_State as the presence gate: it is the primary TRM field and
        // is always published when TRM data exists. This replaces the old
        // dict.keys.contains { $0.hasPrefix("TRM_") } check, which required
        // the full bulk dict and cannot be reproduced with per-key reads.
        // Cache the value here so the guard and the field assignment share
        // the same IOKit call -- avoiding a second round-trip and a potential
        // race if the service transitions state between the two reads.
        let trmStateRaw = read("TRM_State")
        guard trmStateRaw != nil else { return nil }

        let parent = parentPortIdentity(read: read)
        let portKey = "\(parent.type)/\(parent.number)"

        return TRMTransport(
            id: entryID,
            portKey: portKey,
            transportType: transportType,
            state: (trmStateRaw as? NSNumber)?.intValue,
            stateDescription: read("TRM_StateDescription") as? String,
            transportRestricted: (read("TRM_TransportRestricted") as? NSNumber)?.boolValue,
            transportSupervised: (read("TRM_TransportSupervised") as? NSNumber)?.boolValue,
            identificationRestricted: (read("TRM_IdentificationRestricted") as? NSNumber)?.boolValue,
            deviceLocked: (read("TRM_DeviceLocked") as? NSNumber)?.boolValue,
            relaxedPeriod: (read("TRM_RelaxedPeriod") as? NSNumber)?.boolValue,
            gracePeriodReason: (read("TRM_GracePeriodReason") as? NSNumber)?.intValue,
            gracePeriodReasonDescription: read("TRM_GracePeriodReasonDescription") as? String,
            profile: (read("TRM_Profile") as? NSNumber)?.intValue,
            profileDescription: read("TRM_ProfileDescription") as? String,
            cacheMiss: (read("TRM_CacheMiss") as? NSNumber)?.boolValue,
            hpmControllerUUID: hpmControllerUUID
        )
    }

    /// Parse a CIO cable capability from a property-read closure. The
    /// `hpmControllerUUID` is passed in so tests can supply nil without IOKit.
    ///
    /// Unlike TRM, CIO has no hard gate key -- any IOPortTransportStateCIO
    /// service is a valid candidate. Callers guard on transportType == "CIO".
    nonisolated static func makeCIOCapability(
        entryID: UInt64,
        read: (String) -> Any?,
        hpmControllerUUID: String?
    ) -> CIOCableCapability? {
        let parent = parentPortIdentity(read: read)
        let portKey = "\(parent.type)/\(parent.number)"

        return CIOCableCapability(
            id: entryID,
            portKey: portKey,
            cableGeneration: (read("CableGeneration") as? NSNumber)?.intValue,
            negotiatedLinkSpeed: (read("CableSpeed") as? NSNumber)?.intValue,
            generation: (read("Generation") as? NSNumber)?.intValue,
            asymmetricModeSupported: (read("AsymmetricModeSupported") as? NSNumber)?.boolValue,
            legacyAdapter: (read("LegacyAdapter") as? NSNumber)?.boolValue,
            linkTrainingMode: (read("LinkTrainingMode") as? NSNumber)?.intValue,
            hpmControllerUUID: hpmControllerUUID
        )
    }

    /// Reads the parent port type and number from the service's properties.
    /// Same approach as `USB3TransportWatcher` and `PowerSourceWatcher`.
    nonisolated static func parentPortIdentity(read: (String) -> Any?) -> (type: Int, number: Int) {
        let type = (read("ParentBuiltInPortType") as? NSNumber)?.intValue
            ?? (read("ParentPortType") as? NSNumber)?.intValue
            ?? 0
        let number = (read("ParentBuiltInPortNumber") as? NSNumber)?.intValue
            ?? (read("ParentPortNumber") as? NSNumber)?.intValue
            ?? Int(((read("Priority") as? NSNumber)?.uint64Value ?? 0) & 0xFF)
        return (type, number)
    }

    /// Extracts a short transport type label from the IOKit class name.
    /// "IOPortTransportStateUSB2" -> "USB2", etc.
    nonisolated static func transportType(from className: String) -> String {
        let prefix = "IOPortTransportState"
        if className.hasPrefix(prefix) {
            return String(className.dropFirst(prefix.count))
        }
        return className
    }
}
