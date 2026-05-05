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
// NotchPanelController.swift
//
// Phase 19 — owns the `NotchPanel` + `NSHostingController`, runs the
// open / close / dismiss animations, and serializes back-to-back
// alerts via a FIFO queue (max depth 3, drop-oldest on overflow).
// Animation curves verbatim per SPEC §21.4:
//
//   - Open spring     : .spring(response: 0.42, dampingFraction: 0.80)
//   - Close spring    : .spring(response: 0.50, dampingFraction: 0.85)
//   - Content fade-in : .easeOut(duration: 0.26).delay(0.14)
//   - Panel alpha     : 0 → 1 over 0.22s via NSAnimationContext
//
// Per Q23 / SPEC §21.4 the queue is FIFO with max depth 3; on
// overflow the **oldest** queued entry is dropped. The currently-
// visible alert is **never displaced** mid-animation.
//
// `dismiss()` is synchronous so `applicationWillTerminate` doesn't
// leave a half-open panel hanging during process teardown.

import AppKit
import SwiftUI
import os

@MainActor
final class NotchPanelController {

    // MARK: - State

    /// One queued / live alert. The queue holds these tuples; the
    /// live alert is consumed off the head of the queue when the
    /// previous alert auto-dismisses.
    private struct Pending {
        let content: AnyView
        let duration: TimeInterval
    }

    /// FIFO queue. Capacity enforced inside `enqueue(_:)`.
    private var queue: [Pending] = []

    /// `true` while the panel is mid-open or visible. Blocks new
    /// `show(_:)` calls from displacing the visible alert; new calls
    /// enqueue instead.
    private var isVisible: Bool = false

    /// In-flight auto-dismiss timer. Cancelled on `dismiss()` or on
    /// successive enqueue cycles (to prevent two timers racing).
    private var dismissTimer: Timer?

    /// Live SwiftUI animation parameters. The hosting controller
    /// re-binds these via a state object so changes drive the
    /// open / close springs without rebuilding the host view.
    private let viewModel: NotchPanelViewModel

    /// Current panel + host controller. Reconstructed for each
    /// alert so the resolved `NotchAnchor` (which can change between
    /// alerts when the user moves between screens) drives a fresh
    /// frame + path-provider.
    private var panel: NotchPanel?
    private var hostingController: NSHostingController<NotchPanelRoot>?

    // MARK: - Init

    init() {
        self.viewModel = NotchPanelViewModel()
    }

    // MARK: - Public API

    /// Show a piece of SwiftUI content for `duration` seconds. If a
    /// notch alert is currently visible, the new alert is enqueued
    /// per the FIFO depth-3 drop-oldest policy. The currently-visible
    /// alert is never displaced mid-animation.
    func show<Content: View>(content: Content, for duration: TimeInterval) {
        let pending = Pending(content: AnyView(content), duration: duration)
        if isVisible {
            Log.app.info("NotchPanelController — already visible, enqueueing (queue depth \(self.queue.count + 1, privacy: .public))")
            enqueue(pending)
            return
        }
        Log.app.info("NotchPanelController.show — presenting alert for \(duration, privacy: .public)s")
        present(pending)
    }

    /// Synchronously close the panel + clear the queue. Called from
    /// `applicationWillTerminate` so a half-open panel doesn't linger
    /// as the app exits. NOT animated — the goal is to drop the panel
    /// before the runloop tears down, not to be pretty.
    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        queue.removeAll()
        guard let panel else {
            isVisible = false
            return
        }
        panel.orderOut(nil)
        self.panel = nil
        hostingController = nil
        isVisible = false
    }

    // MARK: - Queue

    /// Append + enforce the depth-3 cap. Drop-oldest on overflow per
    /// SPEC §21.4 / Q23 — the **head** of the queue is the oldest
    /// and is the one we discard.
    private func enqueue(_ pending: Pending) {
        queue.append(pending)
        while queue.count > NotchPanelControllerConstants.maxQueueDepth {
            queue.removeFirst()
        }
    }

    // MARK: - Present

    /// Stand up the panel + hosting controller, animate open, schedule
    /// auto-dismiss after `pending.duration`.
    private func present(_ pending: Pending) {
        guard let anchor = NotchAnchor.resolve() else {
            Log.app.error("NotchPanelController.present — NotchAnchor.resolve() returned nil; alert dropped")
            return
        }
        Log.app.info("NotchPanelController.present — anchor hasNotch=\(anchor.hasNotch, privacy: .public), screen=\(anchor.screenFrame.debugDescription, privacy: .public), notchFrame=\(anchor.notchFrame.debugDescription, privacy: .public)")

        let canvasSize = canvasSize(for: anchor)
        let frame = panelFrame(for: anchor, canvasSize: canvasSize)
        let notchWidth = anchor.hasNotch ? anchor.notchFrame.width : canvasSize.width
        let notchHeight = anchor.hasNotch ? anchor.notchFrame.height : 0

        let panel = NotchPanel(contentRect: frame)
        let root = NotchPanelRoot(
            viewModel: viewModel,
            notchWidth: notchWidth,
            notchHeight: notchHeight,
            canvasSize: canvasSize,
            content: pending.content
        )
        let hosting = NSHostingController(rootView: root)
        hosting.view.frame = NSRect(origin: .zero, size: frame.size)
        panel.contentViewController = hosting
        panel.setFrame(frame, display: false)

        self.panel = panel
        self.hostingController = hosting
        self.isVisible = true

        // Reset the view model to a closed state so the open spring
        // animates from a thin pill matching the notch width.
        viewModel.isOpen = false
        viewModel.contentOpacity = 0

        // Set alpha directly. NSAnimationContext-driven fades on
        // freshly-ordered panels are unreliable; the SwiftUI frame
        // spring is what carries the perceived unfurl.
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        Log.app.info(
            "NotchPanelController.present — panel ordered front: isVisible=\(panel.isVisible, privacy: .public) alpha=\(panel.alphaValue, privacy: .public) frame=\(NSStringFromRect(panel.frame), privacy: .public) level=\(panel.level.rawValue, privacy: .public)"
        )

        // Defer the open animation to the next runloop tick so SwiftUI
        // observes the closed state (frame collapsed to notchWidth × 0)
        // before the spring kicks the frame up to full canvas. Without
        // the defer, both states fold into one transaction and the
        // animation pops instead of unfurling. The transaction also
        // avoids the Swift 6 strict-concurrency executor-check bug
        // we hit when forcing synchronous SwiftUI layout immediately
        // after orderFront (it cascaded into MainWindow's segmented
        // Picker and crashed).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            withAnimation(NotchPanelControllerConstants.openSpring) {
                self.viewModel.isOpen = true
            }
            withAnimation(
                NotchPanelControllerConstants.contentFadeIn
                    .delay(NotchPanelControllerConstants.contentFadeDelay)
            ) {
                self.viewModel.contentOpacity = 1
            }
        }

        // Schedule auto-dismiss.
        let timer = Timer.scheduledTimer(
            withTimeInterval: pending.duration,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAutoDismiss()
            }
        }
        dismissTimer = timer
    }

    // MARK: - Auto-dismiss

    /// Animate close, then either present the next queued entry
    /// (back-to-back per Q23) or fully tear down.
    private func handleAutoDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard let panel else {
            isVisible = false
            return
        }

        // Close spring + content fade-out. Setting isOpen = false
        // springs the frame back to the closed pill.
        withAnimation(NotchPanelControllerConstants.closeSpring) {
            viewModel.isOpen = false
        }
        withAnimation(.easeIn(duration: NotchPanelControllerConstants.contentFadeOutDuration)) {
            viewModel.contentOpacity = 0
        }

        // Wait for the close spring to mostly finish, then either
        // hand off to the next queued entry or order the panel out.
        let closeWindow = NotchPanelControllerConstants.closeWindow
        DispatchQueue.main.asyncAfter(deadline: .now() + closeWindow) { [weak self] in
            guard let self else { return }
            self.completeDismissTransition(panel: panel)
        }
    }

    /// Final teardown after the close spring window elapses. Hands
    /// off to the next queued alert if one exists; otherwise orders
    /// the panel out + clears references so the next `show` builds
    /// a fresh panel.
    private func completeDismissTransition(panel: NotchPanel) {
        if let next = queue.first {
            queue.removeFirst()
            // Tear down the current panel and present the next. Per
            // §21.4 the close-then-open runs back-to-back without an
            // inter-alert gap.
            panel.orderOut(nil)
            self.panel = nil
            self.hostingController = nil
            self.isVisible = false
            present(next)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = NotchPanelControllerConstants.panelAlphaDuration
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    panel.orderOut(nil)
                    self.panel = nil
                    self.hostingController = nil
                    self.isVisible = false
                }
            }
        }
    }

    // MARK: - Geometry

    /// Canvas size in points. Width = notch width + a margin on each
    /// side to host the content; the body inside the shape ends up
    /// `canvasWidth - 2 × shoulderRadius` wide. Height fixed at the
    /// alert height; the SwiftUI frame interpolation springs from
    /// `(notchWidth, 0)` to this size.
    private func canvasSize(for anchor: NotchAnchor) -> CGSize {
        let height = NotchPanelControllerConstants.panelHeight
        // Notched: canvas extends `notchExtension` past each side of
        // the physical notch so the body has breathing room past the
        // concave shoulders. Non-notched: fall back to a fixed width.
        let width: CGFloat
        if anchor.hasNotch {
            width = anchor.notchFrame.width
                + NotchPanelControllerConstants.notchExtension * 2
        } else {
            width = NotchPanelControllerConstants.panelWidth
        }
        return CGSize(width: width, height: height)
    }

    /// Position the panel frame in screen coordinates. Centered on
    /// the screen the cursor is on; vertical alignment depends on the
    /// notched / non-notched path.
    ///
    /// - Notched: panel's top edge at `screenFrame.maxY` so the notch
    ///   sits flush. The shape's `notchHeight` accounts for the
    ///   physical notch's vertical extent.
    /// - Non-notched (SPEC §21.12 fallback): panel positioned 6pt
    ///   below `visibleFrame.maxY` so the menu bar doesn't visually
    ///   overlap.
    private func panelFrame(for anchor: NotchAnchor, canvasSize: CGSize) -> NSRect {
        let screenFrame = anchor.screenFrame
        let centerX = screenFrame.midX - canvasSize.width / 2
        let topY: CGFloat
        if anchor.hasNotch {
            // Panel's TOP edge sits at the SCREEN TOP, so the canvas
            // extends behind the physical notch. The shape's top
            // corners (canvas (0,0) / (width,0)) land on the screen
            // top, slightly past each side of the notch — the area
            // between them at y=0 falls behind the notch (hardware-
            // masked, invisible). What the user sees is the canvas's
            // two outer "wings" poking out from the notch's left and
            // right shoulders, with the shape's concave corners
            // unfurling from there. This is the "blends into the
            // notch" look. NSScreen origin is bottom-left, so the
            // window's bottom-left is `screenTop - canvasHeight`.
            topY = anchor.notchFrame.maxY - canvasSize.height
        } else {
            // Non-notched fallback: position just below the menu bar.
            let visibleTop = (anchor.screen?.visibleFrame.maxY) ?? screenFrame.maxY
            topY = visibleTop
                - canvasSize.height
                - NotchPanelControllerConstants.fallbackTopOffset
        }
        return NSRect(
            x: centerX,
            y: topY,
            width: canvasSize.width,
            height: canvasSize.height
        )
    }
}

// MARK: - View model

/// Animation-driving view model for `NotchHostView`. Lives outside
/// the controller so the SwiftUI tree can `@Bindable` against it.
@MainActor
@Observable
final class NotchPanelViewModel {
    /// `false` = closed pill (frame matches the notch width × 0),
    /// `true` = full dropdown. Toggled inside `withAnimation(spring)`
    /// so the SwiftUI frame interpolation drives the unfurl.
    var isOpen: Bool = false
    /// Inner content opacity. Driven by the delayed easeOut so the
    /// content fades in AFTER the shape unfurls.
    var contentOpacity: CGFloat = 0
}

// MARK: - Root SwiftUI view

/// SwiftUI root injected into `NSHostingController`. Bridges the
/// `NotchPanelViewModel` into `NotchHostView`. The host view owns
/// the frame interpolation; this root just forwards the dimensions
/// and the bindable state.
struct NotchPanelRoot: View {

    @Bindable var viewModel: NotchPanelViewModel
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let canvasSize: CGSize
    let content: AnyView

    var body: some View {
        NotchHostView(
            notchWidth: notchWidth,
            notchHeight: notchHeight,
            isOpen: viewModel.isOpen,
            contentOpacity: viewModel.contentOpacity,
            canvasSize: canvasSize,
            content: content
        )
    }
}

// MARK: - Constants

enum NotchPanelControllerConstants {
    /// FIFO queue depth ceiling. Drop-oldest on overflow per Q23.
    static let maxQueueDepth: Int = 3

    /// Open spring — SPEC §21.4 verbatim.
    static let openSpring: Animation = .spring(response: 0.42, dampingFraction: 0.80)

    /// Close spring — SPEC §21.4 verbatim. Slightly slower than
    /// open per Phase 19 plan tuning.
    static let closeSpring: Animation = .spring(response: 0.50, dampingFraction: 0.85)

    /// Content fade-in — easeOut after the shape opens.
    static let contentFadeIn: Animation = .easeOut(duration: 0.26)

    /// Delay before content fade-in starts. Lets the shoulders
    /// unfurl visibly before the title appears.
    static let contentFadeDelay: Double = 0.14

    /// Content fade-out duration when closing. Slightly faster than
    /// fade-in so the title doesn't linger after the shape collapses.
    static let contentFadeOutDuration: Double = 0.18

    /// Panel-level alpha animation (NSAnimationContext) — 0 → 1 over
    /// this duration on open and 1 → 0 on close. Separate from the
    /// SwiftUI shape progress so the panel doesn't pop into existence
    /// with a hard edge.
    static let panelAlphaDuration: TimeInterval = 0.22

    /// Time we wait after kicking off the close spring before
    /// tearing down the panel or presenting the next queued alert.
    /// Slightly longer than the spring's natural settling time so
    /// the close completes visibly.
    static let closeWindow: TimeInterval = 0.42

    /// Fallback canvas width on non-notched displays (M1 Air,
    /// external monitor). On notched hardware the canvas width is
    /// derived from `notchFrame.width + 2 × notchExtension` so the
    /// dropdown unfurls symmetrically from the notch.
    static let panelWidth: CGFloat = 360

    /// Default panel canvas height in points. Sized to clear the
    /// physical notch (~38pt) PLUS a three-line content stack
    /// (title / subtitle / time-remaining caption) PLUS bottom
    /// padding. The visible body height (below the notch) is
    /// `panelHeight - notchHeight - paddings` — currently ~64pt
    /// for the three-line stack.
    static let panelHeight: CGFloat = 112

    /// Distance the canvas extends past each side of the physical
    /// notch on notched hardware. Wide enough to fit the icon, the
    /// title / subtitle / time-caption stack at full single-line
    /// width, AND the trailing percent label without anything
    /// truncating. With `notchWidth = 220pt`, this yields a 360pt
    /// canvas / 332pt body / ~316pt content area — ~190pt available
    /// for the text stack after the icon + spacer + percent budget.
    static let notchExtension: CGFloat = 70

    /// Fallback Y offset (no-notch path) — gap between the menu bar
    /// (visibleFrame top) and the panel's top edge. 6pt matches
    /// SPEC §21.12.
    static let fallbackTopOffset: CGFloat = 6
}
