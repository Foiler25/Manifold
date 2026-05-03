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
// ExportSheet.swift
//
// Per SPEC §13.2 + §18 Phase 11 #4. Modal sheet that lets the user
// pick:
//   - Kind: Event log CSV / Telemetry samples CSV / Full topology JSON
//   - Scope: Full / Single host / Single device  (CSV ignores; JSON respects)
//   - Time range: All / Last 24h / Last 7d / Last 30d  (CSV only)
//
// "Export…" button opens an `NSSavePanel` with a sane default
// filename + the right `UTType` for the kind. Failure shows an
// inline error alert; success dismisses.

import SwiftUI
import UniformTypeIdentifiers
import ManifoldKit

struct ExportSheet: View {

    @Environment(\.dismiss) private var dismiss

    @Bindable var graph: PortGraph
    let eventRepository: EventRepository?
    let sampleRepository: SampleRepository?

    @State private var kind: ExportKind = .eventLogCSV
    @State private var scope: ExportScope = .fullTopology
    @State private var timeRange: ExportTimeRange = .all
    @State private var status: Status = .idle

    private enum Status {
        case idle
        case running
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("export.sheet.title")
                .font(.title2.weight(.semibold))

            Form {
                Section {
                    Picker("export.field.kind", selection: $kind) {
                        ForEach(ExportKind.allCases) { kind in
                            Text(kind.localizedTitle).tag(kind)
                        }
                    }
                }

                if kind == .topologyJSON {
                    Section {
                        Picker("export.field.scope", selection: $scope) {
                            Text("export.scope.full").tag(ExportScope.fullTopology)
                            ForEach(graph.hosts) { host in
                                Text(host.name).tag(ExportScope.host(host.id))
                            }
                            ForEach(allDevices(), id: \.0) { id, name in
                                Text(name).tag(ExportScope.device(id))
                            }
                        }
                    }
                } else {
                    Section {
                        Picker("export.field.timeRange", selection: $timeRange) {
                            ForEach(ExportTimeRange.allCases) { range in
                                Text(range.localizedTitle).tag(range)
                            }
                        }
                    }
                }

                if case .failed(let message) = status {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption.monospaced())
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("export.action.cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("export.action.save") {
                    runExport()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning || isExportInapplicable)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    // MARK: - Action

    private var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    /// Disable the export button when the kind requires a repository
    /// that isn't available (silent-disable case from Phase 10).
    private var isExportInapplicable: Bool {
        switch kind {
        case .eventLogCSV:    return eventRepository == nil
        case .telemetryCSV:   return sampleRepository == nil
        case .topologyJSON:   return false  // doesn't need persistence; uses live graph
        }
    }

    private func runExport() {
        status = .running
        Task {
            do {
                let data = try await produceData()
                let url = await MainActor.run { presentSavePanel(forKind: kind) }
                guard let url else {
                    await MainActor.run { status = .idle }
                    return
                }
                try data.write(to: url, options: [.atomic])
                await MainActor.run {
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    status = .failed(String(describing: error))
                }
            }
        }
    }

    private func produceData() async throws -> Data {
        switch kind {
        case .eventLogCSV:
            guard let repo = eventRepository else {
                throw ExportError.repositoryUnavailable
            }
            // F24 closure (Phase 11 review, due Phase 14): the
            // repo's new `events(since:limit:)` filters at the SQL
            // layer so a 30-day export doesn't have to drag every
            // 1-year-retention row through memory first.
            // `.distantPast` keeps the legacy "All time" semantics.
            let scoped = try await repo.events(since: timeRange.cutoff(now: .now))
            return EventLogCSVExporter.encodeData(scoped)

        case .telemetryCSV:
            guard let repo = sampleRepository else {
                throw ExportError.repositoryUnavailable
            }
            let cutoff = timeRange.cutoff(now: .now)
            // Across every port, every aggregation. For "all time"
            // the cutoff is `.distantPast` so the repository returns
            // every row.
            var samples: [StoredSample] = []
            for port in allPortIDs() {
                for aggregation in SampleAggregation.allCases {
                    samples.append(contentsOf: try await repo.samples(forPort: port, since: cutoff, aggregation: aggregation))
                }
            }
            samples.sort { $0.timestamp < $1.timestamp }
            return SampleCSVExporter.encodeData(samples)

        case .topologyJSON:
            guard let data = TopologyJSONExporter.encode(hosts: graph.hosts, scope: jsonScope) else {
                throw ExportError.scopeNotFound
            }
            return data
        }
    }

    /// Map the SwiftUI scope picker into `TopologyJSONExporter.Scope`.
    private var jsonScope: TopologyJSONExporter.Scope {
        switch scope {
        case .fullTopology:      return .fullTopology
        case .host(let id):      return .host(id)
        case .device(let id):    return .device(id)
        }
    }

    /// Every port id in the graph (recursive) so the sample export
    /// covers every history. Sample queries are per-port so we have
    /// to enumerate.
    private func allPortIDs() -> [PortID] {
        var out: [PortID] = []
        func walk(_ ports: [ManifoldKit.Port]) {
            for port in ports {
                out.append(port.id)
                walk(port.children)
            }
        }
        for host in graph.hosts { walk(host.ports) }
        return out
    }

    /// Every (DeviceID, name) pair for the scope picker.
    private func allDevices() -> [(DeviceID, String)] {
        var out: [(DeviceID, String)] = []
        func walk(_ ports: [ManifoldKit.Port]) {
            for port in ports {
                if let device = port.connectedDevice {
                    out.append((device.id, device.name))
                }
                walk(port.children)
            }
        }
        for host in graph.hosts { walk(host.ports) }
        return out
    }

    // MARK: - Save panel

    private func presentSavePanel(forKind kind: ExportKind) -> URL? {
        let panel = NSSavePanel()
        panel.title = NSLocalizedString("export.panel.title", comment: "Save panel title.")
        panel.nameFieldStringValue = kind.defaultFilename(now: .now)
        panel.allowedContentTypes = [kind.utType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let response = panel.runModal()
        return response == .OK ? panel.url : nil
    }
}

// MARK: - Supporting types

enum ExportKind: String, CaseIterable, Identifiable {
    case eventLogCSV
    case telemetryCSV
    case topologyJSON

    var id: String { rawValue }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .eventLogCSV:  return "export.kind.events"
        case .telemetryCSV: return "export.kind.samples"
        case .topologyJSON: return "export.kind.topology"
        }
    }

    var utType: UTType {
        switch self {
        case .eventLogCSV, .telemetryCSV: return .commaSeparatedText
        case .topologyJSON:               return .json
        }
    }

    func defaultFilename(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let stamp = formatter.string(from: now)
        switch self {
        case .eventLogCSV:  return "manifold-events-\(stamp).csv"
        case .telemetryCSV: return "manifold-samples-\(stamp).csv"
        case .topologyJSON: return "manifold-topology-\(stamp).json"
        }
    }
}

enum ExportScope: Hashable {
    case fullTopology
    case host(HostID)
    case device(DeviceID)
}

enum ExportTimeRange: String, CaseIterable, Identifiable {
    case all
    case last24h
    case last7d
    case last30d

    var id: String { rawValue }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .all:     return "export.range.all"
        case .last24h: return "export.range.24h"
        case .last7d:  return "export.range.7d"
        case .last30d: return "export.range.30d"
        }
    }

    /// Cutoff date — rows older than this are excluded. `.distantPast`
    /// for `.all` means "no filter".
    func cutoff(now: Date) -> Date {
        switch self {
        case .all:     return .distantPast
        case .last24h: return now.addingTimeInterval(-86_400)
        case .last7d:  return now.addingTimeInterval(-604_800)
        case .last30d: return now.addingTimeInterval(-2_592_000)
        }
    }
}

/// Localized error messages get rendered into the failure-state row;
/// the underlying `String(describing: error)` gives the developer a
/// signal to debug from in the rare disk-write failure case.
enum ExportError: LocalizedError {
    case repositoryUnavailable
    case scopeNotFound

    var errorDescription: String? {
        switch self {
        case .repositoryUnavailable:
            return NSLocalizedString("export.error.repositoryUnavailable", comment: "")
        case .scopeNotFound:
            return NSLocalizedString("export.error.scopeNotFound", comment: "")
        }
    }
}

#Preview("ExportSheet — populated") {
    let graph = PortGraph()
    graph.replace(hosts: [PreviewData.macBook])
    return ExportSheet(graph: graph, eventRepository: nil, sampleRepository: nil)
}
