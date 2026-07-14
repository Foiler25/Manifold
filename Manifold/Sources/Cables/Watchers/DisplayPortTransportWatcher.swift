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
public final class DisplayPortTransportWatcher: ObservableObject {
    public struct DisplayPortUpdate: Codable, Sendable, Equatable {
        /// The IOKit registry entry id of this DisplayPort node: a kernel-assigned
        /// value that is unique per node and stable for its lifetime. This is the
        /// dedup key, because a dock that drives two monitors through one host
        /// Thunderbolt port produces two nodes that share `portIndex`/`portType`
        /// (and whose `Index` field is always 0), so port identity alone would
        /// collapse them to one. See issue #271.
        public let entryID: UInt64
        public let portIndex: Int
        public let portType: String
        public let status: IOPortTransportStateDisplayPort
    }

    @Published public private(set) var statuses: [DisplayPortUpdate] = []

    /// Native video output sockets that aren't USB-C and so have no
    /// `AppleHPMInterface` entry (today: the built-in HDMI port on M-series
    /// MacBook Pros, Mac mini Pro, Mac Studio). Derived from `statuses` by
    /// grouping each DP node whose parent port is built-in and isn't USB-C.
    /// Empty whenever nothing is plugged into a native HDMI port; we don't
    /// synthesise idle entries (the IOKit transport node only exists when a
    /// display is actually attached). Issue #352.
    public var builtInDisplayPorts: [BuiltInDisplayPort] {
        BuiltInDisplayPort.group(from: statuses.map(\.status))
    }

    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    public init() {}

    public func start() {
        guard notifyPort == nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let added: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<DisplayPortTransportWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak watcher] in watcher?.handleAdded(iterator) }
        }
        let removed: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<DisplayPortTransportWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak watcher] in watcher?.handleRemoved(iterator) }
        }

        if IOServiceAddMatchingNotification(
            port,
            kIOMatchedNotification,
            IOServiceMatching("IOPortTransportStateDisplayPort"),
            added,
            selfPtr,
            &addedIterator
        ) == KERN_SUCCESS {
            handleAdded(addedIterator)
        }

        if IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching("IOPortTransportStateDisplayPort"),
            removed,
            selfPtr,
            &removedIterator
        ) == KERN_SUCCESS {
            handleRemoved(removedIterator)
        }
    }

    public func stop() {
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        statuses.removeAll()
    }

    public func refresh() {
        // Build locally and assign once so subscribers never see a transient
        // empty list mid-refresh. See issue #227.
        var rebuilt: [DisplayPortUpdate] = []
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPortTransportStateDisplayPort"), &iter) == KERN_SUCCESS {
            while case let service = IOIteratorNext(iter), service != 0 {
                if let update = makeUpdate(from: service) {
                    rebuilt.removeAll { $0.entryID == update.entryID }
                    rebuilt.append(update)
                }
                IOObjectRelease(service)
            }
            IOObjectRelease(iter)
        }
        let next = enrichedWithLiveMode(rebuilt)
        if next != statuses { statuses = next }
    }

    private func handleAdded(_ iterator: io_iterator_t) {
        var changed = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            if let update = makeUpdate(from: service) {
                statuses.removeAll { $0.entryID == update.entryID }
                statuses.append(update)
                changed = true
            }
            IOObjectRelease(service)
        }
        // Attach the live on-screen mode to the newly added display(s) so the
        // popover, widget, CLI, and Diagnostics window all agree (DAR-159).
        if changed { statuses = enrichedWithLiveMode(statuses) }
    }

    /// Attach the live CoreGraphics on-screen mode (`currentMode` / `maxMode`)
    /// to each published status, at this single source. Every consumer of
    /// `statuses` (the main-popover port card, the widget, the CLI snapshot, and
    /// the Pro Diagnostics window) then sees the same live-mode verdict. Before
    /// this, surfaces that read `statuses` without calling `DisplayModeReader`
    /// themselves (the popover card and the widget) fell back to the EDID and
    /// showed a stale verdict, for example "may be using compression" while the
    /// Diagnostics panel said "full quality" for the same display (DAR-159).
    /// `enrich` is a pure, order- and count-preserving map, so re-pairing by
    /// index is safe.
    private func enrichedWithLiveMode(_ updates: [DisplayPortUpdate]) -> [DisplayPortUpdate] {
        let modes = DisplayModeReader.enrich(updates.map(\.status))
        guard modes.count == updates.count else { return updates }
        return zip(updates, modes).map { update, status in
            DisplayPortUpdate(
                entryID: update.entryID,
                portIndex: update.portIndex,
                portType: update.portType,
                status: status
            )
        }
    }

    private func handleRemoved(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            // Remove by registry entry id, the same per-node key makeUpdate
            // stores. The entry id is kernel-assigned and readable even while
            // the service is being torn down, so it matches exactly the node
            // that went away and never the other display on the same port when
            // a dock drives two monitors through one port (issue #271).
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { continue }
            statuses.removeAll { $0.entryID == entryID }
        }
    }

    // MARK: - IOKit wrapper (private)

    private func makeUpdate(from service: io_service_t) -> DisplayPortUpdate? {
        // Read keys individually rather than fetching the full property
        // dictionary. The bulk fetch (IORegistryEntryCreateCFProperties)
        // can abort the process from inside IOCFUnserializeBinary when
        // the kernel returns a malformed serialised properties blob,
        // typically when the service is being torn down mid-read. The
        // per-key call has no such failure path. See issue #181.
        func read(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        // Unique, stable per-node identity used as the dedup key (issue #271).
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return nil }

        let portIndex = wcPortIndex(read: read, service: service)
        let portType = wcPortType(read: read, service: service)
        // Walk the parent chain to capture the HPM controller UUID.
        // DisplayPort nodes sit at Port-USB-C@N/DisplayPort, so the controller
        // is ~2 steps up (AppleHPMInterfaceType10 -> AppleHPMDeviceHALType3).
        let uuid = wcHPMControllerUUID(for: service)

        return Self.makeUpdate(
            entryID: entryID,
            read: read,
            portIndex: portIndex,
            portType: portType,
            hpmControllerUUID: uuid
        )
    }

    // MARK: - Parse function (internal, testable)

    /// Parse a DisplayPort transport update from a property-read closure.
    /// The `portIndex`, `portType`, and `hpmControllerUUID` are passed in so
    /// the caller (the IOKit wrapper) can resolve them once and tests can
    /// supply fixed values without IOKit.
    nonisolated static func makeUpdate(
        entryID: UInt64,
        read: (String) -> Any?,
        portIndex: Int,
        portType: String,
        hpmControllerUUID: String?
    ) -> DisplayPortUpdate? {
        let link = DisplayPortLink(
            active: wcBool(read("Active")),
            laneCount: wcInt(read("LaneCount")),
            maxLaneCount: wcInt(read("MaxLaneCount")),
            linkRate: wcInt(read("LinkRate")),
            linkRateDescription: read("LinkRateDescription") as? String,
            tunneled: wcBool(read("Tunneled")),
            hpdState: wcInt(read("HPD_State")),
            hpdStateDescription: read("HPD_StateDescription") as? String
        )

        let metadata = read("Metadata") as? [String: Any]
        let monitor = MonitorInfo(
            manufacturerName: (read("ManufacturerName") as? String)
                ?? (metadata?["ManufacturerName"] as? String),
            productName: (read("ProductName") as? String)
                ?? (metadata?["ProductName"] as? String),
            productId: read("ProductID").map(wcInt)
                ?? metadata?["ProductID"].map(wcInt),
            serialNumber: read("SerialNumber").map(wcInt)
                ?? metadata?["SerialNumber"].map(wcInt),
            yearOfManufacture: read("YearOfManufacture").map(wcInt)
                ?? metadata?["Year of Manufacture"].map(wcInt),
            weekOfManufacture: metadata?["Week of Manufacture"].map(wcInt),
            edid: wcData(read("EDID")) ?? wcData(metadata?["EDID"])
        )

        // NominalSignalingFrequenciesHz can be an opaque CFType in some
        // text dumps; only decode it when it arrives as an array.
        let freqs: [Int]
        if let arr = read("NominalSignalingFrequenciesHz") as? [Any] {
            freqs = arr.map { wcInt($0) }
        } else {
            freqs = []
        }

        let status = IOPortTransportStateDisplayPort(
            link: link,
            monitor: monitor,
            dfpType: (read("DFP Type Description") as? String)
                ?? (metadata?["DFP Type Description"] as? String)
                ?? read("DFP Type").map { String(wcInt($0)) },
            branchDeviceId: (read("BranchDeviceID") as? String)
                ?? (metadata?["BranchDeviceID"] as? String),
            branchDeviceOUI: wcData(read("BranchDeviceOUI"))
                ?? wcData(metadata?["BranchDeviceOUI"]),
            sinkCount: wcInt(read("SinkCount")),
            role: wcInt(read("Role")),
            roleDescription: read("RoleDescription") as? String,
            driverStatus: wcInt(read("DriverStatus")),
            driverStatusDescription: read("DriverStatusDescription") as? String,
            transportType: wcInt(read("TransportType")),
            transportTypeDescription: read("TransportTypeDescription") as? String,
            transportDescription: read("TransportDescription") as? String,
            authorizationRequired: wcBool(read("AuthorizationRequired")),
            authorizationStatus: wcInt(read("AuthorizationStatus")),
            authorizationStatusDescription: read("AuthorizationStatusDescription") as? String,
            authenticationRequired: wcBool(read("AuthenticationRequired")),
            authenticationStatus: wcInt(read("AuthenticationStatus")),
            authenticationStatusDescription: read("AuthenticationStatusDescription") as? String,
            hashStatus: wcInt(read("HashStatus")),
            hashStatusDescription: read("HashStatusDescription") as? String,
            trmTransportSupervised: wcBool(read("TRM_TransportSupervised")),
            parentPortType: wcInt(read("ParentPortType")),
            parentPortTypeDescription: read("ParentPortTypeDescription") as? String,
            parentPortNumber: wcInt(read("ParentPortNumber")),
            parentPortBuiltIn: wcBool(read("ParentPortBuiltIn")),
            parentBuiltInPortType: wcInt(read("ParentBuiltInPortType")),
            parentBuiltInPortTypeDescription: read("ParentBuiltInPortTypeDescription") as? String,
            parentBuiltInPortNumber: wcInt(read("ParentBuiltInPortNumber")),
            edidChanged: wcBool(read("EDIDChanged")),
            nominalSignalingFrequenciesHz: freqs,
            index: wcInt(read("Index")),
            hpmControllerUUID: hpmControllerUUID
        )
        return DisplayPortUpdate(
            entryID: entryID,
            portIndex: portIndex,
            portType: portType,
            status: status
        )
    }
}
