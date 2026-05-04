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
                // "<draw> / <charger>" reads at a glance — accent
                // green for the live draw, dimmer secondary for the
                // charger wattage so the eye lands on the active
                // number first. Falls back to just the draw when on
                // battery or on a desktop Mac without
                // `AppleSmartBattery`.
                HStack(spacing: 4) {
                    Text(host.totalPowerDraw.formatted)
                        .foregroundStyle(Color.manifoldAccent)
                    if let input = host.inputPower {
                        Text(verbatim: "/")
                            .foregroundStyle(.secondary)
                        Text(input.formatted)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline.monospacedDigit())
                if diagnosticCount > 0 {
                    Text(diagnosticString(for: diagnosticCount))
                        .font(.caption)
                        .foregroundStyle(Color.manifoldWarning)
                } else {
                    Text("popover.host.diagnostics.none")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
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
