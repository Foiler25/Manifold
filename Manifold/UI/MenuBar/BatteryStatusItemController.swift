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
// Glyph: a custom-drawn template image — battery body outline +
// terminal nub + the percentage rendered centered inside the body.
// One simple icon, no separate text label. Charge state is surfaced
// in the popover (pill + subtitle), not in the menu bar slot, per
// Brandon's UX feedback (2026-05-04).
//
// Template-mode means a single tint that follows the menu bar's
// light/dark adaptation automatically. The accessibility summary is
// composed on every `setBattery(_:)` via `DateComponentsFormatter`
// + a localized format string — VoiceOver still reads "Battery 84%,
// charging, fully charged in 1 hour 24 minutes" even though the
// visible glyph just says "84".

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

        button.image = makeBatteryIcon(percent: 50)
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

    /// Update the glyph. Called by AppDelegate's sampler callback
    /// bridge each tick. Nil → fall back to a 0% seed icon (sampler
    /// hasn't reported yet, or hardware reported a transient nil —
    /// keep the slot looking sensible).
    func setBattery(_ info: BatteryInfo?) {
        guard let button = statusItem?.button else { return }

        guard let info else {
            button.image = makeBatteryIcon(percent: 0)
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString()
            return
        }

        // One image, no separate text label. The percentage lives
        // inside the battery body so the slot stays a single compact
        // icon at the menu bar scale.
        button.image = makeBatteryIcon(percent: info.chargePercent)
        button.imagePosition = .imageOnly
        button.attributedTitle = NSAttributedString()

        // VoiceOver summary — formatted on every update so the
        // assistive readout matches what's on screen even though the
        // visible glyph is a single tight icon.
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

    /// Render a custom template image: a battery body outline + small
    /// terminal nub on the right + the percentage drawn centered
    /// inside the body. Single-color (template) so the menu bar tint
    /// follows light/dark mode automatically.
    ///
    /// No internal fill bar, no charging overlay — the percentage
    /// itself communicates the level, and charge state is surfaced in
    /// the popover. Per Brandon's UX feedback (2026-05-04): "make it
    /// a simple icon."
    private func makeBatteryIcon(percent: Int) -> NSImage {
        let width = BatteryStatusItemControllerConstants.iconWidth
        let height = BatteryStatusItemControllerConstants.iconHeight
        let bodyWidth = BatteryStatusItemControllerConstants.iconBodyWidth
        let nubWidth = BatteryStatusItemControllerConstants.iconNubWidth
        let nubHeight = BatteryStatusItemControllerConstants.iconNubHeight
        let stroke = BatteryStatusItemControllerConstants.iconStrokeWidth
        let cornerRadius = BatteryStatusItemControllerConstants.iconCornerRadius
        let nubCornerRadius = BatteryStatusItemControllerConstants.iconNubCornerRadius
        let fontSize = BatteryStatusItemControllerConstants.iconTextFontSize

        let image = NSImage(
            size: NSSize(width: width, height: height),
            flipped: false
        ) { _ in
            // Battery body outline.
            let bodyRect = NSRect(
                x: stroke / 2,
                y: stroke / 2,
                width: bodyWidth - stroke,
                height: height - stroke
            )
            let bodyPath = NSBezierPath(
                roundedRect: bodyRect,
                xRadius: cornerRadius,
                yRadius: cornerRadius
            )
            bodyPath.lineWidth = stroke
            NSColor.black.setStroke()
            bodyPath.stroke()

            // Terminal nub on the right edge.
            let nubRect = NSRect(
                x: bodyWidth,
                y: (height - nubHeight) / 2,
                width: nubWidth,
                height: nubHeight
            )
            NSColor.black.setFill()
            NSBezierPath(
                roundedRect: nubRect,
                xRadius: nubCornerRadius,
                yRadius: nubCornerRadius
            ).fill()

            // Percentage text, centered in the body.
            let text = "\(percent)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.menuBarFont(ofSize: fontSize).withWeightApplied(.bold),
                .foregroundColor: NSColor.black
            ]
            let textSize = text.size(withAttributes: attrs)
            let textRect = NSRect(
                x: bodyRect.midX - textSize.width / 2,
                y: bodyRect.midY - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attrs)

            return true
        }
        // Template mode: AppKit retints the whole image to match menu
        // bar appearance (white in dark mode, black in light mode).
        // The `NSColor.black` calls above are placeholders — only the
        // alpha channel matters under template tinting.
        image.isTemplate = true
        image.accessibilityDescription = NSLocalizedString(
            AppConstants.menuBarBatteryIconAccessibilityKey,
            comment: ""
        )
        return image
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
    /// Total drawn-image width in points. Body width + nub width.
    /// Sized so the menu bar slot stays compact while leaving room for
    /// "100" inside the body without the digits crowding the outline.
    static let iconWidth: CGFloat = 28

    /// Total drawn-image height in points. Sized to read clearly in
    /// the standard menu bar slot (~22pt tall) without dominating it.
    static let iconHeight: CGFloat = 14

    /// Width of the rounded-rectangle "body" portion (the inset of
    /// `iconWidth` reserved for the percentage text). Remaining width
    /// is the terminal nub.
    static let iconBodyWidth: CGFloat = 26

    /// Width of the right-side terminal nub.
    static let iconNubWidth: CGFloat = 2

    /// Height of the right-side terminal nub. ~half the body height —
    /// matches the proportions of the SF Symbol battery family.
    static let iconNubHeight: CGFloat = 6

    /// Stroke width of the body outline.
    static let iconStrokeWidth: CGFloat = 1

    /// Corner radius of the rounded-rectangle body outline.
    static let iconCornerRadius: CGFloat = 2

    /// Corner radius of the terminal nub.
    static let iconNubCornerRadius: CGFloat = 1

    /// Point size of the percentage text drawn inside the body. Sized
    /// so "100" fits within the body interior with breathing room on
    /// either side.
    static let iconTextFontSize: CGFloat = 9

    /// 1 minute → 60 seconds for `DateComponentsFormatter`.
    static let secondsPerMinute: Int = 60
}
