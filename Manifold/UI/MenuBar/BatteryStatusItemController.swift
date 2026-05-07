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
    /// button activates the app + brings the window forward; the
    /// gear button deep-links into Settings on the Menu Bar pane.
    private let onOpenWindow: @MainActor () -> Void
    private let onOpenSettings: @MainActor () -> Void
    private let onPopoverDidShow: @MainActor () -> Void
    private let onPopoverDidClose: @MainActor () -> Void

    /// Held alongside the popover so the delegate stays alive — the
    /// popover's `delegate` is `weak`. Lifted shared adapter from
    /// `StatusItemController.swift` (per D17 + SPEC §20.6).
    private var popoverDelegate: PopoverDelegateAdapter?

    /// Global click-outside monitor token. NSPopover's `.transient`
    /// behavior auto-installs a click-outside watcher, but elevating
    /// the popover's host window to `.popUpMenu` level (which we do in
    /// `configurePopoverWindowForFullscreenOverlay()` so the popover
    /// floats over fullscreen apps) defeats that watcher — clicks
    /// outside the popover go to the underlying app instead of closing
    /// us. We re-add a manual watcher so the click-to-dismiss UX
    /// survives the level elevation.
    private var clickOutsideMonitor: Any?

    // MARK: - Init

    init(
        graph: PortGraph,
        onOpenWindow: @escaping @MainActor () -> Void,
        onOpenSettings: @escaping @MainActor () -> Void,
        onPopoverDidShow: @escaping @MainActor () -> Void = {},
        onPopoverDidClose: @escaping @MainActor () -> Void = {}
    ) {
        self.graph = graph
        self.onOpenWindow = onOpenWindow
        self.onOpenSettings = onOpenSettings
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

        button.image = makeBatteryIcon(percent: 50, charging: false)
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
        removeClickOutsideMonitor()
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
            button.image = makeBatteryIcon(percent: 0, charging: false)
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString()
            return
        }

        // One image, no separate text label. The percentage lives
        // inside the battery body so the slot stays a single compact
        // icon at the menu bar scale. When charging, a small bolt
        // glyph appears to the left of the percentage so the slot
        // visually conveys "this is charging right now."
        button.image = makeBatteryIcon(
            percent: info.chargePercent,
            charging: info.chargeState == .charging
        )
        button.imagePosition = .imageOnly
        button.attributedTitle = NSAttributedString()

        // VoiceOver summary — formatted on every update so the
        // assistive readout matches what's on screen even though the
        // visible glyph is a single tight icon.
        button.setAccessibilityLabel(accessibilitySummary(for: info))
    }

    // MARK: - Click handling

    /// AppKit invokes this via target/action. Marked `nonisolated` to
    /// suppress Swift 6's auto-inserted `_checkExpectedExecutor` thunk
    /// — that thunk reads a corrupted `SerialExecutorRef` under some
    /// build configurations and crashes inside `swift_getObjectType`
    /// on the way to deciding "is this MainActor". We *know* AppKit
    /// dispatches target/action on the main thread, so `MainActor.
    /// assumeIsolated` is the documented way to tell the compiler /
    /// runtime "yes, we're on MainActor — skip the check".
    @objc
    nonisolated private func buttonClicked(_ sender: Any?) {
        MainActor.assumeIsolated {
            showPopover()
        }
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
        installClickOutsideMonitor()
    }

    /// Add a global click-watcher that closes the popover when the
    /// user clicks anywhere outside it. Compensates for NSPopover's
    /// own transient watcher being defeated by the elevated window
    /// level. Idempotent — re-installing is a no-op.
    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.popover?.performClose(nil)
            }
        }
    }

    /// Remove the global click-watcher. Called from
    /// `popoverDidClose`-bridge so the watcher's lifetime mirrors the
    /// popover's visible state — keeps idle CPU at zero when the
    /// popover is hidden.
    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
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
            onOpenWindow: onOpenWindow,
            onOpenSettings: onOpenSettings
        )
        // Wrap `onPopoverDidClose` so the click-outside monitor is
        // torn down whenever the popover hides — including the
        // user's outside-click path AND the AppDelegate-driven
        // sampler-lifecycle path. Avoids leaking the global monitor
        // when the popover is dismissed any way other than re-clicking
        // the status item button.
        let onClose = onPopoverDidClose
        let delegate = PopoverDelegateAdapter(
            onShow: onPopoverDidShow,
            onClose: { [weak self] in
                Task { @MainActor in
                    self?.removeClickOutsideMonitor()
                }
                onClose()
            }
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
    /// When `charging == true`, a small `bolt.fill` SF Symbol is
    /// drawn to the left of the percentage text — both centered as
    /// a unit inside the body. The bolt visually communicates "this
    /// is charging right now" without losing the percentage readout.
    /// Discharging / fully-charged states omit the bolt and center
    /// just the percentage.
    ///
    /// At `percent >= 100` the body fills with an `∞` glyph instead
    /// of the digits-plus-bolt unit. "100" + a bolt is the most
    /// cramped state the icon ever gets into (three digits leave
    /// almost no room for the bolt), and "fully charged" reads
    /// naturally as "infinite battery left" — single tall glyph,
    /// instantly recognisable at menu-bar scale.
    private func makeBatteryIcon(percent: Int, charging: Bool) -> NSImage {
        let width = BatteryStatusItemControllerConstants.iconWidth
        let height = BatteryStatusItemControllerConstants.iconHeight
        let bodyWidth = BatteryStatusItemControllerConstants.iconBodyWidth
        let nubWidth = BatteryStatusItemControllerConstants.iconNubWidth
        let nubHeight = BatteryStatusItemControllerConstants.iconNubHeight
        let stroke = BatteryStatusItemControllerConstants.iconStrokeWidth
        let cornerRadius = BatteryStatusItemControllerConstants.iconCornerRadius
        let nubCornerRadius = BatteryStatusItemControllerConstants.iconNubCornerRadius
        let fontSize = BatteryStatusItemControllerConstants.iconTextFontSize
        let infinityFontSize = BatteryStatusItemControllerConstants.iconInfinityFontSize
        let boltGap = BatteryStatusItemControllerConstants.iconChargingBoltGap

        // At full charge the body shows just an `∞` — no digits, no
        // bolt. Captured up-front so the drawing block below can
        // branch on a single boolean.
        let isFull = percent >= 100

        // Pre-render the bolt symbol outside the drawing block so we
        // can measure its size for the centered layout below. Skipped
        // entirely when full — the infinity glyph subsumes both
        // "what's the level?" and "is this plugged in?" signals.
        let boltImage: NSImage? = (charging && !isFull) ? Self.chargingBoltImage(at: fontSize) : nil
        let boltSize = boltImage?.size ?? .zero

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

            // Full-charge path: render `∞` centered in the body and
            // bail out before the digits + bolt layout below.
            //
            // Visual centering quirk: `NSString.size(withAttributes:)`
            // returns the typographic bounding box (ascender +
            // descender), and `draw(in:)` aligns the baseline at
            // `rect.y + descent`. For a digit pair like "100" that
            // produces a visually-centered glyph, but the `∞`
            // character is drawn around its **xHeight** midline, not
            // its cap-height midline — symmetric symbols sit lower
            // than the rect-center math expects. Nudging the rect up
            // by `iconInfinityYOffset` aligns the glyph's visual
            // midline with `bodyRect.midY`.
            if isFull {
                let inf = "∞" as NSString
                let infAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.menuBarFont(ofSize: infinityFontSize).withWeightApplied(.bold),
                    .foregroundColor: NSColor.black
                ]
                let infSize = inf.size(withAttributes: infAttrs)
                let yOffset = BatteryStatusItemControllerConstants.iconInfinityYOffset
                let infRect = NSRect(
                    x: bodyRect.midX - infSize.width / 2,
                    y: bodyRect.midY - infSize.height / 2 + yOffset,
                    width: infSize.width,
                    height: infSize.height
                )
                inf.draw(in: infRect, withAttributes: infAttrs)
                return true
            }

            // Percentage text + (optional) charging bolt, centered as
            // one unit inside the body. Without the bolt we just
            // center the digits as before; with the bolt the unit
            // width grows by `boltSize.width + boltGap` and we offset
            // the start-x so the combined glyph stays centered.
            //
            // The bolt SF Symbol's `.size` includes a small amount of
            // transparent left/right padding inside the image — the
            // visible bolt sits a pixel or two in from the bounds.
            // Pure mathematical centering gives equal *math* padding
            // on each side, but the visible left gap looks larger
            // than the visible right gap because of that internal
            // whitespace. Shifting the centered unit slightly left by
            // `iconTextTrailingInset` adds matching visible padding
            // to the right of the digits.
            let text = "\(percent)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.menuBarFont(ofSize: fontSize).withWeightApplied(.bold),
                .foregroundColor: NSColor.black
            ]
            let textSize = text.size(withAttributes: attrs)
            let totalWidth: CGFloat = boltImage == nil
                ? textSize.width
                : boltSize.width + boltGap + textSize.width
            let trailingInset = boltImage == nil
                ? 0
                : BatteryStatusItemControllerConstants.iconTextTrailingInset
            let startX = bodyRect.midX - totalWidth / 2 - trailingInset / 2

            if let boltImage {
                let boltRect = NSRect(
                    x: startX,
                    y: bodyRect.midY - boltSize.height / 2,
                    width: boltSize.width,
                    height: boltSize.height
                )
                boltImage.draw(
                    in: boltRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0
                )
            }

            let textX: CGFloat = boltImage == nil
                ? startX
                : startX + boltSize.width + boltGap
            let textRect = NSRect(
                x: textX,
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

    /// Pre-rendered `bolt.fill` SF Symbol used as the charging
    /// indicator inside the icon body. SF Symbols return template
    /// images by default — drawn into a flipped:false NSImage they
    /// keep their alpha mask, which is what we want for menu bar
    /// tint inheritance. Static so the symbol-config render only
    /// happens once per icon size, not per icon redraw.
    private static func chargingBoltImage(at fontSize: CGFloat) -> NSImage? {
        let symbolConfig = NSImage.SymbolConfiguration(
            pointSize: fontSize,
            weight: .heavy
        )
        guard let bolt = NSImage(
            systemSymbolName: "bolt.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(symbolConfig) else {
            return nil
        }
        bolt.isTemplate = true
        return bolt
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
    /// Bumped from 28 → 34 alongside the height increase so the
    /// extra vertical room doesn't make the icon read as squat.
    static let iconWidth: CGFloat = 34

    /// Total drawn-image height in points. The standard macOS menu
    /// bar slot is ~22pt tall — this leaves a ~3pt margin top and
    /// bottom while making the digits inside the body comfortable
    /// to read at typical viewing distance.
    static let iconHeight: CGFloat = 17

    /// Width of the rounded-rectangle "body" portion (the inset of
    /// `iconWidth` reserved for the percentage text). Remaining width
    /// is the terminal nub.
    static let iconBodyWidth: CGFloat = 31

    /// Width of the right-side terminal nub.
    static let iconNubWidth: CGFloat = 3

    /// Height of the right-side terminal nub. ~half the body height —
    /// matches the proportions of the SF Symbol battery family.
    static let iconNubHeight: CGFloat = 8

    /// Stroke width of the body outline.
    static let iconStrokeWidth: CGFloat = 1.2

    /// Corner radius of the rounded-rectangle body outline.
    static let iconCornerRadius: CGFloat = 3

    /// Corner radius of the terminal nub.
    static let iconNubCornerRadius: CGFloat = 1.5

    /// Point size of the percentage text drawn inside the body. Sized
    /// so "100" fits within the body interior with breathing room on
    /// either side.
    static let iconTextFontSize: CGFloat = 11

    /// Point size of the `∞` glyph drawn inside the body when the
    /// battery is fully charged. Bumped above the digits' size so
    /// the single-character glyph fills the body proportionally —
    /// "∞" at 11 pt looks visually undersized next to a digit-pair
    /// rendering at the same size.
    static let iconInfinityFontSize: CGFloat = 14

    /// Vertical nudge (points) applied to the `∞` glyph's drawing
    /// rect at full charge. Pure rect-based centering aligns the
    /// glyph's typographic bounding box, which is anchored on the
    /// font's baseline + descender — but `∞` is drawn symmetrically
    /// around its **xHeight** midline (lower than the cap-height
    /// midline that digit-pair rendering implicitly targets), so the
    /// glyph appears too low. Nudging the rect up brings the visual
    /// midline back to `bodyRect.midY`. Tuned by inspection at the
    /// menu-bar size.
    static let iconInfinityYOffset: CGFloat = 1

    /// Horizontal gap between the charging bolt and the percentage
    /// text. Tuned so the two glyphs read as a single "this is
    /// charging" unit at menu-bar scale, neither cramped together
    /// nor floating apart.
    static let iconChargingBoltGap: CGFloat = 1

    /// Trailing inset added to the right of the percentage when the
    /// charging bolt is shown — compensates for the SF Symbol bolt's
    /// built-in transparent padding inside its image bounds, so the
    /// visible left gap (bolt → body edge) and the visible right gap
    /// (digits → body edge) read as the same width.
    static let iconTextTrailingInset: CGFloat = 2

    /// 1 minute → 60 seconds for `DateComponentsFormatter`.
    static let secondsPerMinute: Int = 60
}
