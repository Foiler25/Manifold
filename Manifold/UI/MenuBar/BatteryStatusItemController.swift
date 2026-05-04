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
// BatteryStatusItemController.swift
//
// Phase 18 — secondary `NSStatusItem` controller per D17 / SPEC §20.6.
// Sibling of `StatusItemController`, NOT a subclass — the two diverge
// on every meaningful axis (glyph family, title, popover content,
// install gate, observed graph property) and a sibling pattern keeps
// the two file-local concerns isolated.
//
// Glyph: SF Symbol family `battery.0/.25/.50/.75/.100` switched on
// the rounded `chargePercent` bucket. When charging, the same family
// is replaced with its `.bolt` variant (e.g. `battery.50.bolt`) so
// the menu bar reads "is charging" at a glance.
//
// Title: percentage rendered as `attributedTitle` with a leading space
// (matches the primary's spacing pattern from §13.1) and `imagePosition
// = .imageLeft`. The accessibility summary is composed on every
// `setBattery(_:)` via `DateComponentsFormatter` + a localized format
// string — VoiceOver reads "Battery 84%, charging, fully charged in
// 1 hour 24 minutes" rather than just "84%".

import AppKit
import SwiftUI
import os
import ManifoldKit

@MainActor
final class BatteryStatusItemController {

    // MARK: - State

    /// Held strongly because `NSStatusBar` releases the slot the
    /// moment we drop the reference.
    private var statusItem: NSStatusItem?

    /// Lazily constructed on first popover open. Same pattern the
    /// primary `StatusItemController` uses.
    private var popover: NSPopover?

    /// PortGraph reference — `setBattery(_:)` is called by AppDelegate
    /// each tick AND the popover content reads through `graph.battery`
    /// directly, so SwiftUI sees the same `@Observable` source of
    /// truth.
    private let graph: PortGraph

    /// AppDelegate hooks. The popover's "Open Manifold" toolbar
    /// button activates the app + brings the window forward.
    private let onOpenWindow: @MainActor () -> Void
    private let onPopoverDidShow: @MainActor () -> Void
    private let onPopoverDidClose: @MainActor () -> Void

    /// Held alongside the popover so the delegate stays alive — the
    /// popover's `delegate` is `weak`. Lifted shared adapter from
    /// `StatusItemController.swift` (per D17 + SPEC §20.6).
    private var popoverDelegate: PopoverDelegateAdapter?

    // MARK: - Init

    init(
        graph: PortGraph,
        onOpenWindow: @escaping @MainActor () -> Void,
        onPopoverDidShow: @escaping @MainActor () -> Void = {},
        onPopoverDidClose: @escaping @MainActor () -> Void = {}
    ) {
        self.graph = graph
        self.onOpenWindow = onOpenWindow
        self.onPopoverDidShow = onPopoverDidShow
        self.onPopoverDidClose = onPopoverDidClose
    }

    // MARK: - Install / uninstall

    /// Install the secondary status item. Idempotent — calling on an
    /// already-installed controller is a no-op.
    ///
    /// AppDelegate gates this on (a) the app-start probe of
    /// `BatterySnapshotReader.currentSnapshot()` returning non-nil
    /// AND (b) the `menubarBatteryItemVisible` AppStorage value.
    /// Desktop Macs (no `AppleSmartBattery` service) skip step (a)
    /// and never call this.
    func install() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(
            withLength: AppConstants.batteryStatusItemLength
        )
        guard let button = item.button else {
            // Headless test runs land here. Safe no-op.
            return
        }

        button.image = makeBaseIcon(percent: 50, isCharging: false)
        button.imagePosition = .imageOnly
        button.imageHugsTitle = true
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.setAccessibilityIdentifier("menubar.battery.statusItem")
        button.setAccessibilityLabel(
            NSLocalizedString(
                AppConstants.menuBarBatteryIconAccessibilityKey,
                comment: ""
            )
        )

        statusItem = item
        Log.app.info("Battery NSStatusItem installed.")

        // Apply the latest known battery snapshot so the glyph + %
        // are correct immediately — without waiting for the next
        // sampler tick.
        if let battery = graph.battery {
            setBattery(battery)
        }
    }

    /// Remove the status item + tear down the popover. Idempotent.
    /// Used by AppDelegate's live-toggle observer when the user flips
    /// `menubarBatteryItemVisible` to false.
    func uninstall() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        popover?.performClose(nil)
        popover = nil
        popoverDelegate = nil
        Log.app.info("Battery NSStatusItem uninstalled.")
    }

    // MARK: - Battery update

    /// Update the glyph + percent. Called by AppDelegate's sampler
    /// callback bridge each tick. Nil → fall back to the seed icon
    /// (sampler hasn't reported yet, or hardware reported a transient
    /// nil — keep the slot looking sensible).
    func setBattery(_ info: BatteryInfo?) {
        guard let button = statusItem?.button else { return }

        guard let info else {
            button.image = makeBaseIcon(percent: 50, isCharging: false)
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString()
            return
        }

        // Glyph: SF Symbol family chosen by the rounded bucket; the
        // `.bolt` variant overlays a charging arrow when the state
        // says so.
        button.image = makeBaseIcon(
            percent: info.chargePercent,
            isCharging: info.chargeState == .charging
        )

        // Title: percent attributedString, leading space mirrors the
        // primary's badge pattern from §13.1.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuBarFont(ofSize: 0).withWeightApplied(.semibold),
            .foregroundColor: NSColor.labelColor
        ]
        button.attributedTitle = NSAttributedString(
            string: " \(info.chargePercent)%",
            attributes: attrs
        )
        button.imagePosition = .imageLeft

        // VoiceOver summary — formatted on every update so the
        // assistive readout matches what's on screen.
        button.setAccessibilityLabel(accessibilitySummary(for: info))
    }

    // MARK: - Click handling

    @objc
    private func buttonClicked(_ sender: Any?) {
        showPopover()
    }

    /// Open / close the battery popover.
    func showPopover() {
        let popover = popoverIfNeeded()
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        configurePopoverWindowForFullscreenOverlay()
    }

    /// Lifts the popover's underlying NSWindow to a level + collection
    /// behaviour that lets it draw over fullscreen apps. Mirrors the
    /// same trick `StatusItemController` uses.
    private func configurePopoverWindowForFullscreenOverlay() {
        guard let window = popover?.contentViewController?.view.window else {
            return
        }
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        window.level = .popUpMenu
    }

    private func popoverIfNeeded() -> NSPopover {
        if let existing = popover { return existing }
        let popover = BatteryPopoverHostingView.makePopover(
            graph: graph,
            onOpenWindow: onOpenWindow
        )
        let delegate = PopoverDelegateAdapter(
            onShow: onPopoverDidShow,
            onClose: onPopoverDidClose
        )
        popover.delegate = delegate
        self.popoverDelegate = delegate
        self.popover = popover
        return popover
    }

    // MARK: - Glyph

    /// Pick the right SF Symbol from the `battery.{0,25,50,75,100}`
    /// family by the rounded charge bucket, swapping in the `.bolt`
    /// variant when charging.
    private func makeBaseIcon(percent: Int, isCharging: Bool) -> NSImage? {
        let bucket = roundedBucket(for: percent)
        let suffix = isCharging ? ".bolt" : ""
        let symbolName = "battery.\(bucket)\(suffix)"
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: NSLocalizedString(
                AppConstants.menuBarBatteryIconAccessibilityKey,
                comment: ""
            )
        )
        image?.isTemplate = true
        return image
    }

    /// Map a percent to the nearest battery-icon bucket. Matches the
    /// thresholds Apple's own battery menu bar item uses.
    private func roundedBucket(for percent: Int) -> Int {
        switch percent {
        case ..<BatteryStatusItemControllerConstants.bucket25Threshold:    return 0
        case ..<BatteryStatusItemControllerConstants.bucket50Threshold:    return 25
        case ..<BatteryStatusItemControllerConstants.bucket75Threshold:    return 50
        case ..<BatteryStatusItemControllerConstants.bucket100Threshold:   return 75
        default:                                                            return 100
        }
    }

    // MARK: - Accessibility summary

    /// Compose a "Battery 84%, charging, fully charged in 1 hour 24
    /// minutes"-style summary using `DateComponentsFormatter` for the
    /// time portion + the localized format key `menubar.battery.accessibility.format`.
    ///
    /// Format key takes:
    ///   1$@  percent string ("84%")
    ///   2$@  state string  ("charging" / "on battery" / "plugged in")
    ///   3$@  time string   ("fully charged in 1 hour 24 minutes" /
    ///                       "3 hours 15 minutes remaining" / "")
    private func accessibilitySummary(for info: BatteryInfo) -> String {
        let percent = "\(info.chargePercent)%"
        let stateString = NSLocalizedString(info.chargeState.labelKey, comment: "")
        let timeString = composeTimeString(for: info)
        let format = NSLocalizedString(
            "menubar.battery.accessibility.format",
            comment: "Battery menu bar VoiceOver summary."
        )
        return String.localizedStringWithFormat(format, percent, stateString, timeString)
    }

    private func composeTimeString(for info: BatteryInfo) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .full
        let secondsPerMinute = BatteryStatusItemControllerConstants.secondsPerMinute
        switch info.chargeState {
        case .charging:
            if let minutes = info.timeUntilFullMinutes,
               let formatted = formatter.string(from: TimeInterval(minutes * secondsPerMinute)) {
                return String.localizedStringWithFormat(
                    NSLocalizedString("window.battery.timeUntilFull", comment: ""),
                    formatted
                )
            }
        case .discharging:
            if let minutes = info.timeUntilEmptyMinutes,
               let formatted = formatter.string(from: TimeInterval(minutes * secondsPerMinute)) {
                return String.localizedStringWithFormat(
                    NSLocalizedString("window.battery.timeUntilEmpty", comment: ""),
                    formatted
                )
            }
        case .fullyCharged:
            return NSLocalizedString("window.battery.fullyCharged", comment: "")
        case .notCharging, .unknown:
            break
        }
        return ""
    }
}

// MARK: - Constants

enum BatteryStatusItemControllerConstants {
    /// Boundaries between the SF Symbol `battery.{0/.25/.50/.75/.100}`
    /// buckets. A charge of 12% → bucket 0; 38% → bucket 25; 62% →
    /// bucket 50; 88% → bucket 75; 95% → bucket 100. Matches the
    /// thresholds Apple's own menu-bar battery icon uses, +/- a couple
    /// of percent (Apple's exact thresholds aren't published; observed).
    static let bucket25Threshold: Int = 13
    static let bucket50Threshold: Int = 38
    static let bucket75Threshold: Int = 63
    static let bucket100Threshold: Int = 88

    /// 1 minute → 60 seconds for `DateComponentsFormatter`.
    static let secondsPerMinute: Int = 60
}
