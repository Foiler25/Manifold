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
// ─────────────────────────────────────────────────────────────────────
// PowerView.swift
//
// "Power" tab content — surfaces the active wall-power source
// (MagSafe / USB-C PD / wireless) plus everything macOS exposes about
// the active adapter (manufacturer, voltage, amperage, FamilyCode).
// Below that, summarises the USB-side draw the host is currently
// passing through to peripherals so users can see input vs output at
// a glance.

import SwiftUI
import ManifoldKit

struct PowerView: View {

    @Bindable var graph: PortGraph

    /// Currently-displayed host. nil → no hosts in the graph yet
    /// (cold launch); `emptyState` covers that.
    let host: ManifoldKit.Host?

    var body: some View {
        if let host {
            populated(host: host)
        } else {
            emptyState
        }
    }

    // MARK: - Populated

    private func populated(host: ManifoldKit.Host) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                inputSection(host: host)
                Divider()
                drawSection(host: host)
                if let adapter = host.inputAdapter {
                    Divider()
                    detailSection(adapter: adapter)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("window.tab.power.populated")
    }

    // MARK: - Sections

    private func inputSection(host: ManifoldKit.Host) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("window.power.section.input")
            HStack(alignment: .center, spacing: 16) {
                // Big source-type icon. Tints accent green so the live
                // power state reads as the page's primary signal.
                Image(systemName: sourceIconName(for: host.inputAdapter?.source))
                    .font(.system(size: 40))
                    .foregroundStyle(host.inputAdapter == nil
                                     ? Color.secondary
                                     : Color.manifoldAccent)
                    .frame(width: 56, height: 56)
                    .background(Color.manifoldCard)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text(sourceHeadline(for: host.inputAdapter))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.manifoldText)
                    if let adapter = host.inputAdapter {
                        Text(adapter.watts.formatted)
                            .font(.title2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Color.manifoldAccent)
                    } else {
                        Text("window.power.source.unplugged.subtitle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
    }

    private func drawSection(host: ManifoldKit.Host) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("window.power.section.draw")
            HStack(alignment: .firstTextBaseline) {
                Text("window.power.field.totalDraw")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(host.totalPowerDraw.formatted)
                    .font(.subheadline.monospacedDigit().weight(isOverBudget(host) ? .semibold : .regular))
                    .foregroundStyle(isOverBudget(host) ? Color.manifoldCritical : Color.manifoldText)
                if isOverBudget(host) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.manifoldCritical)
                        .help("window.power.overbudget.help")
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("window.power.field.connectedDevices")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(host.ports.compactMap(\.connectedDevice).count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.manifoldText)
            }
            // Per-device breakdown: every connected device with a
            // known draw, sorted high→low so the biggest consumers
            // surface at the top.
            let drawingDevices = devicesByDraw(host: host)
            if !drawingDevices.isEmpty {
                Divider().padding(.vertical, 4)
                ForEach(drawingDevices, id: \.id) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "cable.connector")
                            .foregroundStyle(Color.manifoldAccent.opacity(0.7))
                            .frame(width: 16)
                        Text(entry.name)
                            .font(.subheadline)
                            .foregroundStyle(Color.manifoldText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Text(entry.watts.formatted)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func detailSection(adapter: AdapterInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("window.power.section.details")
            if let description = adapter.description, !description.isEmpty {
                detailRow("window.power.field.description", description)
            }
            if let manufacturer = adapter.manufacturer, !manufacturer.isEmpty {
                detailRow("window.power.field.manufacturer", manufacturer)
            }
            if let model = adapter.model, !model.isEmpty {
                detailRow("window.power.field.model", model)
            }
            if let voltage = adapter.voltage {
                detailRow("window.power.field.voltage", String(format: "%.1f V", voltage))
            }
            if let amperage = adapter.amperage {
                detailRow("window.power.field.current", String(format: "%.2f A", amperage))
            }
            if let familyCode = adapter.familyCode {
                detailRow("window.power.field.familyCode", String(format: "0x%08X", familyCode))
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.slash")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("window.power.empty.title")
                .font(.headline)
                .foregroundStyle(Color.manifoldText)
            Text("window.power.empty.subtitle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("window.tab.power.empty.title")
    }

    // MARK: - Helpers

    private func sectionHeader(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption.smallCaps())
            .foregroundStyle(.secondary)
    }

    private func detailRow(_ labelKey: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(labelKey)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Color.manifoldText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(value)
        }
    }

    private func sourceIconName(for source: AdapterInfo.Source?) -> String {
        guard let source else { return "battery.50" }
        switch source {
        case .magsafe:  return "bolt.batteryblock.fill"
        case .usbC:     return "bolt.fill"
        case .wireless: return "bolt.badge.checkmark.fill"
        case .unknown:  return "bolt.fill"
        }
    }

    /// Headline text for the input section. Combines the source name
    /// and the kernel's free-form description when both are present.
    private func sourceHeadline(for adapter: AdapterInfo?) -> String {
        guard let adapter else {
            return NSLocalizedString("window.power.source.unplugged.title", comment: "")
        }
        let key: String
        switch adapter.source {
        case .magsafe:  key = "window.power.source.magsafe.title"
        case .usbC:     key = "window.power.source.usbC.title"
        case .wireless: key = "window.power.source.wireless.title"
        case .unknown:  key = "window.power.source.unknown.title"
        }
        return NSLocalizedString(key, comment: "")
    }

    /// Flatten every connected device with a known per-port draw,
    /// sorted descending so the page reads "biggest consumer first".
    private func devicesByDraw(host: ManifoldKit.Host) -> [DrawEntry] {
        var entries: [DrawEntry] = []
        func walk(_ ports: [ManifoldKit.Port]) {
            for port in ports {
                if let device = port.connectedDevice, let watts = port.powerDraw {
                    entries.append(DrawEntry(
                        id: device.id.rawValue,
                        name: device.displayName.isEmpty
                            ? "\(device.vendorID):\(device.productID)"
                            : device.displayName,
                        watts: watts
                    ))
                }
                walk(port.children)
            }
        }
        walk(host.ports)
        return entries.sorted { $0.watts.value > $1.watts.value }
    }

    private struct DrawEntry: Hashable {
        let id: String
        let name: String
        let watts: Watts
    }

    /// True when the host is drawing more from USB than the active
    /// charger is supplying — a "soft" overdraw signal because macOS
    /// pulls the difference from the battery, but worth surfacing so
    /// the user notices their headroom has gone negative.
    private func isOverBudget(_ host: ManifoldKit.Host) -> Bool {
        guard let input = host.inputAdapter?.watts.value else { return false }
        return host.totalPowerDraw.value > input
    }
}

#Preview("PowerView — populated") {
    let graph = PortGraph()
    graph.replace(hosts: [PreviewData.macBook])
    return PowerView(graph: graph, host: PreviewData.macBook)
        .frame(width: 540, height: 600)
        .background(Color.manifoldSurface)
}

#Preview("PowerView — empty") {
    PowerView(graph: PortGraph(), host: nil)
        .frame(width: 540, height: 600)
        .background(Color.manifoldSurface)
}
