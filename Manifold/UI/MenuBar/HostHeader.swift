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
// HostHeader.swift
//
// Top-of-popover summary row per SPEC.md §13.1: model name, total
// draw, diagnostic count. Phase 4 ships the layout; Phase 8 starts
// emitting diagnostics that populate the count badge non-trivially.

import SwiftUI
import ManifoldKit

struct HostHeader: View {

    let host: ManifoldKit.Host
    let diagnosticCount: Int

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .font(.headline)
                    .foregroundStyle(Color.manifoldText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Show the bonjour hostname when we have a separate
                // friendly name; otherwise fall back to the model so
                // the subtitle row is never empty.
                Text(host.friendlyName != nil ? host.name : host.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                // "<draw> / <charger>". Draw renders in the default
                // text colour (no special tint when within budget) —
                // it flips to critical red when it exceeds the input
                // wattage, signalling overdraw. Input wattage is the
                // green "headroom" accent. Falls back to just the
                // draw when on battery or on a desktop Mac without
                // `AppleSmartBattery`.
                HStack(spacing: 4) {
                    Text(host.totalPowerDraw.formatted)
                        .foregroundStyle(drawColor(for: host))
                    if let input = host.inputAdapter {
                        Text(verbatim: "/")
                            .foregroundStyle(.secondary)
                        Text(input.watts.formatted)
                            .foregroundStyle(Color.manifoldAccent)
                    }
                }
                .font(.subheadline.monospacedDigit())
                // Second line: charger source when known
                // ("via MagSafe" / "via USB-C"). Falls through to a
                // third line for the diagnostic count so both can
                // coexist when both apply.
                if let source = adapterSourceCaption {
                    Text(source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if diagnosticCount > 0 {
                    Text(diagnosticString(for: diagnosticCount))
                        .font(.caption)
                        .foregroundStyle(Color.manifoldWarning)
                } else if adapterSourceCaption == nil {
                    Text("popover.host.diagnostics.none")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("menubar.popover.host")
    }

    /// Default text colour for the draw figure, flipped to critical
    /// red when total USB draw exceeds the connected charger's input
    /// wattage. Battery / desktop / no-adapter cases keep the default
    /// colour because there's no comparison baseline.
    private func drawColor(for host: ManifoldKit.Host) -> Color {
        guard let input = host.inputAdapter?.watts.value,
              host.totalPowerDraw.value > input else {
            return Color.manifoldText
        }
        return Color.manifoldCritical
    }

    /// "via MagSafe" / "via USB-C" / "via Wireless". nil when the
    /// adapter source is `.unknown` or when no adapter is connected —
    /// caller falls back to the diagnostic count line in that case.
    private var adapterSourceCaption: String? {
        guard let source = host.inputAdapter?.source else { return nil }
        let labelKey: String
        switch source {
        case .magsafe:  labelKey = "popover.host.adapter.source.magsafe"
        case .usbC:     labelKey = "popover.host.adapter.source.usbC"
        case .wireless: labelKey = "popover.host.adapter.source.wireless"
        case .unknown:  return nil
        }
        return NSLocalizedString(labelKey, comment: "")
    }

    /// Localised "1 diagnostic" / "N diagnostics" via the string
    /// catalog's plural variation.
    private func diagnosticString(for count: Int) -> String {
        String(
            format: NSLocalizedString(
                "popover.host.diagnostics.count",
                comment: "Plural-aware diagnostic count for the host header."
            ),
            count
        )
    }

    /// VoiceOver reads the whole header as one element: model + total
    /// draw + diagnostic state. Using `.combine` so VO doesn't visit
    /// each `Text` separately.
    private var accessibilityLabel: String {
        let diag = diagnosticCount > 0
            ? diagnosticString(for: diagnosticCount)
            : NSLocalizedString("popover.host.diagnostics.none", comment: "")
        return String(
            format: NSLocalizedString(
                "popover.host.accessibility",
                comment: "VoiceOver label for the host header."
            ),
            host.displayName,
            host.totalPowerDraw.formatted,
            diag
        )
    }
}

#Preview("HostHeader — populated") {
    HostHeader(host: PreviewData.macBook, diagnosticCount: 2)
        .padding()
        .background(Color.manifoldSurface)
}

#Preview("HostHeader — empty + no diagnostics") {
    HostHeader(host: PreviewData.emptyMacBook, diagnosticCount: 0)
        .padding()
        .background(Color.manifoldSurface)
}
