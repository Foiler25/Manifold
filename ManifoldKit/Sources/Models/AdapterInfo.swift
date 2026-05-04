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
// ─────────────────────────────────────────────────────────────────────
// AdapterInfo.swift
//
// One end of the wall-power story: which charger is currently feeding
// the host, and how much it's delivering. macOS picks ONE active
// adapter when multiple are plugged in (e.g. MagSafe + USB-C PD); this
// type captures whatever `AppleSmartBattery`'s `AdapterDetails` exposes
// about that active source.

public struct AdapterInfo: Sendable, Hashable, Codable {

    /// The connection / form-factor classification we surface in the UI.
    /// Derived in the discovery layer from `AdapterDetails`'s
    /// `Description` / `Family` / `IsWireless` fields. `.unknown` when
    /// the kernel publishes details we can't classify.
    public enum Source: String, Sendable, Hashable, Codable, CaseIterable {
        case magsafe
        case usbC
        case wireless
        case unknown

        /// User-facing short label ("MagSafe", "USB-C", "Wireless",
        /// "—"). Localised to the running app's primary language by
        /// the views that render it; the raw value is the catalog key.
        public var labelKey: String {
            "host.adapter.source.\(rawValue)"
        }
    }

    /// Wattage the active charger is reporting. Already in watts —
    /// `Watts` is the same value type the rest of ManifoldKit uses.
    public let watts: Watts

    /// How the charger is connected. Derived; never absent — falls
    /// back to `.unknown` for unrecognised charger descriptors.
    public let source: Source

    /// Free-form description string the kernel publishes (e.g.
    /// "USB-C 65W", "MagSafe", "Generic"). Useful for tooltips /
    /// VoiceOver but generally too verbose for the inline label.
    /// nil when the field isn't set.
    public let description: String?

    /// Charger manufacturer string (e.g. "Apple"). Often nil on
    /// third-party USB-C PD bricks that don't populate the field.
    public let manufacturer: String?

    /// Hardware model / part number (e.g. "MNWA3LL/A").
    public let model: String?

    /// Negotiated bus voltage in volts. nil when unavailable.
    public let voltage: Double?

    /// Negotiated current in amps. Multiplied by `voltage` ≈ `watts`,
    /// minus protocol overhead.
    public let amperage: Double?

    /// Apple `FamilyCode` raw value preserved in case the source
    /// classification (`Source` enum) collapses an interesting
    /// distinction. Useful for debugging unknown chargers.
    public let familyCode: Int?

    public init(
        watts: Watts,
        source: Source,
        description: String? = nil,
        manufacturer: String? = nil,
        model: String? = nil,
        voltage: Double? = nil,
        amperage: Double? = nil,
        familyCode: Int? = nil
    ) {
        self.watts = watts
        self.source = source
        self.description = description
        self.manufacturer = manufacturer
        self.model = model
        self.voltage = voltage
        self.amperage = amperage
        self.familyCode = familyCode
    }
}
