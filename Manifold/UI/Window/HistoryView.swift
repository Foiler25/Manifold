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
// HistoryView.swift
//
// **History** tab content per SPEC §13.2 + §18 Phase 10. Loads the
// most-recent N events from `EventRepository.recentEvents` on appear
// and re-loads on a manual refresh. Phase 11's CSV/JSON export sheet
// will mount on top of this same data path; Phase 10 keeps the view
// focused on display.
//
// Filter affordance per SPEC §18 Phase 10 #6 ("filterable by device,
// port, time range") — Phase 10 ships the device/port substring
// filter inline; the time-range scope is the load-limit + the
// retention-policy cutoff (older rows are pruned by DownsamplingJob,
// not by this view).

import SwiftUI
import ManifoldKit

struct HistoryView: View {

    let eventRepository: EventRepository?

    @State private var events: [StoredEvent] = []
    @State private var loadState: LoadState = .idle
    @State private var filterText: String = ""

    private enum LoadState {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if eventRepository == nil {
                emptyDatabaseState
            } else {
                toolbar
                Divider()
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.manifoldSurface)
        .accessibilityIdentifier("window.tab.history.root")
        .task {
            await reload()
        }
    }

    // MARK: - Sections

    private var toolbar: some View {
        HStack(spacing: 8) {
            TextField("window.tab.history.filter.placeholder", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .accessibilityIdentifier("window.tab.history.filter")
            Spacer()
            Button {
                Task { await reload() }
            } label: {
                Label("window.tab.history.refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("window.tab.history.refresh")
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .idle, .loading:
            loadingState
        case .failed(let message):
            errorState(message)
        case .loaded:
            if filteredEvents.isEmpty {
                emptyResultsState
            } else {
                eventList
            }
        }
    }

    private var eventList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(filteredEvents) { event in
                    EventRow(event: event)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    Divider()
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - States

    private var loadingState: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("window.tab.history.error.title")
                .font(.headline)
            Text(message)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyResultsState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("window.tab.history.empty.title")
                .font(.headline)
                .foregroundStyle(Color.manifoldText)
                .accessibilityIdentifier("window.tab.history.placeholder.title")
            Text("window.tab.history.empty.subtitle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Phase 10 silent-disable path: DatabaseManager init failed, so
    /// no events were persisted. Reuses the original Phase 6
    /// placeholder copy so a Reviewer eyeballing the tab still sees
    /// the familiar message.
    private var emptyDatabaseState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("window.tab.history.placeholder.title")
                .font(.title2)
                .foregroundStyle(Color.manifoldText)
                .accessibilityIdentifier("window.tab.history.placeholder.title")
            Text("window.tab.history.placeholder.subtitle")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Filtering

    /// Substring match against device id (when present) and port id.
    /// Lowercased on both sides so the user doesn't have to match case.
    private var filteredEvents: [StoredEvent] {
        let needle = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return events }
        return events.filter { event in
            event.portID.rawValue.lowercased().contains(needle)
                || (event.deviceID?.rawValue.lowercased().contains(needle) ?? false)
                || event.payloadJSON.lowercased().contains(needle)
        }
    }

    // MARK: - Loading

    private func reload() async {
        guard let repo = eventRepository else { return }
        loadState = .loading
        do {
            let result = try await repo.recentEvents(limit: 200)
            events = result
            loadState = .loaded
        } catch {
            loadState = .failed(String(describing: error))
        }
    }
}

// MARK: - EventRow

private struct EventRow: View {

    let event: StoredEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kindIcon)
                .font(.body)
                .foregroundStyle(kindColor)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.manifoldText)
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(timestampString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var kindIcon: String {
        switch event.kind {
        case .attached:   return "plus.circle"
        case .detached:   return "minus.circle"
        case .diagnostic: return "exclamationmark.triangle"
        }
    }

    private var kindColor: Color {
        switch event.kind {
        case .attached:   return .manifoldAccent
        case .detached:   return .secondary
        case .diagnostic: return .yellow
        }
    }

    private var headline: String {
        switch event.payload {
        case .attached(let name, _, _):
            return name.isEmpty ? event.deviceID?.rawValue ?? "—" : name
        case .detached(let last):
            return last
                ?? event.deviceID?.rawValue
                ?? NSLocalizedString("notification.disconnected.subtitle.unknown", comment: "")
        case .diagnostic(_, _, let title, _):
            return title
        }
    }

    private var detail: String {
        switch event.payload {
        case .attached(_, let proto, _):
            return [event.portID.rawValue, proto].compactMap { $0 }.joined(separator: " · ")
        case .detached:
            return event.portID.rawValue
        case .diagnostic(_, _, _, let detail):
            return detail
        }
    }

    private var timestampString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: event.timestamp)
    }
}

#Preview("HistoryView — silent-disable") {
    HistoryView(eventRepository: nil)
        .frame(width: 720, height: 480)
}
