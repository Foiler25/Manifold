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

/// Watches USB-C / MagSafe port-controller services. On Apple-silicon Macs the
/// relevant class is `AppleHPMInterfaceType10` (USB-C) and `Type11` (MagSafe).
@MainActor
public final class AppleHPMInterfaceWatcher: ObservableObject {
    @Published public private(set) var ports: [AppleHPMInterface] = []

    // Match only Type-C / MagSafe physical port controllers. Generic
    // `AppleUSBHostPort` would sweep in internal DRD (dual-role device)
    // ports — those have no physical connector and just confuse the UI.
    // The exact IOKit class for a USB-C port node varies by chip
    // generation. M3-era machines expose `AppleHPMInterfaceType10/11/12`;
    // M1 and M2 expose `AppleTCControllerType10/11`; MacBook Neo
    // (A-series) uses `AppleHPMInterfaceType18`. Apple-silicon desktop
    // front USB-C ports (Mac mini, Studio) are plain USB behind an
    // internal hub with no port-controller node, so they never appear
    // here regardless of class (see issue #291). `IOPort` is the shared
    // superclass of these port nodes, kept as a defensive catch-all, not
    // a front-port mechanism. It is probably redundant on M3+ (the HPM
    // classes above are `IOPort` subclasses, already matched by name), but
    // it is left in deliberately: dropping it is a behaviour change that
    // could hide a USB-C port on hardware we haven't tested, for no proven
    // gain. Revisit only if it ever pulls in noise. The
    // `PortTypeDescription` / `Port-` filter in `makePort` drops anything
    // that isn't a real physical port.
    nonisolated static let candidateClasses = [
        "AppleHPMInterfaceType10",
        "AppleHPMInterfaceType11",
        "AppleHPMInterfaceType12",
        "AppleHPMInterfaceType18",
        "AppleTCControllerType10",
        "AppleTCControllerType11",
        "IOPort"
    ]

    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    // Interest notifications registered per-port so we hear about property
    // changes (connection state, contract negotiation) as they happen, instead
    // of relying purely on polling. Keyed by registry entry ID so we don't
    // double-register when a port is rediscovered during a manual refresh.
    private var interestNotifications: [UInt64: io_object_t] = [:]

    public init() {}

    public func start() {
        guard notifyPort == nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let cb: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<AppleHPMInterfaceWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak watcher] in watcher?.drain(iterator: iterator) }
        }

        for cls in Self.candidateClasses {
            let matching = IOServiceMatching(cls)
            var iter: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, kIOMatchedNotification, matching, cb, selfPtr, &iter) == KERN_SUCCESS {
                iterators.append(iter)
                drain(iterator: iter)
            }
        }
    }

    public func stop() {
        for iter in iterators { IOObjectRelease(iter) }
        iterators.removeAll()
        for (_, n) in interestNotifications { IOObjectRelease(n) }
        interestNotifications.removeAll()
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        ports.removeAll()
    }

    /// Re-walk the registry. Property changes (cable plug/unplug) don't fire
    /// match notifications, so callers poll this on demand. Builds the new
    /// list in a local array and assigns once, so observers see a single
    /// transition instead of an empty intermediate state. Skips the
    /// assignment entirely when nothing changed, which keeps the UI calm
    /// when refresh() is called speculatively after every device event.
    public func refresh() {
        var rebuilt: [AppleHPMInterface] = []
        var liveEntryIDs: Set<UInt64> = []

        for cls in Self.candidateClasses {
            let matching = IOServiceMatching(cls)
            var iter: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS {
                while case let service = IOIteratorNext(iter), service != 0 {
                    if let port = makePort(from: service),
                       !rebuilt.contains(where: { $0.id == port.id }) {
                        rebuilt.append(port)
                        liveEntryIDs.insert(port.id)
                        registerInterest(for: service, entryID: port.id)
                    }
                    IOObjectRelease(service)
                }
                IOObjectRelease(iter)
            }
        }

        // Prune interest notifications for port services that are no longer
        // present in the registry. Only kIOMatchedNotification is registered
        // (no terminated callback), so without this prune, stale io_object_t
        // handles would accumulate across plug/unplug cycles without limit.
        // Each handle is a Mach port reference and must be released explicitly.
        for entryID in interestNotifications.keys where !liveEntryIDs.contains(entryID) {
            if let n = interestNotifications.removeValue(forKey: entryID) {
                IOObjectRelease(n)
            }
        }

        rebuilt.sort { lhs, rhs in
            let lhsActive = lhs.connectionActive == true
            let rhsActive = rhs.connectionActive == true
            if lhsActive != rhsActive { return lhsActive }
            return lhs.serviceName < rhs.serviceName
        }
        if rebuilt != ports { ports = rebuilt }
    }

    private func drain(iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            if let port = makePort(from: service), !ports.contains(where: { $0.id == port.id }) {
                ports.append(port)
                registerInterest(for: service, entryID: port.id)
            }
            IOObjectRelease(service)
        }
        // Active connections first, then alphabetically within each group.
        ports.sort { lhs, rhs in
            let lhsActive = lhs.connectionActive == true
            let rhsActive = rhs.connectionActive == true
            if lhsActive != rhsActive { return lhsActive }
            return lhs.serviceName < rhs.serviceName
        }
    }

    /// Subscribe to property/state changes on a port controller. The kernel
    /// fires `kIOMessageServicePropertyChange` (and related lifecycle
    /// messages) when a cable is plugged or unplugged, so this gives us a
    /// timely refresh trigger that doesn't depend on polling.
    private func registerInterest(for service: io_service_t, entryID: UInt64) {
        guard let notifyPort, interestNotifications[entryID] == nil else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let cb: IOServiceInterestCallback = { refcon, _, _, _ in
            guard let refcon else { return }
            let watcher = Unmanaged<AppleHPMInterfaceWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak watcher] in watcher?.refresh() }
        }
        var notification: io_object_t = 0
        let result = IOServiceAddInterestNotification(
            notifyPort,
            service,
            kIOGeneralInterest,
            cb,
            selfPtr,
            &notification
        )
        if result == KERN_SUCCESS {
            interestNotifications[entryID] = notification
        }
    }

    private func makePort(from service: io_service_t) -> AppleHPMInterface? {
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return nil }

        // Build the full registry entry name with its location suffix
        // (e.g. "Port-USB-C@1"). `IORegistryEntryGetName` returns just the
        // base name ("Port-USB-C"); the "@1" comes from
        // `IORegistryEntryGetLocationInPlane`. Devices reference ports by
        // this combined form via their XHCI controller's `UsbIOPort`
        // property, so the two must match.
        var nameBuf = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(service, &nameBuf)
        let baseName = String(cString: nameBuf)

        var locBuf = [CChar](repeating: 0, count: 128)
        let serviceName: String
        if IORegistryEntryGetLocationInPlane(service, kIOServicePlane, &locBuf) == KERN_SUCCESS {
            let location = String(cString: locBuf)
            serviceName = location.isEmpty ? baseName : "\(baseName)@\(location)"
        } else {
            serviceName = baseName
        }

        var classBuf = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(service, &classBuf) == KERN_SUCCESS else { return nil }
        let className = String(cString: classBuf)

        // Read keys individually rather than fetching the full property
        // dictionary. The bulk fetch (IORegistryEntryCreateCFProperties)
        // can abort the process from inside IOCFUnserializeBinary when
        // the kernel returns a malformed serialised properties blob,
        // typically when the service is being torn down mid-read. The
        // per-key call has no such failure path. See issue #181.
        func read(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        // Pass a bulk-fetch closure for rawProperties so the CLI verbose
        // and --raw output captures every key the HPM controller publishes,
        // not just the 26 known operational keys. HPM port services are
        // long-lived (boot to dock-removal), so the teardown crash window
        // is narrow. All operational fields come from per-key `read` calls;
        // this closure is only called to populate rawProperties.
        func readAll() -> [String: Any]? {
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
                return nil
            }
            return props?.takeRetainedValue() as? [String: Any]
        }

        return AppleHPMInterface.from(
            entryID: entryID,
            serviceName: serviceName,
            className: className,
            read: read,
            readAll: readAll,
            busIndex: busIndex(for: service),
            hpmControllerUUID: hpmControllerUUID(for: service)
        )
    }

    /// Walks the IOKit parent chain looking for a controller-index node. M3-era
    /// Macs commonly expose `hpm<N>`, while M1/M2 machines can expose `atc<N>`
    /// or `usb-drd<N>`. Direct `UsbIOPort` paths are still preferred.
    private func busIndex(for service: io_service_t) -> Int? {
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        for _ in 0..<8 {
            var nameBuf = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(current, &nameBuf)
            if let n = Self.busIndex(fromRegistryName: String(cString: nameBuf)) {
                return n
            }

            var parent: io_service_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                break
            }
            IOObjectRelease(current)
            current = parent
        }

        var locBuf = [CChar](repeating: 0, count: 128)
        if IORegistryEntryGetLocationInPlane(service, kIOServicePlane, &locBuf) == KERN_SUCCESS,
           let n = Self.busIndex(fromLocation: String(cString: locBuf)) {
            return n
        }

        return nil
    }

    /// Walks the IOKit parent chain to find the HPM power-controller node and
    /// returns its `UUID` property. The probe reads `AppleHPMDevice` (the base
    /// class) so it catches both M1/M2 (`AppleHPMDevice` exact) and M3+
    /// (`AppleHPMDeviceHALType3`, a subclass). This matches probe 35's
    /// class-agnostic sweep. Corpus (206 machines, 2026-07-13): **704/704 ports**
    /// carry a UUID -- 409/409 `AppleHPMDeviceHALType3` and 295/295
    /// `AppleHPMDevice` -- zero misses. The class PREDICATE is pinned everywhere
    /// by `HPMControllerClassGateTests` (pure fixtures) via the shared
    /// `wcIsHPMControllerClass`; the 704/704 corpus figure itself is only checked
    /// where probe 35 is on disk (gitignored, so not in CI).
    ///
    /// The UUID is an internal in-session join key only. It is stored on
    /// `AppleHPMInterface.hpmControllerUUID` and must never be serialised to
    /// `--json` / `--raw` or shown in the UI.
    ///
    /// Falls back to `nil` when the parent walk finds no HPM controller or the
    /// controller has no `UUID` property (defensive; corpus says never, but
    /// malformed or sandboxed cases could hit it).
    private func hpmControllerUUID(for service: io_service_t) -> String? {
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        for _ in 0..<8 {
            var classBuf = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(current, &classBuf)
            let cls = String(cString: classBuf)
            // Match both the M1/M2 base class and the M3+ subclass. Shared with
            // `wcHPMControllerUUID` so the two walks can never drift apart on
            // which classes count; see that predicate for why it must stay
            // class-agnostic.
            if wcIsHPMControllerClass(cls) {
                if let uuid = IORegistryEntryCreateCFProperty(
                    current,
                    "UUID" as CFString,
                    kCFAllocatorDefault,
                    0
                )?.takeRetainedValue() as? String, !uuid.isEmpty {
                    return uuid
                }
                // Found the controller but no UUID (e.g. M1/M2 variant without
                // the property). Stop walking; no point going further up.
                return nil
            }

            var parent: io_service_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                break
            }
            IOObjectRelease(current)
            current = parent
        }
        return nil
    }

    nonisolated static func busIndex(fromRegistryName name: String) -> Int? {
        for prefix in ["hpm", "atc", "usb-drd"] where name.hasPrefix(prefix) {
            let suffix = name.dropFirst(prefix.count)
            let digits = suffix.prefix { $0.isNumber }
            if !digits.isEmpty, let n = Int(digits) {
                return n
            }
        }
        return nil
    }

    nonisolated static func busIndex(fromLocation location: String) -> Int? {
        guard !location.isEmpty else { return nil }
        return Int(location, radix: 16)
    }
}

