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
// HistoryPane.swift
//
// Phase 10 settings pane: retention policy sliders + "compact
// database now" affordance + database size display per SPEC §18
// Phase 10 #7.
//
// Phase 14 will compose this pane into the full `SettingsScene`.
// Phase 10 ships it standalone with a #Preview, the same way Phase 9
// shipped NotificationsPane. Database manager + downsampling job
// are passed in as opaque `Storage` parameters so the pane can be
// previewed against nil (silent-disable path).

import SwiftUI

struct HistoryPane: View {

    /// Phase 10: nil when DatabaseManager init failed at app launch.
    /// In that case we render a degraded pane with disabled controls
    /// + an explanation banner.
    let databaseManager: DatabaseManager?

    /// Phase 10: applies new retention values to the running job
    /// without waiting for a relaunch.
    let downsamplingJob: DownsamplingJob?

    /// Retention values persisted via @AppStorage in seconds. Sliders
    /// bind to derived bindings that convert to/from days for the
    /// user-facing scale.
    @AppStorage(HistoryPane.Key.rawRetentionSeconds)
    private var rawRetentionSeconds: Double = RetentionPolicy.default.rawRetention

    @AppStorage(HistoryPane.Key.oneMinRetentionSeconds)
    private var oneMinRetentionSeconds: Double = RetentionPolicy.default.oneMinRetention

    @AppStorage(HistoryPane.Key.oneHourRetentionSeconds)
    private var oneHourRetentionSeconds: Double = RetentionPolicy.default.oneHourRetention

    /// Local UI state for the "compact database" button.
    @State private var compactState: CompactState = .idle
    @State private var dbSize: Int64 = 0

    enum Key {
        static let rawRetentionSeconds     = "history.retention.raw.seconds"
        static let oneMinRetentionSeconds  = "history.retention.1min.seconds"
        static let oneHourRetentionSeconds = "history.retention.1hour.seconds"
    }

    private enum CompactState {
        case idle
        case running
        case done(savedBytes: Int64)
        case failed(String)
    }

    var body: some View {
        Form {
            if databaseManager == nil {
                Section {
                    Label("settings.history.disabled.banner", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }

            Section("settings.history.retention.section") {
                retentionRow(
                    title: "settings.history.retention.raw.title",
                    detail: "settings.history.retention.raw.detail",
                    seconds: $rawRetentionSeconds,
                    range: 3600...604_800,                // 1 hour .. 7 days
                    step: 3600,
                    unit: .hours
                )
                retentionRow(
                    title: "settings.history.retention.oneMin.title",
                    detail: "settings.history.retention.oneMin.detail",
                    seconds: $oneMinRetentionSeconds,
                    range: 86_400...7_776_000,           // 1 day .. 90 days
                    step: 86_400,
                    unit: .days
                )
                retentionRow(
                    title: "settings.history.retention.oneHour.title",
                    detail: "settings.history.retention.oneHour.detail",
                    seconds: $oneHourRetentionSeconds,
                    range: 604_800...63_072_000,         // 1 week .. 2 years
                    step: 604_800,
                    unit: .days
                )
            }

            Section("settings.history.maintenance.section") {
                LabeledContent("settings.history.dbSize.title") {
                    Text(formattedDBSize)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button {
                    runCompact()
                } label: {
                    Label("settings.history.compact.button", systemImage: "internaldrive")
                }
                .disabled(databaseManager == nil || isCompactRunning)

                switch compactState {
                case .idle:
                    EmptyView()
                case .running:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("settings.history.compact.running")
                            .foregroundStyle(.secondary)
                    }
                case .done(let saved):
                    Text(String(format: NSLocalizedString("settings.history.compact.done", comment: ""), formatted(saved)))
                        .foregroundStyle(Color.manifoldAccent)
                case .failed(let msg):
                    Text(msg)
                        .foregroundStyle(.red)
                        .font(.caption.monospaced())
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 460, minHeight: 420)
        .onChange(of: rawRetentionSeconds) { _, _ in pushPolicy() }
        .onChange(of: oneMinRetentionSeconds) { _, _ in pushPolicy() }
        .onChange(of: oneHourRetentionSeconds) { _, _ in pushPolicy() }
        .task {
            refreshDBSize()
        }
    }

    // MARK: - Retention row builder

    private enum SliderUnit {
        case hours
        case days
        var divisor: Double {
            switch self {
            case .hours: return 3600
            case .days:  return 86_400
            }
        }
        var label: String {
            switch self {
            case .hours: return NSLocalizedString("settings.history.unit.hours", comment: "")
            case .days:  return NSLocalizedString("settings.history.unit.days", comment: "")
            }
        }
    }

    @ViewBuilder
    private func retentionRow(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        seconds: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        unit: SliderUnit
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(seconds.wrappedValue / unit.divisor)) \(unit.label)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: seconds, in: range, step: step)
                .disabled(databaseManager == nil)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Compact

    private var isCompactRunning: Bool {
        if case .running = compactState { return true }
        return false
    }

    private func runCompact() {
        guard let manager = databaseManager else { return }
        compactState = .running
        let beforeSize = manager.onDiskSize()
        Task {
            do {
                try await manager.compact()
                let afterSize = manager.onDiskSize()
                let saved = max(0, beforeSize - afterSize)
                await MainActor.run {
                    compactState = .done(savedBytes: saved)
                    refreshDBSize()
                }
            } catch {
                await MainActor.run {
                    compactState = .failed(String(describing: error))
                }
            }
        }
    }

    // MARK: - Helpers

    private var formattedDBSize: String {
        formatted(dbSize)
    }

    private func formatted(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func refreshDBSize() {
        dbSize = databaseManager?.onDiskSize() ?? 0
    }

    /// Push the current @AppStorage retention values into the running
    /// downsampling job so changes take effect on the next tick
    /// without waiting for a relaunch.
    private func pushPolicy() {
        let policy = RetentionPolicy(
            rawRetention: rawRetentionSeconds,
            oneMinRetention: oneMinRetentionSeconds,
            oneHourRetention: oneHourRetentionSeconds
        )
        downsamplingJob?.updatePolicy(policy)
    }
}

#Preview("HistoryPane — disabled (DB init failed)") {
    HistoryPane(databaseManager: nil, downsamplingJob: nil)
}
