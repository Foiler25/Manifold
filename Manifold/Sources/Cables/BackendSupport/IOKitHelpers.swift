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
import IOKit

public func wcInt(_ value: Any?) -> Int {
    if let n = value as? NSNumber { return n.intValue }
    if let i = value as? Int { return i }
    if let s = value as? String, let i = Int(s) { return i }
    return 0
}

public func wcUInt32(_ value: Any?) -> UInt32 {
    if let n = value as? NSNumber { return UInt32(truncatingIfNeeded: n.int64Value) }
    if let i = value as? Int { return UInt32(truncatingIfNeeded: i) }
    if let u = value as? UInt32 { return u }
    return 0
}

public func wcUInt8(_ value: Any?) -> UInt8 {
    UInt8(truncatingIfNeeded: wcInt(value))
}

public func wcBool(_ value: Any?) -> Bool {
    if let n = value as? NSNumber { return n.boolValue }
    if let b = value as? Bool { return b }
    return false
}

public func wcDictionary(_ value: Any?) -> [String: Any] {
    if let dict = value as? [String: Any] { return dict }
    if let nsDict = value as? NSDictionary {
        var converted: [String: Any] = [:]
        for case let (key, val) as (String, Any) in nsDict {
            converted[key] = val
        }
        return converted
    }
    return [:]
}

public func wcArray(_ value: Any?) -> [Any] {
    if let array = value as? [Any] { return array }
    if let nsArray = value as? NSArray { return nsArray.map { $0 } }
    return []
}

public func wcData(_ value: Any?) -> Data? {
    value as? Data
}

public func wcRegistryEntryID(_ service: io_service_t) -> UInt64 {
    var entryID: UInt64 = 0
    IORegistryEntryGetRegistryEntryID(service, &entryID)
    return entryID
}

public func wcPortIndex(from dict: [String: Any], service: io_service_t? = nil) -> Int {
    if let n = dict["PortIndex"].map(wcInt), n != 0 { return n }
    if let n = dict["ParentPortNumber"].map(wcInt), n != 0 { return n }
    if let n = dict["ParentBuiltInPortNumber"].map(wcInt), n != 0 { return n }
    if let n = dict["PortNumber"].map(wcInt), n != 0 { return n }
    guard let service else { return 0 }
    var locBuf = [CChar](repeating: 0, count: 128)
    if IORegistryEntryGetLocationInPlane(service, kIOServicePlane, &locBuf) == KERN_SUCCESS,
       let n = Int(String(cString: locBuf), radix: 16) {
        return n
    }
    return 0
}

public func wcPortIndex(read: (String) -> Any?, service: io_service_t? = nil) -> Int {
    for key in ["PortIndex", "ParentPortNumber", "ParentBuiltInPortNumber", "PortNumber"] {
        let n = wcInt(read(key)); if n != 0 { return n }
    }
    guard let service else { return 0 }
    var locBuf = [CChar](repeating: 0, count: 128)
    if IORegistryEntryGetLocationInPlane(service, kIOServicePlane, &locBuf) == KERN_SUCCESS,
       let n = Int(String(cString: locBuf), radix: 16) {
        return n
    }
    return 0
}

public func wcPortType(from dict: [String: Any], service: io_service_t? = nil) -> String {
    if let type = dict["PortTypeDescription"] as? String { return type }
    guard let service else { return "USB-C" }

    var current = service
    IOObjectRetain(current)
    defer { IOObjectRelease(current) }
    for _ in 0..<5 {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
            break
        }
        IOObjectRelease(current)
        current = parent

        // Read the single key individually rather than bulk-fetching all
        // properties. The bulk fetch can abort inside IOCFUnserializeBinary
        // when the kernel returns a malformed blob mid-teardown. See #181.
        if let type = IORegistryEntryCreateCFProperty(current, "PortTypeDescription" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
            return type
        }
    }
    return "USB-C"
}

public func wcPortType(read: (String) -> Any?, service: io_service_t? = nil) -> String {
    if let type = read("PortTypeDescription") as? String { return type }
    guard let service else { return "USB-C" }

    var current = service
    IOObjectRetain(current)
    defer { IOObjectRelease(current) }
    for _ in 0..<5 {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
            break
        }
        IOObjectRelease(current)
        current = parent

        if let type = IORegistryEntryCreateCFProperty(current, "PortTypeDescription" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
            return type
        }
    }
    return "USB-C"
}

/// Is this IOKit class name an HPM power-controller node (the node that carries
/// the port's `UUID`)?
///
/// **This predicate is deliberately class-agnostic and must stay that way.**
/// `AppleHPMDevice` is the base class used on **M1/M2**; `AppleHPMDeviceHAL*`
/// (e.g. `AppleHPMDeviceHALType3`) is the M3+ subclass. **Both carry a `UUID`.**
/// The 206-machine probe-35 corpus is unambiguous: 295/295 `AppleHPMDevice`
/// ports and 409/409 `AppleHPMDeviceHALType3` ports have one, zero misses
/// (704 ports total; probe 35 also lists 50 `(no port child)` internal
/// controllers, which carry a UUID but own no port and are not counted).
///
/// Narrowing this to the `HALType3` subclass would silently drop every M1/M2
/// machine from the port join while looking like "M1/M2 hardware has no UUID".
/// That misreading has already cost two separate investigations, so it is pinned
/// by `HPMControllerClassGateTests`: narrow it and the tests go red.
public func wcIsHPMControllerClass(_ className: String) -> Bool {
    className == "AppleHPMDevice" || className.hasPrefix("AppleHPMDeviceHAL")
}

/// Walks the IOKit parent chain from `service` looking for an HPM power
/// controller node (`AppleHPMDevice` or `AppleHPMDeviceHAL*`) and
/// returns its `UUID` property as a raw string.
///
/// This is the same walk `AppleHPMInterfaceWatcher.hpmControllerUUID(for:)`
/// performs, factored out so every per-port source watcher (PowerSource,
/// USB3Transport, TRMTransport, CIOCableCapability) can capture the same UUID
/// without duplicating the logic. Both share `wcIsHPMControllerClass` so the two
/// walks can never drift apart on which classes count.
///
/// Returns `nil` when no HPM controller is found within 12 parent steps, or
/// when the controller carries no `UUID` property. The depth limit of 12
/// is larger than the watcher's 8 to accommodate deeper subtrees
/// (IOPortFeaturePowerSource sits ~4 levels below the HPM device node,
/// whereas `AppleHPMInterface` is a direct child).
public func wcHPMControllerUUID(for service: io_service_t) -> String? {
    var current = service
    IOObjectRetain(current)
    defer { IOObjectRelease(current) }

    for _ in 0..<12 {
        var classBuf = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(current, &classBuf)
        let cls = String(cString: classBuf)
        if wcIsHPMControllerClass(cls) {
            if let uuid = IORegistryEntryCreateCFProperty(
                current,
                "UUID" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? String, !uuid.isEmpty {
                return uuid
            }
            // Found the controller but no UUID. Stop walking.
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
