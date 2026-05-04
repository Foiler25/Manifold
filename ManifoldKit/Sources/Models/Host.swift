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
// ─────────────────────────────────────────────────────────────────────
// Host.swift
//
// One Mac. The root of the port tree. Per SPEC.md §4.3.
//
// `Hashable` for SwiftUI `ForEach` stability across re-renders;
// `Codable` for the Snapshot wire format and CSV/JSON exports;
// `Sendable` because everything in ManifoldKit is value-type and
// trivially safe to cross actor boundaries.

// No Foundation types in the public API surface — only ManifoldKit
// types and stdlib `String`/`Array`. UUID is mentioned in the doc
// comment but never instantiated here.

public struct Host: Identifiable, Hashable, Sendable, Codable {

    /// Stable host identifier — derived from the machine's hardware
    /// UUID by the discovery layer. Persists across reboots.
    public let id: HostID

    /// Bonjour / network host name ("temporary-max-pro.local"). Sourced
    /// from `ProcessInfo.processInfo.hostName`.
    public let name: String

    /// User-set Computer Name from the macOS Sharing pane
    /// ("Temporary Max Pro"). Sourced from
    /// `SCDynamicStoreCopyComputerName`. nil when the system call
    /// fails or the user hasn't set one — UI falls back to `name`.
    public let friendlyName: String?

    /// Apple model identifier ("Mac15,9", "MacBookPro18,4"). Used by
    /// Phase 8's diagnostic rules (some power budgets are model-keyed)
    /// and by Phase 12 exports.
    public let model: String

    /// Active wall-power source (MagSafe / USB-C PD / wireless) and
    /// its wattage. Sourced from `AppleSmartBattery`'s `AdapterDetails`.
    /// nil on desktop Macs (no battery service) or on laptops running
    /// unplugged. macOS reports only the *active* adapter when multiple
    /// are physically connected — see `AdapterPowerReader` notes.
    public let inputAdapter: AdapterInfo?

    /// Convenience wrapper around `inputAdapter?.watts` — every existing
    /// view that just needed the wattage keeps working without
    /// reaching into the nested struct.
    public var inputPower: Watts? { inputAdapter?.watts }

    /// Top-level ports on this host. Each port may have downstream
    /// children (hubs, daisy-chained TB devices); see `Port.children`.
    public let ports: [Port]

    /// Every physical port on the host chassis (USB-C@1..N, MagSafe).
    /// Distinct from `ports` — `ports` is only the data-enumerated
    /// subset. A USB-C chassis port that has a power-only sink (a
    /// charging tape measure on a CC-only contract) appears here as
    /// `state == .powerOnly` but has no entry in `ports` because the
    /// device exposes no USB descriptors.
    public let physicalPorts: [PhysicalPort]

    /// Total wattage draw across every device attached to this host,
    /// summed recursively through downstream hubs and daisy chains.
    /// Computed so it stays consistent as the underlying tree changes
    /// (no cache to invalidate).
    public var totalPowerDraw: Watts {
        Watts(ports.reduce(0.0) { $0 + $1.totalDraw.value })
    }

    /// Total advertised port budget across every port on this host —
    /// the supply-side counterpart to `totalPowerDraw`. Sums each
    /// port's `availablePower` (recursively through hubs). Useful as
    /// a "headroom" figure paired with `totalPowerDraw`. Zero when no
    /// port advertises a budget; UI should treat zero as "unknown" /
    /// "—" rather than "0 W".
    public var totalPowerAvailable: Watts {
        Watts(ports.reduce(0.0) { $0 + $1.totalAvailable.value })
    }

    public init(
        id: HostID,
        name: String,
        friendlyName: String? = nil,
        model: String,
        inputAdapter: AdapterInfo? = nil,
        ports: [Port],
        physicalPorts: [PhysicalPort] = []
    ) {
        self.id = id
        self.name = name
        self.friendlyName = friendlyName
        self.model = model
        self.inputAdapter = inputAdapter
        self.ports = ports
        self.physicalPorts = physicalPorts
    }

    /// User-facing primary name: prefer the user-set Computer Name,
    /// fall back to the Bonjour host name. Centralised so every view
    /// renders the same thing.
    public var displayName: String {
        if let friendlyName, !friendlyName.isEmpty { return friendlyName }
        return name
    }

    private enum CodingKeys: String, CodingKey {
        // Stored-property keys only — `inputPower` is a computed
        // wrapper around `inputAdapter` and must NOT appear here, or
        // the synthesised Encodable fails to compile.
        case id, name, friendlyName, model, inputAdapter
        case ports, physicalPorts
        // Legacy key from before `inputAdapter` existed. Only consumed
        // by `init(from:)` for backwards compatibility with snapshots
        // produced by earlier builds; never written.
        case inputPower
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(HostID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.friendlyName = try c.decodeIfPresent(String.self, forKey: .friendlyName)
        self.model = try c.decode(String.self, forKey: .model)
        // Prefer the new `inputAdapter` payload; fall back to the older
        // `inputPower` (Watts only) field if a snapshot from an earlier
        // build is being decoded — surfaces it as an `.unknown` source.
        if let adapter = try c.decodeIfPresent(AdapterInfo.self, forKey: .inputAdapter) {
            self.inputAdapter = adapter
        } else if let watts = try c.decodeIfPresent(Watts.self, forKey: .inputPower) {
            self.inputAdapter = AdapterInfo(watts: watts, source: .unknown)
        } else {
            self.inputAdapter = nil
        }
        self.ports = try c.decode([Port].self, forKey: .ports)
        self.physicalPorts = try c.decodeIfPresent([PhysicalPort].self, forKey: .physicalPorts) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(friendlyName, forKey: .friendlyName)
        try c.encode(model, forKey: .model)
        try c.encodeIfPresent(inputAdapter, forKey: .inputAdapter)
        try c.encode(ports, forKey: .ports)
        try c.encode(physicalPorts, forKey: .physicalPorts)
    }
}
