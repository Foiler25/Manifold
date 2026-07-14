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
// SavedCablesView.swift

import SwiftUI

enum CableHistoryLoadResult<Value> {
    case loaded(Value)
    case failed(String)
}

@MainActor
func loadCableHistory<Value>(
    _ operation: () async throws -> Value
) async -> CableHistoryLoadResult<Value> {
    do {
        return .loaded(try await operation())
    } catch {
        return .failed(error.localizedDescription)
    }
}

struct SavedCablesView: View {
    let repository: CableHistoryRepository?
    @Bindable var engine: CableEngine

    @State private var cables: [SavedCable] = []
    @State private var selectedID: String?
    @State private var sessions: [CableSession] = []
    @State private var isLoading = true
    @State private var isLoadingSessions = false
    @State private var loadError: String?
    @State private var sessionLoadError: String?

    var body: some View {
        Group {
            if repository == nil {
                ContentUnavailableView(
                    "Cable history is unavailable",
                    systemImage: "externaldrive.badge.xmark",
                    description: Text("Manifold couldn't open its local history database.")
                )
            } else if isLoading {
                ProgressView("Loading saved cables…")
            } else if let loadError {
                ContentUnavailableView {
                    Label("Couldn't load saved cables", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try Again") { Task { await reload() } }
                }
            } else if cables.isEmpty {
                ContentUnavailableView(
                    "No saved cables",
                    systemImage: "bookmark",
                    description: Text("Save a cable from its port card, then reconnect it to build a timeline.")
                )
            } else {
                HSplitView {
                    cableList
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                    detail
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .accessibilityIdentifier("window.tab.savedCables.root")
        .task { await reload() }
        .task(id: selectedID) { await loadSessions() }
        .toolbar { DetachToolbarButton(screen: .savedCables) }
    }

    private var cableList: some View {
        List(cables, selection: $selectedID) { cable in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(cable.displayName).fontWeight(.semibold)
                    Spacer()
                    verdictChip(cable.verdictSummary.worstVerdict)
                }
                Text(cable.curatedBrand ?? cable.vendorName ?? String(localized: "Unknown vendor"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Last seen \(cable.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .tag(cable.id)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedID,
           let cable = cables.first(where: { $0.id == selectedID }) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    summary(cable)
                    Text("Session timeline")
                        .font(.headline)
                    if isLoadingSessions {
                        ProgressView("Loading sessions…")
                    } else if let sessionLoadError {
                        ContentUnavailableView {
                            Label("Couldn't load session history", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(sessionLoadError)
                        } actions: {
                            Button("Try Again") { Task { await loadSessions() } }
                        }
                    } else if sessions.isEmpty {
                        Text("No completed observations yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sessions) { session in
                            sessionRow(session)
                        }
                    }
                }
                .padding(20)
            }
        } else {
            ContentUnavailableView(
                "Select a cable",
                systemImage: "cable.connector.horizontal"
            )
        }
    }

    private func summary(_ cable: SavedCable) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(cable.displayName).font(.title2.weight(.semibold))
                    Text(cable.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                verdictChip(cable.verdictSummary.worstVerdict)
            }
            Text("\(cable.verdictSummary.totalSessions) sessions since \(cable.firstSeen.formatted(date: .abbreviated, time: .omitted))")
                .font(.callout)
                .foregroundStyle(.secondary)
            if engine.snapshot?.identities.contains(where: { CableIdentity.key(for: $0) == cable.id }) == true {
                Label("Connected now", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func sessionRow(_ session: CableSession) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(verdictColor(session.verdict))
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .fontWeight(.medium)
                    Spacer()
                    verdictChip(session.verdict)
                }
                HStack(spacing: 12) {
                    Text(session.portKey)
                    if let speed = session.negotiatedGbps { Text("\(speed.formatted()) Gbps") }
                    if let power = session.negotiatedWatts { Text("\(power) W") }
                    Text("\(session.observationCount) samples")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let ended = session.endedAt {
                    Text("Duration \(duration(ended.timeIntervalSince(session.startedAt)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("In progress")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func reload() async {
        guard let repository else {
            isLoading = false
            return
        }
        isLoading = true
        switch await loadCableHistory({ try await repository.savedCables() }) {
        case let .loaded(value):
            cables = value
            loadError = nil
            if selectedID == nil { selectedID = cables.first?.id }
        case let .failed(message):
            loadError = message
        }
        isLoading = false
    }

    private func loadSessions() async {
        guard let repository, let selectedID else {
            sessions = []
            sessionLoadError = nil
            return
        }
        sessions = []
        sessionLoadError = nil
        isLoadingSessions = true
        switch await loadCableHistory({
            try await repository.sessions(cableID: selectedID)
        }) {
        case let .loaded(value):
            sessions = value
        case let .failed(message):
            sessionLoadError = message
        }
        isLoadingSessions = false
    }

    private func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }

    private func verdictColor(_ verdict: SessionMonitor.Verdict?) -> Color {
        switch verdict {
        case .performing: .green
        case .caution: .orange
        case .notPerforming: .red
        case nil: .secondary
        }
    }

    private func verdictChip(_ verdict: SessionMonitor.Verdict?) -> some View {
        Text(verdictLabel(verdict))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(verdictColor(verdict))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(verdictColor(verdict).opacity(0.13), in: Capsule())
    }

    private func verdictLabel(_ verdict: SessionMonitor.Verdict?) -> String {
        switch verdict {
        case .performing: String(localized: "Performing")
        case .caution: String(localized: "Caution")
        case .notPerforming: String(localized: "Needs attention")
        case nil: String(localized: "Not yet rated")
        }
    }
}
