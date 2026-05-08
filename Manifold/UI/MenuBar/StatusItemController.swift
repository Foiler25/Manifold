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
// StatusItemController.swift
//
// Owns the `NSStatusItem` and its lifecycle. Phase 4 extracts this
// from `AppDelegate` per SPEC.md §3 file tree, and adds the **numeric
// badge for connected device count** required by SPEC §18 Phase 4
// acceptance #1.
//
// Badge rendering: the SF Symbol icon stays as `button.image`
// (`isTemplate = true`, auto-tints with menu bar appearance); the
// count number is drawn as `button.attributedTitle` next to the icon
// (image-left, title-right). This is the same pattern macOS's built-in
// status items use (Bluetooth, Wi-Fi, etc.) — keeps the count legible
// at 16 pt.
//
// SPEC §13.1 says "Numeric badge: total connected device count,
// drawn as a NSAttributedString overlay" — flagged as deviation in
// BUILD_LOG: image-left/title-right interpreted as legible
// alternative to a true icon-overlay (which would be too small to
// read at menu-bar scale). Reviewer confirms.

import AppKit
import SwiftUI
import os
import ManifoldKit

@MainActor
final class StatusItemController {

    // MARK: - State

    /// Held strongly because `NSStatusBar` releases the slot the
    /// moment we drop the reference.
    private var statusItem: NSStatusItem?

    /// Lazily constructed on first popover open. Phase 0 deferred this
    /// to "first user click"; Phase 4 keeps the same pattern.
    private var popover: NSPopover?

    /// PortGraph reference held so `setDeviceCount` updates the badge
    /// AND so the popover content sees a live `@Observable` instance.
    private let graph: PortGraph

    /// Closures injected by AppDelegate so the popover toolbar's
    /// "open window" / "settings" buttons trigger AppKit-level
    /// activation without StatusItemController knowing about
    /// `NSApplication`. Phase 5 adds `onPopoverDidShow` /
    /// `onPopoverDidClose` so AppDelegate can drive `SamplerLifecycle`
    /// per SPEC §18 Phase 5 acceptance #3.
    private let onOpenWindow: @MainActor () -> Void
    private let onOpenSettings: @MainActor () -> Void
    private let onPopoverDidShow: @MainActor () -> Void
    private let onPopoverDidClose: @MainActor () -> Void

    /// Inner delegate so StatusItemController can forward NSPopover
    /// callbacks without itself conforming to NSPopoverDelegate (which
    /// would force `@MainActor` interop with `NSObjectProtocol`).
    private var popoverDelegate: PopoverDelegateAdapter?

    /// Global click-outside monitor token. NSPopover's `.transient`
    /// behavior auto-installs a click-outside watcher, but elevating
    /// the popover's host window to `.popUpMenu` level (which we do
    /// in `configurePopoverWindowForFullscreenOverlay()` so the
    /// popover floats over fullscreen apps) defeats that watcher —
    /// clicks outside the popover go to the underlying app instead
    /// of closing us. We re-add a manual watcher so click-to-dismiss
    /// survives the level elevation.
    private var clickOutsideMonitor: Any?

    /// Last device count applied via `setDeviceCount(_:)`. Skips the
    /// `NSAttributedString` re-allocation when the value hasn't
    /// changed.
    private var lastAppliedDeviceCount: Int?

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

    // MARK: - Install

    /// Build the `NSStatusItem`, install the SF-Symbol icon, wire the
    /// click handler. Call once from `applicationDidFinishLaunching`.
    func install() {
        let item = NSStatusBar.system.statusItem(withLength: AppConstants.statusItemLength)

        guard let button = item.button else {
            // Headless test runs land here. Safe no-op.
            return
        }

        button.image = makeBaseIcon()
        button.imagePosition = .imageOnly
        button.imageHugsTitle = true
        button.target = self
        button.action = #selector(buttonClicked(_:))

        statusItem = item
        Log.app.info("NSStatusItem installed.")
    }

    /// Update the badge to reflect `count` total connected devices.
    /// Called from AppDelegate whenever PortGraph changes (every
    /// successful walk + apply). count == 0 → image-only; count > 0 →
    /// image-left, attributedTitle-right.
    func setDeviceCount(_ count: Int) {
        guard let button = statusItem?.button else { return }
        if count == lastAppliedDeviceCount { return }
        lastAppliedDeviceCount = count

        if count == 0 {
            button.attributedTitle = NSAttributedString()
            button.imagePosition = .imageOnly
            return
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuBarFont(ofSize: 0).withWeightApplied(.semibold),
            .foregroundColor: NSColor.labelColor
        ]
        // Leading space gives a small gap between the icon and the
        // number — the system's `imageHugsTitle` brings them flush
        // otherwise, which reads as a single run.
        button.attributedTitle = NSAttributedString(string: " \(count)", attributes: attrs)
        button.imagePosition = .imageLeft
    }

    // MARK: - Click handling

    /// AppKit invokes this via target/action. `nonisolated` +
    /// `MainActor.assumeIsolated` skips Swift 6's `_checkExpectedExecutor`
    /// thunk, which has a runtime bug that occasionally reads a
    /// corrupted `SerialExecutorRef` and crashes inside
    /// `swift_getObjectType` while deciding "is this MainActor".
    /// Target/action dispatch is documented to run on the main thread,
    /// so `assumeIsolated` is sound.
    @objc
    nonisolated private func buttonClicked(_ sender: Any?) {
        MainActor.assumeIsolated {
            showPopover()
        }
    }

    /// Open the popover programmatically. Used by `buttonClicked` and
    /// (DEBUG-only) by `AppDelegate`'s `MANIFOLD_AUTOOPEN_POPOVER`
    /// env-var hook so `PopoverUITests` can drive the popover without
    /// menu-bar coordinate clicking. Idempotent — no-op if already
    /// shown, performs close if already open.
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

    /// Remove the global click-watcher. Called from the popover's
    /// `popoverDidClose` bridge so the watcher's lifetime mirrors
    /// the popover's visible state — keeps idle CPU at zero when
    /// the popover is hidden.
    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    /// Lifts the popover's underlying NSWindow to a level + collection
    /// behaviour that lets it draw over fullscreen apps. NSPopover's
    /// default window is normal-level and tied to its parent's space,
    /// so a popover triggered while another app is in fullscreen
    /// otherwise drops behind the fullscreen Space and looks broken.
    /// Must run after `popover.show(...)` — the hosting window is
    /// created lazily as part of that call.
    private func configurePopoverWindowForFullscreenOverlay() {
        guard let window = popover?.contentViewController?.view.window else {
            return
        }
        // `.canJoinAllSpaces` puts the window on every Space at once
        // (including the active fullscreen Space). `.fullScreenAuxiliary`
        // marks it as an overlay that's allowed to draw over a
        // fullscreen app's window without forcing the app out of
        // fullscreen. `.popUpMenu` is the standard menu-bar transient
        // level — same one NSMenu uses, so the popover floats over
        // fullscreen content but still hides under modal alerts.
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        window.level = .popUpMenu
    }

    private func popoverIfNeeded() -> NSPopover {
        if let existing = popover { return existing }
        let popover = PopoverHostingView.makePopover(
            graph: graph,
            onOpenWindow: onOpenWindow,
            onOpenSettings: onOpenSettings
        )
        // Wire the popover delegate so SamplerLifecycle hears about
        // popover open/close and can pause/resume the sampler.
        // Phase 18: delegate adapter lifted to
        // `Manifold/UI/MenuBar/PopoverDelegateAdapter.swift` so
        // `BatteryStatusItemController` can reuse the same shape (per
        // D17 + SPEC §20.6).
        // Wrap `onPopoverDidClose` so the click-outside monitor is
        // torn down whenever the popover hides — including the
        // user's outside-click path AND the AppDelegate-driven
        // sampler-lifecycle path. Avoids leaking the global monitor.
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

    // MARK: - Icon construction

    /// Build the SF Symbol icon used as the status-item glyph. Phase
    /// 0's bolt placeholder; Phase 15 swaps in the custom
    /// `MenuBarIcon.symbolset` brand mark.
    private func makeBaseIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: AppConstants.menuBarIconSymbolName,
            accessibilityDescription: NSLocalizedString(
                "menubar.icon.accessibility",
                comment: "Spoken description of the Manifold menu bar icon."
            )
        )
        image?.isTemplate = true
        return image
    }
}

// (NSFont.withWeightApplied helper lives in PopoverDelegateAdapter.swift
// so both StatusItemController and BatteryStatusItemController can use
// it without re-declaring the same fileprivate extension.)
