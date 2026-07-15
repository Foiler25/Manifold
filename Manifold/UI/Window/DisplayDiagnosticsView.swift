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
// DisplayDiagnosticsView.swift

import SwiftUI

struct DisplayDiagnosticsView: View {
    @Bindable var engine: CableEngine

    var body: some View {
        Group {
            if let snapshot = engine.snapshot {
                let model = DisplayDiagnosticsModel(snapshot: snapshot)
                if !model.hostSupported {
                    topAligned {
                        ContentUnavailableView(
                            "Display diagnostics aren't available on this Mac",
                            systemImage: "display.trianglebadge.exclamationmark",
                            description: Text("No USB-C DisplayPort transport data is exposed by this host.")
                        )
                    }
                } else if model.entries.isEmpty {
                    topAligned {
                        ContentUnavailableView(
                            "No external display detected",
                            systemImage: "display",
                            description: Text("Connect a display through USB-C, DisplayPort, HDMI, USB4, or Thunderbolt to inspect its live link.")
                        )
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(model.entries) { entry in displayCard(entry) }
                        }
                        .padding(20)
                    }
                }
            } else {
                ProgressView("Reading display links…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityIdentifier("window.tab.display.root")
        .toolbar { DetachToolbarButton(screen: .display) }
    }

    /// Top-anchors an empty/placeholder state inside a `ScrollView` so
    /// it sits just below the tab picker like the Cables and Diagnostics
    /// tabs, instead of floating in the vertical center of the pane.
    private func topAligned<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView { content().frame(maxWidth: .infinity) }
    }

    private func displayCard(_ entry: DisplayDiagnosticsModel.Entry) -> some View {
        let facts = entry.diagnostic.facts
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(facts.monitorName ?? entry.transport.monitor?.productName ?? String(localized: "External display"))
                        .font(.headline)
                    Text(facts.currentMode?.label ?? String(localized: "Connected, mode unreadable"))
                        .font(.title3.weight(.semibold))
                }
                Spacer()
                if let max = facts.maxMode {
                    metric(String(localized: "Best mode"), max.shortLabel)
                }
            }

            HStack(spacing: 20) {
                metric(String(localized: "Link"), facts.rateDescription ?? String(localized: "Unknown rate"))
                metric(String(localized: "Lanes"), "\(facts.lanes) of \(facts.maxLanes)")
                metric(
                    String(localized: "Path"),
                    entry.transport.link.tunneled
                        ? String(localized: "Thunderbolt / USB4")
                        : String(localized: "DisplayPort Alt Mode")
                )
            }

            if let needed = facts.neededGbps, let delivered = facts.deliveredGbps {
                HStack(spacing: 20) {
                    metric(String(localized: "Mode needs"), "\(format(needed)) Gbps")
                    metric(String(localized: "Link delivers"), "\(format(delivered)) Gbps")
                }
            }

            if entry.diagnostic.bottleneck == .compressionActive {
                callout(String(localized: "DSC compression is active"), detail: String(localized: "The live mode exceeds the uncompressed link budget and is reaching the display through Display Stream Compression."), warning: false)
            } else if entry.diagnostic.bottleneck == .compressionPlausible {
                callout(String(localized: "DSC compression is likely"), detail: String(localized: "The link is at its lane and rate ceiling; the display may be using compression for its top mode."), warning: false)
            }

            if let sink = facts.sinkType {
                let branch = facts.branchDevice.map { " — \($0)" } ?? ""
                callout(String(localized: "\(sink) adapter\(branch)"), detail: String(localized: "An active adapter participates in this link, so a bandwidth limit cannot automatically be blamed on the cable."), warning: entry.diagnostic.bottleneck == .adapterLimit)
            }

            Text(entry.diagnostic.summary)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(entry.diagnostic.isWarning ? Color.manifoldWarning : Color.manifoldAccent)
            Text(entry.diagnostic.detail)
                .font(.callout)
                .foregroundStyle(.secondary)

            if entry.diagnostic.cableAssessment == .unlikelyTheCable {
                Label("Current evidence makes the cable an unlikely cause.", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(Color.manifoldAccent)
            }
            if let billboardNote = entry.diagnostic.billboardNote {
                callout(String(localized: "Alt Mode setup hint"), detail: billboardNote, warning: true)
            }
        }
        .padding(CablesViewConstants.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: CablesViewConstants.cardCornerRadius).fill(Color.manifoldCard))
        .accessibilityIdentifier("display.diagnostic.card")
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold))
        }
    }

    private func callout(_ title: String, detail: String, warning: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(warning ? Color.manifoldWarning : Color.manifoldAccent)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill((warning ? Color.manifoldWarning : Color.manifoldAccent).opacity(0.10)))
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
}
