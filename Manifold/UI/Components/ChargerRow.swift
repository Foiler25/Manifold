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
// ChargerRow.swift
//
// "Charging — <source> · Port N — 65 W" row for the main-window
// topology view. A USB-C charger occupies a chassis port that never
// enumerates a USB device, so it never appears in `Host.ports` —
// without this row the topology list would silently omit a meaningful
// connection. The row mirrors the bolt visual treatment from
// `PortChip` so the icon, the chip, and the row read as one physical
// thing.
//
// Metrics intentionally match `TopologyCanvas.topologyRow(port:)`
// (icon column width 20, HStack spacing 10, body / caption fonts) so
// the bolt aligns with the cable-connector glyph in the device rows
// underneath.
//
// The view is intentionally non-interactive — the charger has no
// telemetry to drill into, and the host header already exposes the
// adapter's full description / model in its tooltip.

import SwiftUI
import ManifoldKit

struct ChargerRow: View {

    let adapter: AdapterInfo

    /// Optional chassis-port position to suffix into the subtitle —
    /// "USB-C · Port 1". Present when the host has exactly one
    /// `.powerOnly` USB-C port we can confidently associate with the
    /// active adapter; nil when the mapping is ambiguous (no
    /// matching chip, MagSafe / wireless source, multiple candidates).
    let portPosition: Int?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(Color.manifoldAccent)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text("popover.charger.title")
                    .font(.body)
                    .foregroundStyle(Color.manifoldText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            Text(adapter.watts.formatted)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Composed subtitle: source label, then the chassis port number
    /// when known. Both pieces come from the localisation catalog so
    /// translators get a single source of truth.
    ///
    /// When the source classifier returns `.unknown`, fall back to
    /// whatever string fields the kernel populated (`description`
    /// → `model` → `manufacturer`) before showing the literal
    /// "Unknown" label — those fields often carry a useful hint
    /// even when our classifier couldn't make a confident call.
    private var subtitle: String {
        let source = sourceLabel
        if let position = portPosition {
            return String(
                format: NSLocalizedString(
                    "popover.charger.subtitle.withPort",
                    comment: "Charger row subtitle, %1$@ source label, %2$lld port position."
                ),
                source, position
            )
        }
        return source
    }

    private var sourceLabel: String {
        if adapter.source != .unknown {
            return NSLocalizedString(adapter.source.labelKey, comment: "")
        }
        // Classifier didn't recognise the firmware shape. Use the
        // best free-form field the kernel provided so the row reads
        // as a real charger instead of a generic "Unknown".
        for candidate in [adapter.description, adapter.model, adapter.manufacturer] {
            if let text = candidate?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                return text
            }
        }
        return NSLocalizedString(adapter.source.labelKey, comment: "")
    }

    private var accessibilityLabel: String {
        let source = NSLocalizedString(adapter.source.labelKey, comment: "")
        if let position = portPosition {
            return String(
                format: NSLocalizedString(
                    "popover.charger.accessibility.withPort",
                    comment: "VoiceOver label for the charger row when a port is known. %1$@ source, %2$lld port, %3$@ wattage."
                ),
                source, position, adapter.watts.formatted
            )
        }
        return String(
            format: NSLocalizedString(
                "popover.charger.accessibility.noPort",
                comment: "VoiceOver label for the charger row when no port is known. %1$@ source, %2$@ wattage."
            ),
            source, adapter.watts.formatted
        )
    }
}

// MARK: - Helpers

extension ChargerRow {

    /// Best-effort chassis-port position for the active adapter:
    /// - For source `.usbC`: the unique `.powerOnly` USB-C port, if
    ///   exactly one exists. Multiple candidates → ambiguous → nil.
    /// - For other sources (MagSafe / wireless / unknown): nil — the
    ///   pill row doesn't include those, so there's no chip to bind to.
    static func portPosition(for adapter: AdapterInfo, in physicalPorts: [PhysicalPort]) -> Int? {
        guard adapter.source == .usbC else { return nil }
        let candidates = physicalPorts.filter {
            $0.kind == .usbC && $0.state == .powerOnly
        }
        return candidates.count == 1 ? candidates.first?.position : nil
    }
}

// MARK: - Previews

#Preview("ChargerRow — USB-C with port") {
    ChargerRow(
        adapter: AdapterInfo(watts: Watts(65), source: .usbC),
        portPosition: 1
    )
    .padding()
    .background(Color.manifoldSurface)
}

#Preview("ChargerRow — MagSafe, no port") {
    ChargerRow(
        adapter: AdapterInfo(watts: Watts(96), source: .magsafe),
        portPosition: nil
    )
    .padding()
    .background(Color.manifoldSurface)
}
