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
import IOKit.usb
import os

@MainActor
public final class USBWatcher: ObservableObject {
    @Published public private(set) var devices: [USBDevice] = []

    // nonisolated so `classifyAncestry` (a nonisolated static pure function)
    // can log from off the main actor. Logger is a Sendable struct.
    nonisolated private static let log = Logger(subsystem: "uk.whatcable.whatcable", category: "usb")

    private var notifyPort: IONotificationPortRef?
    private var addedIter: io_iterator_t = 0
    private var removedIter: io_iterator_t = 0

    public init() {}

    public func start() {
        guard notifyPort == nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let addedCallback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<USBWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak watcher] in watcher?.handleAdded(iterator: iterator) }
        }

        let removedCallback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<USBWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak watcher] in watcher?.handleRemoved(iterator: iterator) }
        }

        // IOServiceAddMatchingNotification consumes one reference to the matching
        // dictionary, so call IOServiceMatching fresh for each registration.
        // Only drain the iterator when registration succeeds; the out-parameter
        // iterator is only valid on KERN_SUCCESS, and passing an uninitialised
        // value to IOIteratorNext is undefined behaviour.
        if IOServiceAddMatchingNotification(
            port,
            kIOMatchedNotification,
            IOServiceMatching("IOUSBHostDevice"),
            addedCallback,
            selfPtr,
            &addedIter
        ) == KERN_SUCCESS {
            handleAdded(iterator: addedIter)
        }

        if IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching("IOUSBHostDevice"),
            removedCallback,
            selfPtr,
            &removedIter
        ) == KERN_SUCCESS {
            handleRemoved(iterator: removedIter)
        }
    }

    public func stop() {
        if addedIter != 0 { IOObjectRelease(addedIter); addedIter = 0 }
        if removedIter != 0 { IOObjectRelease(removedIter); removedIter = 0 }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        devices.removeAll()
    }

    private func handleAdded(iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            if let device = makeDevice(from: service) {
                if !devices.contains(where: { $0.id == device.id }) {
                    devices.append(device)
                }
            }
            IOObjectRelease(service)
        }
        devices.sort { ($0.productName ?? "") < ($1.productName ?? "") }
    }

    private func handleRemoved(iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS {
                devices.removeAll { $0.id == entryID }
            }
            IOObjectRelease(service)
        }
    }

    private func makeDevice(from service: io_service_t) -> USBDevice? {
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return nil }

        // USBWatcher uses the bulk fetch intentionally: it iterates all keys
        // from the returned dictionary to populate `rawProperties` on USBDevice.
        // There is no fixed key list, so per-key reads are not feasible here.
        // USB device services are stable (not torn-down mid-read), so the
        // IOCFUnserializeBinary crash path described in issue #181 does not
        // apply. See also: AppleHPMInterfaceWatcher.makePort for the contrast.
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        let vendorID = (dict["idVendor"] as? NSNumber)?.uint16Value ?? 0
        let productID = (dict["idProduct"] as? NSNumber)?.uint16Value ?? 0
        let locationID = (dict["locationID"] as? NSNumber)?.uint32Value ?? 0
        let speedRaw = (dict["Device Speed"] as? NSNumber)?.uint8Value
        let bcdUSB = (dict["bcdUSB"] as? NSNumber)?.uint16Value
        let busPower = (dict["Bus Power Available"] as? NSNumber).map { $0.intValue * 2 }
        let current = (dict["Requested Power"] as? NSNumber).map { $0.intValue * 2 }
        let deviceClass = (dict["bDeviceClass"] as? NSNumber)?.uint8Value

        // The leaf IOKit class. A Billboard device enumerates as
        // "AppleUSBHostBillboardDevice" (a subclass of IOUSBHostDevice, so the
        // matcher above still catches it). Used as a detection signal that
        // doesn't depend on the product-name string.
        // Only trust the buffer when the call succeeds; on failure IOKit does
        // not guarantee it leaves the buffer untouched, and USBDevice's
        // contract is that ioClassName is nil when unavailable.
        var classBuf = [CChar](repeating: 0, count: 128)
        let ioClassName = IOObjectGetClass(service, &classBuf) == KERN_SUCCESS
            ? String(cString: classBuf)
            : nil

        var raw: [String: String] = [:]
        for (k, v) in dict {
            raw[k] = stringify(v)
        }

        let (busIdx, portName, tunnelled, behindInternalHub) = controllerInfo(
            for: service,
            fallback: locationID,
            ownUSBPortType: (dict["USBPortType"] as? NSNumber)?.intValue,
            deviceClass: deviceClass
        )

        // Read the Billboard Capability Descriptor (advertised Alt Modes and
        // their per-mode state) once, here at device-appearance. One-shot
        // control transfer, no device-open. See DAR-141.
        //
        // We probe every device deliberately, NOT just Billboard-class ones.
        // Functional docks, hubs and AV adapters advertise a Billboard
        // capability inside their ordinary BOS (seen on 103 such devices across
        // 71 machines in the customer-probe corpus), and the Pro Cable
        // Diagnostics screen surfaces those alt modes; gating to Billboard-class
        // devices would blank that table for them. The freeze in issue #370
        // came purely from a force-open fallback that no longer exists; the
        // no-open read here is harmless on a device a kernel driver holds.
        let billboard = BillboardDescriptorReader.read(from: service)

        return USBDevice(
            id: entryID,
            locationID: locationID,
            vendorID: vendorID,
            productID: productID,
            vendorName: dict["USB Vendor Name"] as? String,
            productName: dict["USB Product Name"] as? String,
            serialNumber: dict["USB Serial Number"] as? String,
            usbVersion: bcdUSB.map { formatBCD($0) },
            speedRaw: speedRaw,
            busPowerMA: busPower,
            currentMA: current,
            busIndex: busIdx,
            controllerPortName: portName,
            isThunderboltTunnelled: tunnelled,
            isBehindInternalHub: behindInternalHub,
            deviceClass: deviceClass,
            ioClassName: ioClassName,
            billboard: billboard,
            rawProperties: raw
        )
    }

    /// One hop of the IOService-plane parent walk above a USB device, as
    /// consumed by `classifyAncestry`. The live walk builds these in
    /// `collectAncestors`; the corpus sweep rebuilds them from probe 38
    /// captures (`38_usb_device_tree`), so the exact same classification code
    /// runs in production and against every recorded real machine.
    struct USBAncestor: Equatable, Sendable {
        /// IOKit class name (IOObjectGetClass).
        let className: String
        /// The ancestor's `locationID`, when it has one. Captured on every hop
        /// so the classification can take the bus index from whichever
        /// controller ends the walk.
        let locationID: UInt32?
        /// The ancestor's `UsbIOPort` registry path, already resolved from its
        /// String/Data raw form via `usbIOPortPath(from:)`. nil when absent.
        let usbIOPortPath: String?
        /// The ancestor's `USBPortType`. Only populated when the node conforms
        /// to `IOUSBHostDevice` (the hubs and devices), mirroring the
        /// conformance gate the live walk applies before reading the key.
        let usbPortType: Int?
        /// Whether the node conforms to `IOUSBHostDevice` at all, i.e. is a
        /// hub or device rather than port/controller plumbing. Used by the
        /// embedded-branch plumbing rule: a hub with NO conforming ancestor
        /// sits directly on the controller's root ports.
        let conformsToUSBHostDevice: Bool
    }

    /// The decisions `controllerInfo` derives from the parent walk.
    /// `reachedNativeController` is exposed alongside the four consumed values
    /// so tests and sweeps can assert on the gate itself, not just its effect.
    struct AncestryClassification: Equatable, Sendable {
        /// Upper byte of the terminating controller's `locationID`, or nil when
        /// the walk ended without reading one (caller falls back to the
        /// device's own locationID).
        let busIndex: Int?
        /// Physical port service name (e.g. "Port-USB-C@1") from the first
        /// `UsbIOPort` ancestor, or nil.
        let portName: String?
        /// The device reached the Mac over a Thunderbolt PCIe tunnel.
        let tunnelled: Bool
        /// The walk ended at a native Apple Silicon controller (`AppleT*USBXHCI`).
        let reachedNativeController: Bool
        /// The walk ended at an Apple-embedded board controller
        /// (`isEmbeddedBuiltInController`): the Mac's own extra built-in
        /// plain-USB wiring (discussion #417).
        let reachedEmbeddedController: Bool
        /// The device is on a desktop Mac's plain-USB built-in port, either
        /// via the no-port-node native path (issue #348) or behind an
        /// Apple-embedded board controller (discussion #417).
        let behindInternalHub: Bool
    }

    /// Classifies a USB device from its IOService-plane ancestor chain,
    /// collecting these pieces of information:
    ///   - `portName`: parsed from the first ancestor with a `UsbIOPort`
    ///     property. These are the `usb-drd*-port-hs/ss` nodes that sit
    ///     between the device and the `AppleT*USBXHCI` controller. Their
    ///     `UsbIOPort` value is a registry path ending in the physical port's
    ///     service name (e.g. ".../Port-USB-C@1").
    ///   - `busIndex`: upper byte of the XHCI controller's `locationID`, kept
    ///     as a fallback for older topologies that don't expose `UsbIOPort`
    ///     (and for the advanced view).
    ///   - `tunnelled`: the device reached the Mac over a Thunderbolt PCIe
    ///     tunnel. Either the chain runs through `AppleUSBXHCITR`, the native
    ///     USB tunnel (issue #274), or through a Thunderbolt 3 dock's own PCIe
    ///     USB host controller (`isThunderboltDockController`).
    ///   - `behindInternalHub`: the device is on a desktop Mac's plain-USB
    ///     front port. Detected structurally: the walk reaches a native
    ///     controller, is not tunnelled, and finds no `UsbIOPort` ancestor
    ///     (no `Port-USB-C@N` match). See the gate below the loop (issue #348).
    ///
    /// Pure: no IOKit. This is the seam that makes the walk replayable from
    /// probe 38 corpus captures (`USBWatcherCorpusSweepTests`); the live half
    /// is `collectAncestors`, which only gathers, never decides.
    /// - Parameter ownUSBPortType: the DEVICE's own `USBPortType` property
    ///   (the kind of port the device itself is plugged into), read from its
    ///   property dictionary in `makeDevice`. Used only in the embedded
    ///   branch: a value of `internalHubPortType` (2) means the device is
    ///   plugged into a port internal to the Mac's board, i.e. it IS the
    ///   Mac's own hub silicon, not something the user attached.
    /// - Parameter deviceClass: the device's own `bDeviceClass`. Used only in
    ///   the embedded branch: class 9 (hub) with no hub ancestor is the
    ///   Mac's own root fan-out silicon (see the plumbing rule below).
    nonisolated static func classifyAncestry(
        _ ancestors: [USBAncestor],
        ownUSBPortType: Int? = nil,
        deviceClass: UInt8? = nil
    ) -> AncestryClassification {
        var portName: String?
        var bus: Int?
        var tunnelled = false
        // Set when the walk lands on a *native* Apple Silicon USB host
        // controller (`AppleT*USBXHCI`), as opposed to the tunnelled
        // `AppleUSBXHCITR`. Used below to gate the internal-hub classification.
        var reachedNativeController = false
        // Set when the walk lands on an Apple-embedded third-party controller
        // (`AppleEmbedded*USBXHCI*`): built-in plain-USB wiring, see the
        // branch below.
        var reachedEmbeddedController = false
        // `USBPortType` of the nearest USB hub this device hangs off (the first
        // `IOUSBHostDevice` ancestor we meet going up). It reports the kind of
        // port that hub is plugged into: the Mac's own internal hubs report
        // `internalHubPortType` (2), external hubs report 0. nil when the device
        // sits on no hub. Used to tell a genuine built-in-port device apart from
        // one behind an external hub (issue #373).
        var hubPortType: Int?

        // Whether any ancestor before the terminating controller conforms to
        // IOUSBHostDevice, i.e. the device hangs off a hub rather than
        // sitting directly on the controller's root ports.
        var hasHubAncestor = false

        for ancestor in ancestors {
            if ancestor.conformsToUSBHostDevice { hasHubAncestor = true }
            if portName == nil, let portPath = ancestor.usbIOPortPath {
                if let name = Self.portName(fromUSBIOPortPath: portPath) {
                    portName = name
                } else {
                    // Found a `UsbIOPort` ancestor, but its path tail isn't a
                    // recognised `Port-*` node. Without a port name the device
                    // is later treated as port-less and, on a desktop, surfaced
                    // as a front-port device (issue #348). If a future Apple
                    // Silicon generation renames the port node, this is the
                    // silent failure mode; log it so it's diagnosable. The path
                    // is IOKit topology, not PII.
                    Self.log.debug("UsbIOPort path has no recognised port node: \(portPath, privacy: .public)")
                }
            }

            // Take the `USBPortType` of the nearest hub only, the first one
            // going up: a device behind an external hub that is itself plugged
            // into the Mac's internal hub must read the external hub's value
            // (0), not the internal one further up the chain (issue #373).
            if hubPortType == nil, let pt = ancestor.usbPortType {
                hubPortType = pt
            }

            // The tunnelled host controller for devices behind a Thunderbolt
            // dock or display (issue #274). It plays the same role as the native
            // XHCI controller below, but reached over the TB PCIe tunnel, so we
            // flag the device and stop the walk at it. There is no `UsbIOPort`
            // on this path, so `portName` stays nil and the device matches no
            // physical port.
            if ancestor.className.hasPrefix("AppleUSBXHCITR") {
                tunnelled = true
                if let loc = ancestor.locationID { bus = Self.busIndex(fromLocationID: loc) }
                break
            }
            if ancestor.className.hasPrefix("AppleT") && ancestor.className.hasSuffix("USBXHCI") {
                reachedNativeController = true
                if let loc = ancestor.locationID { bus = Self.busIndex(fromLocationID: loc) }
                break
            }
            // Apple-embedded third-party controller: the Mac's own extra
            // built-in plain-USB wiring (Mac Studio front ports and back
            // USB-A, M1 Mac mini USB-A block), soldered to the board but
            // driven by third-party silicon (`AppleEmbeddedUSBXHCIASMedia3142`,
            // `AppleEmbeddedUSBXHCIFL1100`). Before this branch existed these
            // fell through to the dock rule below and were wrongly grouped
            // under "reached through a Thunderbolt dock" (discussion #417 on
            // a Mac Studio). The `AppleEmbedded` prefix is Apple's own marker
            // for board-mounted controllers: across the whole customer-probe
            // corpus every `AppleEmbedded*` stop is a desktop Mac and no real
            // dock ever carries the prefix.
            if Self.isEmbeddedBuiltInController(ancestor.className) {
                reachedEmbeddedController = true
                // Like the dock branch below, deliberately no `locationID`
                // read: built-in devices are grouped by flag, never matched
                // by bus index, so `bus` is left to the caller's fallback.
                break
            }
            // A Thunderbolt 3 dock (e.g. CalDigit TS3+) brings its own PCIe USB
            // host controller rather than tunnelling USB natively, so its
            // downstream devices enumerate under a third-party XHCI driver class
            // (`AppleUSBXHCIFL1100`, `AppleASMediaUSBXHCI`, `AppleUSBXHCIAR`,
            // ...) instead of `AppleUSBXHCITR`. Those devices still reached the
            // Mac over the Thunderbolt PCIe tunnel and have no `UsbIOPort`
            // ancestor, so we flag them tunnelled and stop, exactly like the
            // native-tunnel case above. Confirmed on TS3+ hardware
            // (m4_macos27.0_c / m1pro_macos26.5.1_i in the customer-probe
            // corpus). We do not read `locationID` here: a tunnelled device is
            // attributed to its port by Thunderbolt topology, not bus index, so
            // `bus` is left to the caller's fallback.
            if Self.isThunderboltDockController(ancestor.className) {
                tunnelled = true
                break
            }
        }

        // Everything behind an embedded controller is a built-in plain-USB
        // port, so it belongs in the "Built-in USB ports" section (issue #348
        // UX), not under a dock or a port card. Its `UsbIOPort` board node
        // (e.g. "Port-USB-A@1") is KEPT on the record exactly as macOS
        // reports it (owner rule: identifiers are never dropped; it is raw
        // registry truth and a research join key). It is shared by every
        // port on the controller, front USB-C and back USB-A alike, so it
        // must never drive DISPLAY attribution: grouping routes these
        // devices by the behindInternalHub flag, and the port-card matcher
        // cannot match it (a Port-USB-A name never equals a Port-USB-C
        // card, and a named device is excluded from the bus-index
        // fallback), so no double-render is possible.
        //
        // One exclusion (raised across both PR 408 review rounds): the
        // embedded controller's own hub silicon also enumerates as USB
        // devices, and flagging THOSE would render the Mac's plumbing as
        // permanently connected devices in the card. Two hardware signals
        // identify plumbing, and BOTH are needed (verified over every
        // embedded chain in the 524-machine corpus: 16 plumbing exclusions,
        // all visibly Apple silicon; 33 user devices, all kept):
        //   - own `USBPortType == internalHubPortType` (2): Apple marks its
        //     internal hubs as plugged into board-internal ports (the
        //     Studio ASMedia fan-out hubs).
        //   - a hub-class device (bDeviceClass 9) with NO hub ancestor: it
        //     sits directly on the controller's root ports, so it IS the
        //     controller's own fan-out (the M1 mini FL1100 root-hub
        //     personas, which do NOT carry USBPortType=2). Non-hub devices
        //     directly on the controller are real user hardware (an iPhone
        //     on an M1 mini USB-A port does exactly this) and are kept.
        // Residual, documented: a USER hub plugged into a direct-wired
        // USB-A port would match the second signal and be excluded; zero
        // such cases exist in the corpus, and its children would still
        // render (unnested), so the failure mode is mild. Excluded plumbing
        // renders nowhere, exactly like the mini's internal hub on the
        // native path.
        //
        // ASSUMPTION (same class as the AppleT-prefix note on
        // isThunderboltDockController): AppleEmbedded* controllers only
        // exist on desktop Macs (every corpus occurrence is a desktop; the
        // sweep cross-checks this against probe-32 form factors). If a
        // future LAPTOP shipped one, its devices would classify
        // behind-internal-hub here and then be dropped by the desktop gate
        // in TunnelledDeviceGrouping.group, vanishing from the UI. Revisit
        // if the embedded-implies-desktop sweep ever fails.
        let isOwnInternalPlumbing = ownUSBPortType == Self.internalHubPortType
            || (deviceClass == 9 && !hasHubAncestor)
        let behindInternalHub = (reachedEmbeddedController && !isOwnInternalPlumbing)
            || Self.classifyBehindInternalHub(
            reachedNativeController: reachedNativeController,
            tunnelled: tunnelled,
            portName: portName,
            underInternalHub: hubPortType == Self.internalHubPortType
        )

        return AncestryClassification(
            busIndex: bus,
            portName: portName,
            tunnelled: tunnelled,
            reachedNativeController: reachedNativeController,
            reachedEmbeddedController: reachedEmbeddedController,
            behindInternalHub: behindInternalHub
        )
    }

    /// True when `className` is an Apple-embedded third-party USB host
    /// controller: board-mounted silicon driving a desktop Mac's extra
    /// built-in plain-USB ports (Mac Studio front ports and back USB-A, M1
    /// Mac mini USB-A block). Apple's own driver naming carries the
    /// distinction: embedded controllers get the `AppleEmbedded` prefix
    /// (`AppleEmbeddedUSBXHCIASMedia3142`, `AppleEmbeddedUSBXHCIFL1100`);
    /// the same silicon inside a dock enumerates without it
    /// (`AppleASMediaUSBXHCI`, `AppleUSBXHCIFL1100`). Verified across the
    /// customer-probe corpus: every `AppleEmbedded*` stop is a desktop Mac,
    /// and none of the 42 real-dock chains carries the prefix.
    ///
    /// Pure so it is unit-testable without IOKit.
    nonisolated static func isEmbeddedBuiltInController(_ className: String) -> Bool {
        className.hasPrefix("AppleEmbedded") && className.contains("USBXHCI")
    }

    /// True when `className` is a host controller that ends the ancestor walk
    /// (native, tunnel, embedded, or dock: the same four cases
    /// `classifyAncestry` breaks on, composed from the same predicates so the
    /// two can't drift). Used by `collectAncestors` to stop gathering at the
    /// controller, exactly where the pure classification stops reading.
    nonisolated static func isWalkTerminator(_ className: String) -> Bool {
        className.hasPrefix("AppleUSBXHCITR")
            || (className.hasPrefix("AppleT") && className.hasSuffix("USBXHCI"))
            || isEmbeddedBuiltInController(className)
            || isThunderboltDockController(className)
    }

    /// Live half of the ancestor walk: gathers IOService-plane parents of a
    /// USB device into `USBAncestor` records, reading only the properties
    /// `classifyAncestry` consumes, and stopping at the first host controller
    /// (`isWalkTerminator`), which is included as the final record. Gathers,
    /// never decides: all classification logic lives in the pure function so
    /// the corpus sweep can run the real thing.
    ///
    /// The 20-hop bound mirrors the old in-line walk: the real depth from a
    /// USB device to its host controller is small (2-4 hops directly attached;
    /// a few more behind chained hubs), so 20 is far beyond anything observed
    /// and just acts as a backstop against a malformed or cyclic registry.
    private static func collectAncestors(of service: io_service_t) -> [USBAncestor] {
        var ancestors: [USBAncestor] = []
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        for _ in 0..<20 {
            var parent: io_service_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                break
            }
            IOObjectRelease(current)
            current = parent

            var classBuf = [CChar](repeating: 0, count: 128)
            let className = IOObjectGetClass(current, &classBuf) == KERN_SUCCESS
                ? String(cString: classBuf)
                : ""

            let locationID = (IORegistryEntryCreateCFProperty(
                current, "locationID" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? NSNumber)?.uint32Value

            var usbIOPortPath: String?
            if let raw = IORegistryEntryCreateCFProperty(
                current, "UsbIOPort" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() {
                usbIOPortPath = Self.usbIOPortPath(from: raw)
            }

            // Conformance gate: only `IOUSBHostDevice` nodes (the hubs and
            // devices) carry a meaningful `USBPortType`; reading it elsewhere
            // would let an unrelated node shadow the nearest hub's value.
            let conforms = IOObjectConformsTo(current, "IOUSBHostDevice") != 0
            var usbPortType: Int?
            if conforms {
                usbPortType = (IORegistryEntryCreateCFProperty(
                    current, "USBPortType" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? NSNumber)?.intValue
            }

            ancestors.append(USBAncestor(
                className: className,
                locationID: locationID,
                usbIOPortPath: usbIOPortPath,
                usbPortType: usbPortType,
                conformsToUSBHostDevice: conforms
            ))

            // Stop at the host controller, like the old in-line walk did:
            // nothing above it is read, live or replayed.
            if Self.isWalkTerminator(className) { break }
        }
        return ancestors
    }

    /// Walks the IOKit parent chain from a USB device and classifies it. See
    /// `classifyAncestry` for what is derived and how; this wrapper only pairs
    /// the live collector with the pure classifier and applies the bus-index
    /// fallback.
    private func controllerInfo(
        for service: io_service_t,
        fallback locationID: UInt32,
        ownUSBPortType: Int?,
        deviceClass: UInt8?
    ) -> (Int?, String?, Bool, Bool) {
        let classification = Self.classifyAncestry(
            Self.collectAncestors(of: service),
            ownUSBPortType: ownUSBPortType,
            deviceClass: deviceClass
        )
        // Fallback: the device's own locationID upper byte mirrors its
        // controller's locationID upper byte on Apple Silicon.
        let bus = classification.busIndex ?? Self.busIndex(fromLocationID: locationID)
        return (bus, classification.portName, classification.tunnelled, classification.behindInternalHub)
    }

    /// `USBPortType` value Apple reports for a port that is internal to the Mac
    /// (`kIOUSBHostPortTypeInternal`). The Mac's own front-panel hub reports it;
    /// external hubs (including Apple's own Studio Display and keyboard hubs)
    /// report 0. Confirmed across the customer-probe corpus: this value is only
    /// ever reported by Apple internal hardware, only on desktop Macs, and every
    /// desktop's internal hub reports it.
    ///
    /// Cross-validated against Apple's own built-in marker: every hub that
    /// carries the `com.apple.developer.driverkit.builtin` entitlement reports
    /// `USBPortType == 2`, and every hub reporting 2 carries that entitlement
    /// (97/97 both ways across the corpus). So this value is exactly the set of
    /// Mac-internal hubs, no broader, no narrower. The corpus also has external
    /// hubs that are easy to mistake for internal (Microchip/Prolific/Intel
    /// generic hubs reporting `USBPortType == 5`, Studio Display hubs reporting
    /// 0); none carry the entitlement and none report 2. See
    /// `classifyBehindInternalHub`.
    nonisolated static let internalHubPortType = 2

    /// Structural front-port classification (issue #348). True when all four
    /// hold:
    ///   1. `reachedNativeController` -- the parent walk reached a native USB
    ///      host controller (`AppleT*USBXHCI`), not the Thunderbolt tunnel.
    ///   2. `!tunnelled` -- the walk did NOT go through `AppleUSBXHCITR`.
    ///   3. `portName == nil` -- no `UsbIOPort` ancestor, i.e. no `Port-USB-C@N`
    ///      match.
    ///   4. `underInternalHub` -- the hub this device hangs off is the Mac's own
    ///      internal hub (`USBPortType == internalHubPortType`), not an external
    ///      one.
    /// On a desktop Mac that means a device on a plain-USB front-panel port.
    /// Back-port devices always have a `usb-drd*-port-*` (`UsbIOPort`) ancestor,
    /// so they fail (3). TB-tunnelled devices fail (1)/(2).
    ///
    /// Condition (4) is what fixes issue #373. The earlier gate assumed
    /// `portName == nil` was enough to mean "behind the Mac's internal hub", but
    /// a device behind an *external* hub also has no `Port-USB-C@N` node and
    /// reaches the native controller, so its keyboard/mouse were wrongly grouped
    /// as built-in. The hub's `USBPortType` tells the two apart: only the Mac's
    /// internal hub reports `internalHubPortType`. Because this condition only
    /// makes the gate stricter, it can only drop the external-hub false
    /// positives, never reclassify a device that was already correct.
    ///
    /// This is pure structure, not a desktop guarantee: the desktop-only product
    /// policy is applied downstream in `TunnelledDeviceGrouping.group`. Pure so
    /// it is unit-testable without IOKit.
    nonisolated static func classifyBehindInternalHub(
        reachedNativeController: Bool,
        tunnelled: Bool,
        portName: String?,
        underInternalHub: Bool
    ) -> Bool {
        reachedNativeController && !tunnelled && portName == nil && underInternalHub
    }

    /// True when `className` is the third-party USB host controller a
    /// Thunderbolt 3 dock brings over its PCIe tunnel (Fresco Logic
    /// `AppleUSBXHCIFL1100`, `AppleASMediaUSBXHCI`, `AppleUSBXHCIAR`, and the
    /// like), as opposed to a native Apple Silicon controller (`AppleT*`),
    /// the native USB tunnel (`AppleUSBXHCITR`, handled separately), an
    /// Apple-embedded board controller (`AppleEmbedded*`, the Mac's own
    /// built-in plain-USB wiring, see `isEmbeddedBuiltInController`; treating
    /// these as docks was the discussion #417 bug), or an Intel built-in
    /// controller (Intel Macs are unsupported and do not enumerate these in
    /// practice). The match is structural: any `*USBXHCI` host controller that
    /// is none of those four is a dock-supplied controller, so its devices
    /// reached the Mac over Thunderbolt. Validated against every controller
    /// class name in the customer-probe corpus with zero false positives,
    /// including the M5 Pro/Max native `AppleT6050USBXHCIAUSS` (excluded by the
    /// `AppleT` prefix).
    ///
    /// ASSUMPTION: every native Apple Silicon USB host controller class starts
    /// with `AppleT` (true across M1-M5: T8103, T6000, T8112, T8122, T8132,
    /// T8142, T6050). If a future Apple chip family used a different prefix, its
    /// native controller would clear all three exclusions and be misread as a
    /// dock, so its back-port devices would surface under "Other USB devices"
    /// instead of their port. Revisit when a new silicon generation lands.
    ///
    /// Pure so it is unit-testable without IOKit.
    nonisolated static func isThunderboltDockController(_ className: String) -> Bool {
        className.contains("USBXHCI")
            && !className.hasPrefix("AppleT")
            && !className.hasPrefix("AppleUSBXHCITR")
            && !className.hasPrefix("AppleIntel")
            && !isEmbeddedBuiltInController(className)
    }

    nonisolated static func busIndex(fromLocationID locationID: UInt32) -> Int {
        Int((locationID >> 24) & 0xFF)
    }

    nonisolated static func usbIOPortPath(from value: Any) -> String? {
        if let string = value as? String {
            return string
        }
        if let data = value as? Data {
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters)
        }
        return nil
    }

    nonisolated static func portName(fromUSBIOPortPath path: String) -> String? {
        guard let last = path.split(separator: "/").last else { return nil }
        let name = String(last)
        return name.hasPrefix("Port-") ? name : nil
    }

    private func formatBCD(_ value: UInt16) -> String {
        let major = (value >> 8) & 0xFF
        let minor = (value >> 4) & 0xF
        let sub = value & 0xF
        return sub == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(sub)"
    }

    private func stringify(_ value: Any) -> String {
        switch value {
        case let n as NSNumber: return n.stringValue
        case let s as String: return s
        case let d as Data: return d.map { String(format: "%02X", $0) }.joined(separator: " ")
        case let a as [Any]: return "[\(a.map { stringify($0) }.joined(separator: ", "))]"
        default: return String(describing: value)
        }
    }
}

