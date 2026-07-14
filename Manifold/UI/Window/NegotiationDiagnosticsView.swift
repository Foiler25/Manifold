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
// NegotiationDiagnosticsView.swift

import SwiftUI

struct NegotiationDiagnosticsView: View {
    @Bindable var engine: CableEngine
    @Bindable var powerEngine: PowerTelemetryEngine
    let onAppear: () -> Void
    let onDisappear: () -> Void

    var body: some View {
        Group {
            if let snapshot = engine.snapshot {
                let model = NegotiationDiagnosticsModel(snapshot: snapshot)
                if !model.hostSupported {
                    emptyState(
                        title: "Negotiation diagnostics aren't available on this Mac",
                        detail: "Per-port USB-C negotiation data requires an Apple-silicon HPM controller."
                    )
                } else if model.entries.isEmpty {
                    emptyState(
                        title: "Nothing negotiated",
                        detail: "Connect a USB 3, USB4, or Thunderbolt device to compare the port, cable, and device capabilities."
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(model.entries) { entry in
                                negotiationCard(entry)
                            }
                        }
                        .padding(20)
                    }
                }
            } else {
                ProgressView("Reading negotiated links…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.manifoldSurface)
        .accessibilityIdentifier("window.tab.negotiation.root")
        .onAppear(perform: onAppear)
        .onDisappear(perform: onDisappear)
        .toolbar { DetachToolbarButton(screen: .negotiation) }
    }

    private func negotiationCard(_ entry: NegotiationDiagnosticsModel.Entry) -> some View {
        let facts = entry.diagnostic.facts
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.port.portDescription ?? entry.port.serviceName)
                        .font(.headline)
                    Text(entry.diagnostic.summary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(entry.diagnostic.isWarning ? Color.manifoldWarning : Color.manifoldAccent)
                }
                Spacer()
                Label("\(format(facts.activeGbps)) Gbps", systemImage: "arrow.left.arrow.right")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.manifoldAccent.opacity(0.14)))
            }

            capabilityMatrix(entry)

            Text(entry.diagnostic.detail)
                .font(.callout)
                .foregroundStyle(.secondary)

            if facts.cableEmarkerGbps != nil || facts.cableControllerGbps != nil {
                Divider()
                HStack(spacing: 18) {
                    metric("E-marker", value: facts.cableEmarkerGbps.map { "\(format($0)) Gbps" } ?? "Not read")
                    metric("TB controller", value: facts.cableControllerGbps.map { "\(format($0)) Gbps" } ?? "Not reported")
                }
                if entry.diagnostic.cableSignalConflict {
                    Label("The e-marker and Thunderbolt controller disagree; the live controller measurement wins.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.manifoldWarning)
                }
            }

            if entry.weakParty == .security, !entry.trmTransports.isEmpty {
                Label(entry.trmTransports.map(\.summaryLabel).joined(separator: " · "), systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(Color.manifoldWarning)
            }

            if let portKey = entry.port.portKey,
               let contract = powerEngine.contracts[portKey] {
                Divider()
                PDContractInspector(contract: contract)
            } else if let source = engine.snapshot?.powerSources.first(where: {
                $0.portKey == entry.port.portKey && !$0.options.isEmpty
            }) {
                Divider()
                PDPowerSourceInspector(source: source)
            }
        }
        .padding(CablesViewConstants.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: CablesViewConstants.cardCornerRadius).fill(Color.manifoldCard))
        .accessibilityIdentifier("negotiation.port.card")
    }

    private func capabilityMatrix(_ entry: NegotiationDiagnosticsModel.Entry) -> some View {
        let facts = entry.diagnostic.facts
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("")
                partyHeader("Mac port", party: .host, weak: entry.weakParty)
                partyHeader("Cable", party: .cable, weak: entry.weakParty)
                partyHeader("Device", party: .device, weak: entry.weakParty)
            }
            GridRow {
                Text("Data").foregroundStyle(.secondary)
                matrixValue(facts.hostGbps.map { "\(format($0)) Gbps" } ?? "Unknown", party: .host, weak: entry.weakParty)
                matrixValue(facts.cableGbps.map { "\(format($0)) Gbps" } ?? "Unknown", party: .cable, weak: entry.weakParty)
                matrixValue(facts.deviceGbps.map { "\(format($0)) Gbps" } ?? "Unknown", party: .device, weak: entry.weakParty)
            }
            GridRow {
                Text("Power").foregroundStyle(.secondary)
                matrixValue(entry.negotiatedWatts.map { "\($0) W in" } ?? "—", party: .host, weak: entry.weakParty)
                matrixValue(entry.cableRatedWatts.map { "\($0) W max" } ?? "Unknown", party: .cable, weak: entry.weakParty)
                matrixValue("—", party: .device, weak: entry.weakParty)
            }
            GridRow {
                Text("Transport").foregroundStyle(.secondary)
                Text(entry.port.transportsSupported.joined(separator: ", ")).font(.caption)
                Text(cableTypeLabel(entry.cableIdentity?.cableVDO?.cableType)).font(.caption)
                Text(facts.deviceName ?? "Unknown").font(.caption)
            }
        }
        .font(.caption)
    }

    private func cableTypeLabel(_ type: PDVDO.CableType?) -> String {
        switch type {
        case .passive: "Passive"
        case .active: "Active"
        case .other: "Other"
        case nil: "Unknown"
        }
    }

    private func partyHeader(_ title: String, party: NegotiationDiagnosticsModel.CapabilityParty, weak: NegotiationDiagnosticsModel.CapabilityParty?) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(weak == party ? Color.manifoldWarning : Color.manifoldText)
    }

    private func matrixValue(_ value: String, party: NegotiationDiagnosticsModel.CapabilityParty, weak: NegotiationDiagnosticsModel.CapabilityParty?) -> some View {
        Text(value)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(weak == party ? Color.manifoldWarning.opacity(0.16) : Color.clear))
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold))
        }
    }

    private func emptyState(title: String, detail: String) -> some View {
        ContentUnavailableView(title, systemImage: "arrow.left.arrow.right", description: Text(detail))
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value.rounded() == value ? 0 : 1)))
    }
}
