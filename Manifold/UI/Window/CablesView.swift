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
// CablesView.swift
//
// Phase 21 — body of the new Cables tab. Reads `engine.snapshot` and
// renders one `CablePortCard` per USB-C port. Three empty states:
//
//   1. No snapshot yet (cold launch race) → loading indicator.
//   2. Snapshot present, zero ports → "Apple-Silicon-only" hint
//      (covers Intel Macs and any host where macOS doesn't expose the
//      AppleHPMInterfaceType registry entries).
//   3. Snapshot present, ports present, none connected → "no cables
//      plugged in" hint sitting beneath the per-port card list.
//
// Layout mirrors `BatteryView` — card-per-section inside a ScrollView.

import SwiftUI
import ManifoldKit

struct CablesView: View {

    @Bindable var engine: CableEngine

    /// Manifold's existing graph — used to look up resolved volume
    /// names (e.g. "PlanckSSD" for a device whose USB product string
    /// is "Creator SSD") and the host-level adapter info (whether
    /// any charger is currently connected). The cables snapshot
    /// alone doesn't carry either fact.
    @Bindable var graph: PortGraph

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let snapshot = engine.snapshot {
                    if snapshot.ports.isEmpty {
                        CablesEmptyState(kind: .unsupportedHost)
                    } else {
                        ForEach(snapshot.ports) { port in
                            CablePortCard(
                                port: port,
                                snapshot: snapshot,
                                graph: graph
                            )
                        }
                        if snapshot.ports.allSatisfy({ $0.connectionActive != true }) {
                            CablesEmptyState(kind: .noCablesPluggedIn)
                                .padding(.top, 4)
                        }
                    }
                    if let lastError = engine.lastError {
                        errorBanner(lastError)
                    }
                } else {
                    CablesEmptyState(kind: .loading)
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(20)
        }
        .accessibilityIdentifier("window.tab.cables.populated")
    }

    /// Inline banner shown beneath the port list when the provider
    /// stream surfaces an error. We keep the existing port cards in
    /// view (last good snapshot) so the user still sees something
    /// useful while we surface the failure mode below.
    private func errorBanner(_ error: Error) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(Color.manifoldWarning)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("cables.error.title")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.manifoldText)
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
        }
        .padding(CablesViewConstants.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: CablesViewConstants.cardCornerRadius)
                .fill(Color.manifoldCard)
        )
    }
}

enum CablesViewConstants {
    static let cardPadding: CGFloat = 16
    static let cardCornerRadius: CGFloat = 12
}

#if DEBUG
// Bodies reference `PreviewCableProvider` (DEBUG-only in
// `CablesPreviewData.swift`). The `#Preview` macro doesn't gate its
// own expansion on DEBUG, so we have to gate manually or the Release
// build fails on the unresolved symbol.
#Preview("CablesView — loading (no snapshot yet)") {
    let engine = CableEngine(provider: PreviewCableProvider(snapshots: []))
    return CablesView(engine: engine, graph: PortGraph())
        .frame(width: 540, height: 400)
        .background(Color.manifoldSurface)
}

#Preview("CablesView — empty (Intel-Mac unsupported host)") {
    let engine = CableEngine(provider: PreviewCableProvider(snapshots: [.empty]))
    engine.start()
    return CablesView(engine: engine, graph: PortGraph())
        .frame(width: 540, height: 400)
        .background(Color.manifoldSurface)
}
#endif
