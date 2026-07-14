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

/// Watches `IOPortTransportComponentCCUSBPDSOP` (port partner) and
/// `IOPortTransportComponentCCUSBPDSOPp` (cable e-marker SOP') services.
/// macOS exposes these as separate IOKit classes, so we have to match both.
/// Some hardware also exposes SOP'' as a third class.
@MainActor
public final class USBPDSOPWatcher: ObservableObject {
    @Published public private(set) var identities: [USBPDSOP] = []

    private static let matchedClasses = [
        "IOPortTransportComponentCCUSBPDSOP",
        "IOPortTransportComponentCCUSBPDSOPp",
        "IOPortTransportComponentCCUSBPDSOPpp",
    ]

    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    public init() {}

    public func start() {
        guard notifyPort == nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let added: IOServiceMatchingCallback = { refcon, iter in
            guard let refcon else { return }
            let w = Unmanaged<USBPDSOPWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak w] in w?.handleAdded(iter) }
        }
        let removed: IOServiceMatchingCallback = { refcon, iter in
            guard let refcon else { return }
            let w = Unmanaged<USBPDSOPWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak w] in w?.handleRemoved(iter) }
        }

        for className in Self.matchedClasses {
            var addedIter: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, kIOMatchedNotification,
                IOServiceMatching(className),
                added, selfPtr, &addedIter) == KERN_SUCCESS {
                handleAdded(addedIter)
                iterators.append(addedIter)
            }

            var removedIter: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                IOServiceMatching(className),
                removed, selfPtr, &removedIter) == KERN_SUCCESS {
                handleRemoved(removedIter)
                iterators.append(removedIter)
            }
        }
    }

    public func stop() {
        for iter in iterators where iter != 0 { IOObjectRelease(iter) }
        iterators.removeAll()
        if let p = notifyPort { IONotificationPortDestroy(p); notifyPort = nil }
        identities.removeAll()
    }

    public func refresh() {
        // Build locally and assign once so subscribers never see a transient
        // empty list mid-refresh. See issue #227.
        var rebuilt: [USBPDSOP] = []
        for className in Self.matchedClasses {
            var iter: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMainPortDefault,
                IOServiceMatching(className), &iter) == KERN_SUCCESS {
                while case let service = IOIteratorNext(iter), service != 0 {
                    if let identity = makeIdentity(from: service),
                       !rebuilt.contains(where: { $0.id == identity.id }) {
                        rebuilt.append(identity)
                    }
                    IOObjectRelease(service)
                }
                IOObjectRelease(iter)
            }
        }
        if rebuilt != identities { identities = rebuilt }
    }

    private func handleAdded(_ iter: io_iterator_t) {
        while case let service = IOIteratorNext(iter), service != 0 {
            if let identity = makeIdentity(from: service),
               !identities.contains(where: { $0.id == identity.id }) {
                identities.append(identity)
            }
            IOObjectRelease(service)
        }
    }

    private func handleRemoved(_ iter: io_iterator_t) {
        while case let service = IOIteratorNext(iter), service != 0 {
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS {
                identities.removeAll { $0.id == entryID }
            }
            IOObjectRelease(service)
        }
    }

    private func makeIdentity(from service: io_service_t) -> USBPDSOP? {
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

        var classNameBuf = [CChar](repeating: 0, count: 128)
        let className: String? = (IOObjectGetClass(service, &classNameBuf) == KERN_SUCCESS)
            ? String(cString: classNameBuf)
            : nil

        // Walk the parent chain to capture the HPM controller UUID.
        // SOP/SOP' nodes sit at Port-USB-C@N/CC/SOP, so the controller is
        // ~3-4 steps up (CC -> AppleHPMInterfaceType10 -> AppleHPMDeviceHALType3).
        let uuid = wcHPMControllerUUID(for: service)

        return Self.parseIdentity(
            entryID: entryID,
            read: read,
            className: className,
            hpmControllerUUID: uuid
        )
    }

    /// Parse a `USBPDSOP` from a property-read closure plus metadata that the
    /// IOKit wrapper already resolved. Extracted from `makeIdentity(from:)` so
    /// corpus-replay tests can drive the parse logic without real IOKit services.
    internal nonisolated static func parseIdentity(
        entryID: UInt64,
        read: (String) -> Any?,
        className: String?,
        hpmControllerUUID: String?
    ) -> USBPDSOP? {
        let endpoint = Self.endpoint(read: read, className: className)
        let parent = Self.parentPortIdentity(read: read)
        let specRev = (read("Specification Revision") as? NSNumber)?.intValue ?? 0

        let metadata = Self.metadataDictionary(read: read)
        let vendorID = Self.vendorID(read: read, metadata: metadata)
        let productID = Self.productID(read: read, metadata: metadata)
        let bcdDevice = Self.bcdDevice(from: metadata)

        let vdos: [UInt32] = ((metadata["VDOs"] as? [Any]) ?? []).compactMap { value in
            guard let data = value as? Data else { return nil }
            return PDVDO.vdoFromData(data)
        }

        return USBPDSOP(
            id: entryID,
            endpoint: endpoint,
            parentPortType: parent.type,
            parentPortNumber: parent.number,
            vendorID: vendorID,
            productID: productID,
            bcdDevice: bcdDevice,
            vdos: vdos,
            specRevision: specRev,
            hpmControllerUUID: hpmControllerUUID
        )
    }

    nonisolated static func endpointName(read: (String) -> Any?) -> String {
        (read("ComponentName") as? String)
            ?? (read("AddressDescription") as? String)
            ?? (read("Address Description") as? String)
            ?? (read("TransportTypeDescription") as? String)
            ?? "Unknown"
    }

    nonisolated static func endpoint(read: (String) -> Any?, className: String? = nil) -> USBPDSOP.Endpoint {
        if let name = (read("ComponentName") as? String)
            ?? (read("AddressDescription") as? String)
            ?? (read("Address Description") as? String) {
            return USBPDSOP.Endpoint(rawValue: name) ?? .unknown
        }
        // The IOKit class name is the most reliable signal: macOS exposes
        // SOP' as a separate `IOPortTransportComponentCCUSBPDSOPp` class
        // (and SOP'' as `...SOPpp`), even when ComponentName is absent.
        switch className {
        case "IOPortTransportComponentCCUSBPDSOP": return .sop
        case "IOPortTransportComponentCCUSBPDSOPp": return .sopPrime
        case "IOPortTransportComponentCCUSBPDSOPpp": return .sopDoublePrime
        default: break
        }
        // MagSafe CC transport has no ComponentName; map "CC" only from
        // TransportTypeDescription so a future node with ComponentName="CC"
        // is not misclassified as a cable e-marker.
        switch read("TransportTypeDescription") as? String {
        case "SOP": return .sop
        case "SOP'", "CC": return .sopPrime
        case "SOP''": return .sopDoublePrime
        default: return .unknown
        }
    }

    /// Reads the parent port type and number from the service's properties.
    /// Same approach as `PowerSourceWatcher.parentPortIdentity(read:)`. The
    /// BuiltIn keys must take priority so PD identity and power data resolve
    /// to the same portKey for a given physical port.
    nonisolated static func parentPortIdentity(read: (String) -> Any?) -> (type: Int, number: Int) {
        let type = (read("ParentBuiltInPortType") as? NSNumber)?.intValue
            ?? (read("ParentPortType") as? NSNumber)?.intValue
            ?? 0
        let number = (read("ParentBuiltInPortNumber") as? NSNumber)?.intValue
            ?? (read("ParentPortNumber") as? NSNumber)?.intValue
            ?? Int(((read("Priority") as? NSNumber)?.uint64Value ?? 0) & 0xFF)
        return (type, number)
    }

    nonisolated static func metadataDictionary(read: (String) -> Any?) -> [String: Any] {
        let raw = read("Metadata")
        if let metadata = raw as? [String: Any] {
            return metadata
        }
        if let nsMetadata = raw as? NSDictionary {
            var converted: [String: Any] = [:]
            for case let (key, value) as (String, Any) in nsMetadata {
                converted[key] = value
            }
            return converted
        }
        return [:]
    }

    nonisolated static func vendorID(read: (String) -> Any?, metadata: [String: Any]) -> Int {
        (metadata["Vendor ID"] as? NSNumber)?.intValue
            ?? (metadata["Vendor ID (SOP1)"] as? NSNumber)?.intValue
            ?? (read("Vendor ID (SOP1)") as? NSNumber)?.intValue
            ?? (read("Vendor ID") as? NSNumber)?.intValue
            ?? 0
    }

    nonisolated static func productID(read: (String) -> Any?, metadata: [String: Any]) -> Int {
        (metadata["Product ID"] as? NSNumber)?.intValue
            ?? (metadata["Product ID (SOP1)"] as? NSNumber)?.intValue
            ?? (read("Product ID (SOP1)") as? NSNumber)?.intValue
            ?? (read("Product ID") as? NSNumber)?.intValue
            ?? 0
    }

    nonisolated static func bcdDevice(from metadata: [String: Any]) -> Int {
        (metadata["bcdDevice"] as? NSNumber)?.intValue ?? 0
    }

    public func identities(for port: AppleHPMInterface) -> [USBPDSOP] {
        identities.filter { $0.canonicallyMatches(port: port) }
    }
}

