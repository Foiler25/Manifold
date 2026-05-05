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
            enqueue(pending)
            return
        }
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
        guard let anchor = NotchAnchor.resolve() else { return }

        let canvasSize = canvasSize(for: anchor)
        let frame = panelFrame(for: anchor, canvasSize: canvasSize)

        let panel = NotchPanel(contentRect: frame)
        let root = NotchPanelRoot(
            viewModel: viewModel,
            anchor: anchor,
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
        // animates from scratch.
        viewModel.shapeProgress = 0
        viewModel.contentOpacity = 0

        // Order in with alpha 0 → 1 via NSAnimationContext.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NotchPanelControllerConstants.panelAlphaDuration
            panel.animator().alphaValue = 1.0
        }

        // Drive shape open + delayed content fade-in via SwiftUI
        // animations on the view model. The open spring + the
        // .easeOut(.delay) read directly off SPEC §21.4.
        withAnimation(NotchPanelControllerConstants.openSpring) {
            viewModel.shapeProgress = 1
        }
        withAnimation(
            NotchPanelControllerConstants.contentFadeIn
                .delay(NotchPanelControllerConstants.contentFadeDelay)
        ) {
            viewModel.contentOpacity = 1
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

        // Close spring + content fade-out.
        withAnimation(NotchPanelControllerConstants.closeSpring) {
            viewModel.shapeProgress = 0
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

    /// Canvas size in points. Width is the content width (340pt) plus
    /// the side padding budget — the dropdown is wider than the notch
    /// to host the title + subtitle. Height is fixed at the alert
    /// height; the spring drives `progress` 0→1 to interpolate.
    private func canvasSize(for anchor: NotchAnchor) -> CGSize {
        let width = NotchPanelControllerConstants.panelWidth
        let height = NotchPanelControllerConstants.panelHeight
        // For non-notched fallback, the panel still wants the same
        // canvas size — the shape just fills it without a notch
        // silhouette. For the notched case, ensure the canvas is at
        // least as wide as the physical notch + a margin.
        let minWidth = anchor.notchFrame.width + NotchPanelControllerConstants.minimumNotchMargin * 2
        return CGSize(width: max(width, minWidth), height: height)
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
            // Top edge flush with screen top — the notch silhouette
            // inside fills in the upper area.
            topY = screenFrame.maxY - canvasSize.height
        } else {
            // 6pt below visibleFrame top so the menu bar doesn't
            // overlap the panel content (per SPEC §21.12).
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
    /// 0 = closed pill, 1 = full dropdown. Animated by the open /
    /// close springs.
    var shapeProgress: CGFloat = 0
    /// Inner content opacity. Driven by the delayed easeOut so the
    /// content fades in AFTER the shape opens.
    var contentOpacity: CGFloat = 0
}

// MARK: - Root SwiftUI view

/// SwiftUI root injected into `NSHostingController`. Bridges the
/// `NotchPanelViewModel` into `NotchHostView` and threads the path
/// provider into the click-through hit-testing.
struct NotchPanelRoot: View {

    @Bindable var viewModel: NotchPanelViewModel
    let anchor: NotchAnchor
    let canvasSize: CGSize
    let content: AnyView

    var body: some View {
        NotchHostView(
            notchWidth: anchor.hasNotch ? anchor.notchFrame.width : 0,
            notchHeight: anchor.hasNotch ? anchor.notchFrame.height : 0,
            shapeProgress: viewModel.shapeProgress,
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

    /// Default panel canvas width in points. Wide enough for the
    /// 340pt content view with 18pt horizontal padding on each side
    /// + a margin so the shoulder curves have room to sweep out.
    static let panelWidth: CGFloat = 420

    /// Default panel canvas height in points. Fixed across alerts
    /// so the shape geometry stays consistent.
    static let panelHeight: CGFloat = 96

    /// Minimum side margin from the physical notch to the canvas
    /// edge. Ensures the shoulders have room to sweep out without
    /// cropping at the canvas edge.
    static let minimumNotchMargin: CGFloat = 24

    /// Fallback Y offset (no-notch path) — gap between the menu bar
    /// (visibleFrame top) and the panel's top edge. 6pt matches
    /// SPEC §21.12.
    static let fallbackTopOffset: CGFloat = 6
}
