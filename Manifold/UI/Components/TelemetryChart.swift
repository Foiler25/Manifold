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
// TelemetryChart.swift
//
// Labeled line chart of the last ~60 power-draw samples for a port.
// Replaces the bare Sparkline used in earlier phases. Two visual modes
// share the same data path so the popover and the main-window inspector
// render identically (same component, same dot cadence) — only the
// height and tick density differ.
//
//   - LineMark: smooth line through every sample.
//   - PointMark: dot every 10 seconds (every 10th sample at the 1 Hz
//     default sample rate). Aligns with the X-axis grid lines, so the
//     dots act as both visual cadence markers and tick anchors.
//   - X axis: relative time labels (Now, −10s, −20s, …) at each dot.
//   - Y axis: power in watts at the leading edge.
//
// Accessibility falls back to a one-line spoken summary identical to
// the previous Sparkline (current value, range, sample count). Per-mark
// VoiceOver would read "0.5", "0.51", "0.49"… which is unusable.

import SwiftUI
import Charts
import ManifoldKit

struct TelemetryChart: View {

    /// Samples to plot, oldest-first.
    let samples: [TelemetrySample]

    /// Visual mode controls labels, sizing, and tick density. The same
    /// chart shape renders in both — only chrome differs.
    enum Style {
        /// Inline mode for the menu-bar popover device rows. Compact,
        /// labels rendered in caption2, smaller plot area.
        case inline
        /// Expanded mode for the main-window inspector telemetry pane.
        /// Larger plot, more breathing room around axis labels.
        case expanded
    }

    var style: Style = .expanded

    var body: some View {
        Group {
            if samples.isEmpty {
                placeholder
            } else {
                chart
            }
        }
        .frame(height: style.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NSLocalizedString("accessibility.sparkline.label", comment: ""))
        .accessibilityValue(accessibilityValue)
    }

    // MARK: - Chart

    private var chart: some View {
        Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                if let watts = sample.watts?.value {
                    LineMark(
                        x: .value("sample", index),
                        y: .value("watts", watts)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.manifoldAccent)

                    if isDotIndex(index) {
                        PointMark(
                            x: .value("sample", index),
                            y: .value("watts", watts)
                        )
                        .symbolSize(style.dotSize)
                        .foregroundStyle(Color.manifoldAccent)
                    }
                }
            }
        }
        .chartXAxis { xAxis }
        .chartYAxis { yAxis }
        .chartYScale(domain: yDomain)
        .chartPlotStyle { plot in
            plot.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var xAxis: some AxisContent {
        AxisMarks(values: dotIndices) { value in
            AxisGridLine()
                .foregroundStyle(Color.secondary.opacity(0.15))
            AxisValueLabel {
                if let i = value.as(Int.self) {
                    Text(timeLabel(for: i))
                        .font(style.axisLabelFont)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var yAxis: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: style.yTickCount)) { value in
            AxisGridLine()
                .foregroundStyle(Color.secondary.opacity(0.15))
            AxisValueLabel {
                if let watts = value.as(Double.self) {
                    Text(wattsLabel(watts))
                        .font(style.axisLabelFont)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Empty state

    private var placeholder: some View {
        VStack(spacing: 4) {
            Image(systemName: "chart.line.flattrend.xyaxis")
                .font(style == .inline ? .caption : .title3)
                .foregroundStyle(.secondary)
            Text("telemetry.empty.caption")
                .font(style.axisLabelFont)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    /// Indices of samples that should get a dot marker. With the default
    /// 1 Hz sample rate, every 10th sample = a 10 s tick. Built so the
    /// rightmost dot lands on "now" (the latest sample) regardless of
    /// the buffer's current length.
    private var dotIndices: [Int] {
        guard !samples.isEmpty else { return [] }
        let last = samples.count - 1
        return Array(stride(from: last, through: 0, by: -10)).reversed()
    }

    private func isDotIndex(_ index: Int) -> Bool {
        guard !samples.isEmpty else { return false }
        return (samples.count - 1 - index) % 10 == 0
    }

    /// "Now" for the latest sample, "−10s" / "−20s" / … for older
    /// 10-second markers. Negative-prefix matches macOS conventions for
    /// time-relative labels (e.g. Activity Monitor's CPU graph).
    private func timeLabel(for sampleIndex: Int) -> String {
        let secondsAgo = samples.count - 1 - sampleIndex
        if secondsAgo == 0 {
            return NSLocalizedString("telemetry.axis.now", comment: "")
        }
        return String(
            format: NSLocalizedString("telemetry.axis.secondsAgo", comment: ""),
            secondsAgo
        )
    }

    private func wattsLabel(_ watts: Double) -> String {
        if watts == 0 { return "0 W" }
        if watts < 1 {
            return String(format: "%.1f W", watts)
        }
        return String(format: "%.0f W", watts)
    }

    /// Auto-zoom Y range with a 15% headroom. Falls back to [0, 1]
    /// when the buffer has nil watts only — produces a flat line at
    /// the bottom rather than a Charts "no domain" warning.
    private var yDomain: ClosedRange<Double> {
        let values = samples.compactMap { $0.watts?.value }
        guard let maxValue = values.max(), maxValue > 0 else {
            return 0...1
        }
        return 0...(maxValue * 1.15)
    }

    /// One-line spoken summary derived from the samples, identical to
    /// the previous Sparkline so VoiceOver users hear consistent text.
    private var accessibilityValue: String {
        let watts = samples.compactMap { $0.watts?.value }
        guard let last = watts.last else {
            return NSLocalizedString("accessibility.sparkline.empty", comment: "")
        }
        let minV = watts.min() ?? last
        let maxV = watts.max() ?? last
        return String(
            format: NSLocalizedString("accessibility.sparkline.summary", comment: ""),
            last, minV, maxV, watts.count
        )
    }
}

// MARK: - Style sizing

extension TelemetryChart.Style {
    var height: CGFloat {
        switch self {
        case .inline:   return 72
        case .expanded: return 140
        }
    }

    var dotSize: CGFloat {
        switch self {
        case .inline:   return 18
        case .expanded: return 32
        }
    }

    var yTickCount: Int {
        switch self {
        case .inline:   return 3
        case .expanded: return 4
        }
    }

    var axisLabelFont: Font {
        switch self {
        case .inline:   return .system(size: 9)
        case .expanded: return .caption2
        }
    }
}

// MARK: - Previews

private func previewBuffer(seed: Double) -> [TelemetrySample] {
    (0..<60).map { i in
        TelemetrySample(
            timestamp: Date(timeIntervalSince1970: TimeInterval(i)),
            watts: Watts(seed + sin(Double(i) / 5.0) * 0.3 + Double(i) * 0.01),
            bitrate: nil
        )
    }
}

#Preview("TelemetryChart — expanded (inspector)") {
    TelemetryChart(samples: previewBuffer(seed: 2.5), style: .expanded)
        .frame(width: 320)
        .padding()
        .background(Color.manifoldSurface)
}

#Preview("TelemetryChart — inline (popover row)") {
    TelemetryChart(samples: previewBuffer(seed: 0.8), style: .inline)
        .frame(width: 240)
        .padding()
        .background(Color.manifoldSurface)
}

#Preview("TelemetryChart — empty") {
    VStack(spacing: 16) {
        TelemetryChart(samples: [], style: .expanded)
            .frame(width: 320)
        TelemetryChart(samples: [], style: .inline)
            .frame(width: 240)
    }
    .padding()
    .background(Color.manifoldSurface)
}
