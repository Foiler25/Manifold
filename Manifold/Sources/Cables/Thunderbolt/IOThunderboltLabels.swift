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

/// Pure helpers that turn `IOThunderboltSwitch` / `IOThunderboltPort` model
/// values into user-facing labels. Convention: per-lane Gb/s × lane count,
/// matching Apple's `system_profiler SPThunderboltDataType` output so the
/// labels line up with what users see in About This Mac → System Information.
///
/// TB5 was confirmed against a real M5 Pro + UGreen JHL9580 dock sample on
/// issue #52, so the renderer now emits a confirmed TB5 label for raw speed
/// code `0x2`. See planning/thunderbolt-fabric.md for the reasoning.
public enum ThunderboltLabels {
    /// Compact human label for an active TB link.
    /// Returns nil if the port has no active link.
    /// Examples:
    /// - `"Up to 20 Gb/s × 2"` (USB4 / TB4 dual-lane)
    /// - `"Up to 10 Gb/s × 1"` (TB3 single-lane)
    /// - `"Up to 40 Gb/s × 2"` (TB5 / USB4 v2 dual-lane)
    /// - `"Up to 40 Gb/s (3 TX / 1 RX)"` (TB5 asymmetric)
    public static func linkLabel(for port: IOThunderboltPort) -> String? {
        guard port.hasActiveLink,
              let gen = port.currentSpeed,
              let width = port.currentWidth else {
            return nil
        }

        switch gen {
        case .tb3, .usb4Tb4, .tb5:
            guard let perLane = gen.perLaneGbps else { return nil }
            let lanes = describeLanes(width)
            return String(localized: "Up to \(perLane) Gb/s \(lanes)", bundle: _coreLocalizedBundle)
        case .unknown(let raw):
            let hex = String(raw, radix: 16)
            return String(localized: "Unknown generation (raw speed code 0x\(hex))", bundle: _coreLocalizedBundle)
        }
    }

    /// Lane-count suffix. Symmetric links read `× N`; asymmetric links
    /// (TB5 3+1 configurations) read `(N TX / M RX)`.
    private static func describeLanes(_ width: LinkWidth) -> String {
        if width.asymmetricTx || width.asymmetricRx {
            return "(\(width.txLanes) TX / \(width.rxLanes) RX)"
        }
        // Symmetric: just lane count.
        let lanes = max(width.txLanes, 1)
        return "× \(lanes)"
    }

    /// Human-readable name for a downstream switch ("ASUS PA32QCV",
    /// "CalDigit, Inc. TS3 Plus"). Falls back to "Unknown device" if the
    /// DROM didn't decode (rare but possible).
    public static func deviceName(for sw: IOThunderboltSwitch) -> String {
        let vendor = sw.vendorName.trimmingCharacters(in: .whitespaces)
        let model = sw.modelName.trimmingCharacters(in: .whitespaces)
        switch (vendor.isEmpty, model.isEmpty) {
        case (false, false):
            // Some DROMs repeat the brand in the model string, e.g.
            // vendor "Ugreen" + model "Ugreen Storage Device". Concatenating
            // then reads "Ugreen Ugreen Storage Device" (issue #392). If the
            // model already starts with the vendor name, it is the full
            // name on its own. Match the whole word (equal, or vendor + space)
            // so a vendor that happens to prefix an unrelated model word
            // ("Cal" vs "Calibre X") is not collapsed.
            let vLower = vendor.lowercased()
            let mLower = model.lowercased()
            if mLower == vLower || mLower.hasPrefix(vLower + " ") {
                return model
            }
            return "\(vendor) \(model)"
        case (false, true): return vendor
        case (true, false): return model
        case (true, true): return String(localized: "Unknown device", bundle: _coreLocalizedBundle)
        }
    }
}

/// Topology helpers: walk the switch graph to find the chain rooted at a
/// host port. Pure logic; no IOKit. Used by `PortSummary` and the GUI.
public enum ThunderboltTopology {
    /// Find the host root switch whose lane port has `Socket ID == "N"`,
    /// where N is parsed from a USB-C port's serviceName suffix
    /// (e.g. `Port-USB-C@1` → `1`).
    public static func hostRoot(
        forSocketID socketID: String,
        in switches: [IOThunderboltSwitch]
    ) -> IOThunderboltSwitch? {
        switches.first { sw in
            sw.isHostRoot && sw.ports.contains {
                $0.adapterType.isLane && $0.socketID == socketID
            }
        }
    }

    /// Parse the trailing `@N` suffix from a port serviceName, or nil if
    /// it doesn't have one. `Port-USB-C@1` → `"1"`. Pure parser, kept
    /// public for parser-level unit tests; **production callers must use
    /// `socketID(for:)` instead** so the data-capability gate runs.
    public static func socketID(fromServiceName name: String) -> String? {
        guard let at = name.lastIndex(of: "@") else { return nil }
        let suffix = name[name.index(after: at)...]
        return suffix.isEmpty ? nil : String(suffix)
    }

    /// The TB host-root socket ID for this port, or `nil` when this port
    /// can't host a data link. Power-only ports (MagSafe) share an `@N`
    /// suffix with the first USB-C port on the same HPM controller
    /// (issue #195), so attempting a topology lookup on them leaks the
    /// neighbouring USB-C port's lane state. Gating on `carriesData`
    /// keeps every TB-graph consumer honest at the entry point.
    public static func socketID(for port: AppleHPMInterface) -> String? {
        guard port.carriesData else { return nil }
        return socketID(fromServiceName: port.serviceName)
    }

    /// Return the chain of downstream switches reachable from a host root,
    /// in depth order (root → device). Walks the `parentSwitchUID` graph.
    /// Returns just the root if there's nothing downstream.
    public static func chain(
        from root: IOThunderboltSwitch,
        in switches: [IOThunderboltSwitch]
    ) -> [IOThunderboltSwitch] {
        var byParent: [Int64: [IOThunderboltSwitch]] = [:]
        for sw in switches {
            guard let parentUID = sw.parentSwitchUID else { continue }
            byParent[parentUID, default: []].append(sw)
        }

        var chain: [IOThunderboltSwitch] = [root]
        var current = root
        var seen: Set<Int64> = [root.id]
        // Follow first-child only. Daisy-chains are linear in the common
        // case; if the user has a true tree (dock with two TB devices),
        // the chain follows the first downstream branch and the GUI tree
        // can render the full topology separately.
        while let children = byParent[current.id], let next = children.first {
            guard !seen.contains(next.id) else { break }
            seen.insert(next.id)
            chain.append(next)
            current = next
        }
        return chain
    }

    /// Return the full downstream tree rooted at a host root, following
    /// *every* branch. A dock with two Thunderbolt devices yields two child
    /// subtrees. Depth 0 is the root's direct children (the first downstream
    /// devices), matching how `chain`'s `dropFirst()` is consumed. Returns an
    /// empty array when nothing is downstream.
    ///
    /// This is the branch-aware counterpart to `chain(from:in:)`, which only
    /// follows the first child. Use this for rendering the whole fabric;
    /// `chain` is still the right tool for "deepest single path" questions
    /// like step-down detection.
    public static func tree(
        from root: IOThunderboltSwitch,
        in switches: [IOThunderboltSwitch]
    ) -> [IOThunderboltSwitchNode] {
        var byParent: [Int64: [IOThunderboltSwitch]] = [:]
        for sw in switches {
            guard let parentUID = sw.parentSwitchUID else { continue }
            byParent[parentUID, default: []].append(sw)
        }

        func build(_ sw: IOThunderboltSwitch, depth: Int) -> IOThunderboltSwitchNode {
            let kids = (byParent[sw.id] ?? [])
                .sorted { $0.id < $1.id }
                .map { build($0, depth: depth + 1) }
            return IOThunderboltSwitchNode(sw: sw, depth: depth, children: kids)
        }

        return (byParent[root.id] ?? [])
            .sorted { $0.id < $1.id }
            .map { build($0, depth: 0) }
    }

    /// Flatten a tree into depth-first order (parent, then its subtree),
    /// preserving each node's `depth`. Mirrors `USBDeviceNode.flatten` so the
    /// CLI and GUI render the Thunderbolt fabric the same way they render the
    /// USB device tree.
    public static func flatten(_ nodes: [IOThunderboltSwitchNode]) -> [IOThunderboltSwitchNode] {
        var result: [IOThunderboltSwitchNode] = []
        for node in nodes {
            result.append(node)
            result.append(contentsOf: flatten(node.children))
        }
        return result
    }

    /// The lane port whose link label best represents *how this switch is
    /// connected* (its arriving / active link). For a leaf device this is its
    /// only active lane; for an inline switch every active lane carries the
    /// same per-lane speed, so the first one is representative. Returns nil if
    /// no lane is active.
    public static func connectionLanePort(_ sw: IOThunderboltSwitch) -> IOThunderboltPort? {
        sw.ports.first { $0.adapterType.isLane && $0.hasActiveLink }
    }

    /// Find the active downstream lane port on a switch (the one going
    /// toward the next-hop device, not the upstream link to the host).
    /// Useful for picking which port's link state describes the next leg.
    public static func activeDownstreamLanePort(_ sw: IOThunderboltSwitch) -> IOThunderboltPort? {
        // Host root: any active lane port is downstream by definition.
        // Downstream switch: skip the lane port matching upstreamPortNumber,
        // pick the first active one of the rest.
        let candidates = sw.ports.filter { $0.adapterType.isLane && $0.hasActiveLink }
        if sw.isHostRoot {
            return candidates.first
        }
        return candidates.first { $0.portNumber != sw.upstreamPortNumber }
    }
}

// MARK: - Fabric tree

/// A node in the Thunderbolt fabric tree: one switch plus its depth from the
/// host root and its downstream children. Mirrors `USBDeviceNode` so the CLI
/// and GUI can render the fabric the same way they render the USB device tree.
/// Built from the flat switch list by `ThunderboltTopology.tree(from:in:)`,
/// which walks `parentSwitchUID`.
public struct IOThunderboltSwitchNode: Identifiable {
    public let sw: IOThunderboltSwitch
    public let depth: Int
    public let children: [IOThunderboltSwitchNode]

    public var id: Int64 { sw.id }

    public init(sw: IOThunderboltSwitch, depth: Int, children: [IOThunderboltSwitchNode]) {
        self.sw = sw
        self.depth = depth
        self.children = children
    }
}
