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
public import IOKit

/// Read-only IOKit walker that dumps the IOThunderboltSwitch tree as plain
/// text. Used by `whatcable --tb-debug` to gather field shapes from real
/// Thunderbolt hardware so we can design the rendering layer with evidence
/// rather than guesses. No interpretation, no rendering, just a paste-ready
/// dump of every property on every switch and port.
public enum ThunderboltProbe {
    public static func dump() -> String {
        var output = ""
        output += "# WhatCable Thunderbolt probe\n"
        output += "# whatcable \(AppInfo.version) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        output += "# Generated \(ISO8601DateFormatter().string(from: Date()))\n"
        output += "\n"

        // IOThunderboltSwitch is the abstract parent class. Matching against it
        // catches all subclass variants (IOThunderboltSwitchType7, USB4, etc.).
        let matching = IOServiceMatching("IOThunderboltSwitch")
        var iter: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter)
        guard kr == KERN_SUCCESS else {
            output += "ERROR: IOServiceGetMatchingServices returned \(kr)\n"
            return output
        }
        defer { IOObjectRelease(iter) }

        var switchCount = 0
        while case let service = IOIteratorNext(iter), service != 0 {
            defer { IOObjectRelease(service) }
            switchCount += 1
            output += dumpSwitch(service, index: switchCount)
            output += "\n"
        }

        if switchCount == 0 {
            output += "No IOThunderboltSwitch services found.\n"
            output += "(This is unexpected on Apple Silicon — please flag in the issue.)\n"
        } else {
            output += "# \(switchCount) switch(es) total\n"
        }
        return output
    }

    private static func dumpSwitch(_ service: io_service_t, index: Int) -> String {
        var output = ""
        let className = ioClassName(service) ?? "<unknown class>"
        output += "## Switch #\(index): \(className)\n"

        if let props = ioProperties(service) {
            output += renderProperties(props, indent: "  ")
        }

        // Walk port children.
        var childIter: io_iterator_t = 0
        let kr = IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIter)
        guard kr == KERN_SUCCESS else {
            output += "  ERROR: child iterator failed (\(kr))\n"
            return output
        }
        defer { IOObjectRelease(childIter) }

        var portIndex = 0
        while case let child = IOIteratorNext(childIter), child != 0 {
            defer { IOObjectRelease(child) }
            let childClass = ioClassName(child) ?? "<unknown>"
            // Filter to IOThunderboltPort and its subclasses. Skip the adapter
            // children (AppleThunderboltUSBDownAdapter etc.) — they're driver
            // matches, not link-state carriers.
            guard childClass.contains("Port") else { continue }
            portIndex += 1
            output += "\n  ### Port @\(portIndex): \(childClass)\n"
            if let props = ioProperties(child) {
                output += renderProperties(props, indent: "    ")
            }
        }
        return output
    }

    private static func ioClassName(_ service: io_service_t) -> String? {
        var buf = [CChar](repeating: 0, count: 128)
        let kr = IOObjectGetClass(service, &buf)
        guard kr == KERN_SUCCESS else { return nil }
        return String(cString: buf)
    }

    private static func ioProperties(_ service: io_service_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let dict = unmanaged?.takeRetainedValue() else { return nil }
        return dict as? [String: Any]
    }

    private static func renderProperties(_ props: [String: Any], indent: String) -> String {
        // Sort keys for stable, paste-friendly output. Skip noisy fields that
        // don't help with the design (IOPowerManagement dict, large binary blobs
        // that aren't useful without decoding).
        let skip: Set<String> = ["IOPowerManagement"]
        var output = ""
        for key in props.keys.sorted() where !skip.contains(key) {
            let value = props[key]!
            output += "\(indent)\(key) = \(renderValue(value))\n"
        }
        return output
    }

    private static func renderValue(_ value: Any) -> String {
        switch value {
        case let s as String:
            return "\"\(s)\""
        case let n as NSNumber:
            return n.stringValue
        case let b as Bool:
            return b ? "true" : "false"
        case let data as Data:
            // Hex dump short blobs; truncate long ones.
            let hex = data.prefix(64).map { String(format: "%02x", $0) }.joined()
            let suffix = data.count > 64 ? "...(\(data.count) bytes total)" : ""
            return "<\(hex)\(suffix)>"
        case let arr as [Any]:
            let parts = arr.map { renderValue($0) }
            return "[\(parts.joined(separator: ", "))]"
        case let dict as [String: Any]:
            let parts = dict.keys.sorted().map { "\($0)=\(renderValue(dict[$0]!))" }
            return "{\(parts.joined(separator: ", "))}"
        default:
            return "\(value)"
        }
    }
}
