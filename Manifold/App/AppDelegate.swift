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
// AppDelegate.swift
//
// Phase 4 trim-down: the menu bar / popover code moved to
// `StatusItemController` + `PopoverRoot` per SPEC.md §3 file tree.
// What's left here is app-lifecycle orchestration: own `EventService`,
// `DiscoveryService`, `PortGraph`; subscribe to events; drive
// `StatusItemController` (badge updates, toolbar actions).

import AppKit
import SwiftUI
import os
import ManifoldKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Services + model

    private let discoveryService = DiscoveryService()
    private var eventService: EventService?
    /// Phase 8: registers + runs the SPEC §9 diagnostic rules between
    /// each discovery walk and the `portGraph.replace` commit.
    private let diagnosticEngine = DiagnosticEngine()
    /// Phase 9: native notifications for connect/disconnect/diagnostic
    /// events. Receives each `PortEvent` BEFORE `portGraph.apply` so
    /// `.detached`'s device-name resolution sees the pre-apply graph.
    private let notificationService = NotificationService()

    /// `internal` (default) so `ManifoldApp.body` can pass the graph
    /// into `MainWindow`. The same instance is observed by the popover
    /// and the standalone window — single source of truth per
    /// SPEC §4.6.
    let portGraph = PortGraph()

    /// Public alias used by ManifoldApp; preserves the
    /// "private model, exposed via published accessor" pattern even
    /// though the underlying `portGraph` is internal-visible.
    var publishedPortGraph: PortGraph { portGraph }

    /// Phase 10: read-only accessors for the History view + Settings
    /// HistoryPane. nil when DatabaseManager init failed (silent
    /// disable path); the consumers render an empty-state.
    var publishedEventRepository: EventRepository? { eventRepository }
    var publishedDeviceRepository: DeviceRepository? { deviceRepository }
    var publishedSampleRepository: SampleRepository? { sampleRepository }
    var publishedDatabaseManager: DatabaseManager? { databaseManager }
    var publishedDownsamplingJob: DownsamplingJob? { downsamplingJob }

    private var statusItemController: StatusItemController?
    private var telemetrySampler: TelemetrySampler?
    private let samplerLifecycle = SamplerLifecycle()
    private var eventConsumerTask: Task<Void, Never>?
    private var graphObservationTask: Task<Void, Never>?

    // MARK: - Phase 10 Storage

    /// Lazily constructed in `applicationDidFinishLaunching` so a
    /// throwing init can fail-soft without crashing app launch.
    /// nil-after-failure means persistence is disabled for this run;
    /// every storage call site uses `if let` guards.
    private var databaseManager: DatabaseManager?
    private var deviceRepository: DeviceRepository?
    private var eventRepository: EventRepository?
    private var sampleRepository: SampleRepository?
    private var downsamplingJob: DownsamplingJob?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Window-frame persistence wired explicitly via AppKit per
        // SPEC §18 Phase 6 rev-6. WindowGroup may not have created
        // the window yet by the time applicationDidFinishLaunching
        // fires, so dispatch to the next run-loop tick — by then the
        // SwiftUI scene has instantiated the NSWindow and we can find
        // it in NSApp.windows.
        DispatchQueue.main.async { [weak self] in
            self?.installMainWindowFrameAutosaveName()
        }

        let controller = StatusItemController(
            graph: portGraph,
            onOpenWindow: { [weak self] in self?.openMainWindow() },
            onOpenSettings: { [weak self] in self?.openSettings() },
            onPopoverDidShow: { [weak self] in self?.samplerLifecycle.popoverDidOpen() },
            onPopoverDidClose: { [weak self] in self?.samplerLifecycle.popoverDidClose() }
        )
        controller.install()
        statusItemController = controller

        let service = EventService()
        eventService = service
        // Phase 10: open the GRDB store + spin up repositories. If
        // it throws, persistence is silently disabled (the app
        // still works in-memory); every storage call site below
        // is wrapped in `if let`.
        do {
            let manager = try DatabaseManager()
            databaseManager = manager
            deviceRepository = DeviceRepository(dbPool: manager.dbPool)
            let events = EventRepository(dbPool: manager.dbPool)
            let samples = SampleRepository(dbPool: manager.dbPool)
            eventRepository = events
            sampleRepository = samples
            let job = DownsamplingJob(sampleRepository: samples, eventRepository: events)
            job.start()
            downsamplingJob = job
        } catch {
            Log.app.error("DatabaseManager init failed; persistence disabled this run: \(String(describing: error), privacy: .public)")
        }
        startEventConsumer(service: service)
        startBadgeObserver(controller: controller)

        // Phase 5: telemetry sampler attached to the lifecycle. The
        // lifecycle starts/stops the sampler as popover (and Phase 6
        // window) surfaces appear/disappear; the sampler emits
        // .telemetry events via EventService.inject which flow into
        // PortGraph.apply via the same consumer task.
        let sampler = TelemetrySampler(eventService: service)
        telemetrySampler = sampler
        samplerLifecycle.attach(sampler: sampler)

        // Seed the initial walk through the same .fullRefresh path as
        // any subsequent refresh — keeps the consumer's behavior
        // uniform.
        service.requestRefresh()

        // Phase 9: prompt for notification authorization once per
        // install. Detached Task because requestAuthorization is
        // async and we don't want to block app launch on the user's
        // permission dialog response.
        Task { [notificationService] in
            await notificationService.requestAuthorizationIfNeeded()
        }

#if DEBUG
        runLeakBenchIfRequested()
        autoOpenPopoverIfRequested()
#endif
    }

#if DEBUG
    /// DEBUG-only hook for `PopoverUITests`: when launched with
    /// `MANIFOLD_AUTOOPEN_POPOVER=1`, programmatically open the
    /// popover on launch so the UI test can assert its contents
    /// without driving the menu bar status item via screen coordinates
    /// (brittle) or cross-app accessibility traversal (flaky in CI).
    /// Production builds elide this entirely.
    private func autoOpenPopoverIfRequested() {
        guard ProcessInfo.processInfo.environment["MANIFOLD_AUTOOPEN_POPOVER"] != nil else {
            return
        }
        // Defer to the next run-loop tick so the status item has had
        // a chance to install before we ask it to open.
        DispatchQueue.main.async { [weak self] in
            self?.statusItemController?.showPopover()
        }
    }
#endif

    func applicationWillTerminate(_ notification: Notification) {
        eventConsumerTask?.cancel()
        graphObservationTask?.cancel()
        samplerLifecycle.shutdown()
        eventService?.shutdown()
        downsamplingJob?.stop()
    }

    // MARK: - Event consumer

    /// MainActor `for await` loop. Hop to MainActor happens by virtue
    /// of the closure body running on AppDelegate's actor — satisfies
    /// SPEC §18 Phase 3 acceptance #7.
    private func startEventConsumer(service: EventService) {
        eventConsumerTask = Task { @MainActor [weak self] in
            for await event in service.events() {
                guard let self else { return }
                await self.handle(event: event)
            }
        }
    }

    private func handle(event: PortEvent) async {
        switch event {
        case .fullRefresh:
            await rebuildGraph()
        default:
            // Phase 9: notify BEFORE apply so `.detached` can still
            // resolve the device name from the pre-apply graph.
            notificationService.handle(event, graph: portGraph)
            // Phase 10: persist BEFORE apply for the same reason —
            // `.attached` needs the upsert order (device row first,
            // then event row referencing it via FK). Persistence is
            // fire-and-forget (Task) so the consumer keeps draining.
            persistEventIfPossible(event)
            portGraph.apply(event)
            if portGraph.needsFullRefresh {
                portGraph.acknowledgeRefreshRequest()
                await rebuildGraph()
            }
        }
    }

    /// Phase 10: write `.attached`/`.detached`/`.diagnostic` to GRDB
    /// (events table) and `.telemetry` to the samples table. Each
    /// kind no-ops if persistence is disabled (init-failure path).
    /// Spawned in detached `Task`s so the consumer task isn't
    /// blocked on disk I/O — losing one row across an unclean exit
    /// is acceptable.
    private func persistEventIfPossible(_ event: PortEvent) {
        switch event {
        case .attached(let device, let portID):
            // Upsert the device row first so the event row's FK
            // resolves. F10 reconcile lives in DeviceRepository.
            // Phase 11 F23 closure: snapshot the link protocol +
            // watts at MainActor while we still hold the live graph
            // reference, then thread them through to the persisted
            // payload via AttachedExtras.
            let extras = lookupAttachedExtras(forPortID: portID)
            if let devices = deviceRepository, let events = eventRepository {
                Task {
                    do {
                        try await devices.upsert(device)
                        try await events.write(event, attachedExtras: extras)
                    } catch {
                        Log.app.error("Persist .attached failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
        case .detached, .diagnostic:
            if let events = eventRepository {
                Task {
                    do { try await events.write(event) }
                    catch { Log.app.error("Persist event failed: \(String(describing: error), privacy: .public)") }
                }
            }
        case .telemetry(let portID, let sample):
            if let samples = sampleRepository {
                let deviceID = lookupDeviceID(forPortID: portID)
                Task {
                    do { try await samples.write(sample, portID: portID, deviceID: deviceID) }
                    catch { Log.app.error("Persist .telemetry failed: \(String(describing: error), privacy: .public)") }
                }
            }
        case .fullRefresh:
            break  // No event-log row for the internal coordination signal.
        }
    }

    /// Walk the live PortGraph to find the deviceID currently
    /// connected to `portID`. Used for telemetry persistence so
    /// samples FK to the right device row. nil → port is empty
    /// (still record the sample, but with NULL device_id per the
    /// schema's nullable column).
    private func lookupDeviceID(forPortID portID: PortID) -> DeviceID? {
        for host in portGraph.hosts {
            if let device = findDeviceID(in: host.ports, portID: portID) {
                return device
            }
        }
        return nil
    }

    /// Phase 11 F23: snapshot the link protocol + watts the live
    /// PortGraph holds for `portID` so the persisted `.attached`
    /// payload carries them. Note that on `.attached` the apply
    /// step hasn't run yet — for an already-known port the live
    /// `negotiated` may reflect a prior device's link state. The
    /// `.telemetry` tick that follows fills in the new device's
    /// values; the `.attached` payload captures whatever the OS
    /// reported at attach time, which is the right snapshot for
    /// "what the user saw when this happened."
    private func lookupAttachedExtras(forPortID portID: PortID) -> EventRepository.AttachedExtras {
        for host in portGraph.hosts {
            if let port = findPort(in: host.ports, portID: portID) {
                return EventRepository.AttachedExtras(
                    linkProtocol: port.negotiated?.protocolName,
                    watts: port.powerDraw?.value
                )
            }
        }
        return EventRepository.AttachedExtras()
    }

    private func findPort(in ports: [ManifoldKit.Port], portID: PortID) -> ManifoldKit.Port? {
        for port in ports {
            if port.id == portID { return port }
            if let inChild = findPort(in: port.children, portID: portID) {
                return inChild
            }
        }
        return nil
    }

    private func findDeviceID(in ports: [ManifoldKit.Port], portID: PortID) -> DeviceID? {
        for port in ports {
            if port.id == portID { return port.connectedDevice?.id }
            if let inChild = findDeviceID(in: port.children, portID: portID) {
                return inChild
            }
        }
        return nil
    }

    private func rebuildGraph() async {
        do {
            let hosts = try await discoveryService.walk()
            // Phase 10: upsert every device the walk found so the
            // History view shows boot-time devices too (no .attached
            // event fires for already-plugged devices on first walk).
            // F10 reconcile preserves first_seen on subsequent walks.
            if let devices = deviceRepository {
                for device in Self.collectDevices(from: hosts) {
                    do { try await devices.upsert(device) }
                    catch { Log.app.error("Persist walk device failed: \(String(describing: error), privacy: .public)") }
                }
            }
            let diagnostics = diagnosticEngine.diagnostics(for: hosts)
            // Phase 9: fire one notification per *newly-appearing*
            // diagnostic (compared to the prior set, dedup'd by
            // `(target, ruleIdentifier)`). Existing diagnostics that
            // re-evaluate clean stay quiet; existing ones that
            // re-fire stay quiet too — the user already saw them.
            // Replacement happens AFTER the diff so the builder reads
            // the pre-replace `portGraph.hosts` for port summaries
            // (or, if hosts aren't in the graph yet on first walk,
            // the new `hosts` array directly).
            let priorKeys = Set(portGraph.diagnostics.map(DiagnosticKey.init))
            for diag in diagnostics where !priorKeys.contains(DiagnosticKey(diag)) {
                notificationService.handle(.diagnostic(diag), graph: portGraph)
            }
            portGraph.replace(hosts: hosts, diagnostics: diagnostics)
        } catch {
            Log.discovery.error("rebuildGraph walk failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Phase 10 helper: flatten every connected `Device` across the
    /// host trees. Static so it can be called from the rebuildGraph
    /// path without capturing self.
    private static func collectDevices(from hosts: [ManifoldKit.Host]) -> [Device] {
        var out: [Device] = []
        func walk(_ ports: [ManifoldKit.Port]) {
            for port in ports {
                if let device = port.connectedDevice {
                    out.append(device)
                }
                walk(port.children)
            }
        }
        for host in hosts { walk(host.ports) }
        return out
    }

    /// Dedup key for diagnostic notification gating — matches the
    /// `(target, ruleIdentifier)` pair `PortGraph.applyDiagnostic`
    /// uses internally so the notification side and the badge side
    /// agree on "this is the same finding".
    private struct DiagnosticKey: Hashable {
        let target: PortID
        let ruleIdentifier: String
        init(_ diagnostic: Diagnostic) {
            self.target = diagnostic.target
            self.ruleIdentifier = diagnostic.ruleIdentifier
        }
    }

    // MARK: - Badge observation

    /// Watch `portGraph.totalDeviceCount` and push updates to the
    /// status-item badge. Uses `Observation.withObservationTracking`
    /// in a tight loop — the @Observable property reads inside the
    /// `apply` block re-register on every iteration so changes
    /// continue to fire updates.
    private func startBadgeObserver(controller: StatusItemController) {
        graphObservationTask = Task { @MainActor [weak self, weak controller] in
            while !Task.isCancelled {
                guard let self, let controller else { return }
                let count = withObservationTracking {
                    self.portGraph.totalDeviceCount
                } onChange: { }
                controller.setDeviceCount(count)
                // Wait for the next observation tick. Yielding lets
                // pending PortGraph mutations land before we re-read.
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    // MARK: - Window-frame persistence (SPEC §18 Phase 6 rev-6)

    /// Locate the main window in `NSApp.windows` and set its
    /// `frameAutosaveName` to `MainWindowConstants.windowFrameAutosaveName`
    /// (`"ManifoldMainWindow"`). AppKit then writes the window's
    /// frame to `~/Library/Preferences/com.Loofa.Manifold.plist`
    /// under the key `"NSWindow Frame ManifoldMainWindow"` on every
    /// resize/move and restores from there on next launch.
    ///
    /// This is the AppKit-explicit wiring SPEC §18 Phase 6 rev-6
    /// mandates — Phase 6's first round relied on SwiftUI's
    /// WindowGroup automatic state save, which the spec rev
    /// explicitly forbids ("NOT relying on SwiftUI WindowGroup
    /// automatic state save"). The §18.0 `WINDOW-FRAME-PERSISTS`
    /// procedure verifies this works at re-review.
    ///
    /// Heuristic for finding the main window: at this point in the
    /// app lifecycle (one tick after applicationDidFinishLaunching),
    /// the only `.titled + .resizable` window is the WindowGroup's
    /// MainWindow. The Settings window is created lazily on Cmd-, ;
    /// the popover doesn't have an NSWindow that matches
    /// `.titled + .resizable`. Phase 7+ that adds more windows can
    /// tighten the matcher (e.g., via a marker view).
    private func installMainWindowFrameAutosaveName() {
        guard let window = NSApp.windows.first(where: { window in
            window.styleMask.contains(.titled) && window.styleMask.contains(.resizable)
        }) else {
            // Try once more on the next tick — under unusual launch
            // conditions the WindowGroup may take >1 run-loop iteration
            // to instantiate the window. After that, give up loudly.
            Log.app.notice("Main window not found on first tick; retrying once.")
            DispatchQueue.main.async { [weak self] in
                self?.retryInstallMainWindowFrameAutosaveName()
            }
            return
        }
        applyAutosaveName(to: window)
    }

    /// Second-attempt lookup invoked from
    /// `installMainWindowFrameAutosaveName` when the window wasn't
    /// resolvable on the first run-loop tick. If still not found,
    /// log an error and bail — frame persistence will silently fail
    /// and the user will see fresh defaults on next launch. We don't
    /// hard-crash on this because a missing main window mid-launch
    /// is recoverable (the window may simply not be open yet).
    private func retryInstallMainWindowFrameAutosaveName() {
        guard let window = NSApp.windows.first(where: { window in
            window.styleMask.contains(.titled) && window.styleMask.contains(.resizable)
        }) else {
            Log.app.error("Main window still not found on retry; frame persistence not wired.")
            return
        }
        applyAutosaveName(to: window)
    }

    private func applyAutosaveName(to window: NSWindow) {
        let didSet = window.setFrameAutosaveName(MainWindowConstants.windowFrameAutosaveName)
        if didSet {
            Log.app.notice("Main window frameAutosaveName set to \(MainWindowConstants.windowFrameAutosaveName, privacy: .public).")
        } else {
            // setFrameAutosaveName returns false if another window in
            // the process already owns the same name — shouldn't
            // happen for our single-main-window app, but worth
            // logging if it does.
            Log.app.error("setFrameAutosaveName returned false — name collision?")
        }
    }

    // MARK: - Window lifecycle hooks (Phase 6)

    /// Called by `MainWindow.onAppear` so the SamplerLifecycle's
    /// surface count tracks window visibility per SPEC §18 Phase 5
    /// acceptance #3 ("pauses sampling when popover hidden AND window
    /// not visible"). Phase 5 declared the lifecycle methods; Phase 6
    /// wires them.
    func notifyMainWindowDidAppear() {
        samplerLifecycle.windowDidAppear()
    }

    func notifyMainWindowDidDisappear() {
        samplerLifecycle.windowDidDisappear()
    }

    // MARK: - Toolbar actions

    /// Activate the app + bring the standalone window forward. If the
    /// user has closed the WindowGroup window entirely, the system's
    /// `applicationShouldHandleReopen` semantics re-create it the
    /// next time the user clicks the dock icon; from a popover button
    /// we settle for activating + revealing whichever window is
    /// already present. Phase 6 may swap to `@Environment(\.openWindow)`
    /// once `MainWindow` lands.
    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    /// Open Settings. SwiftUI's `Settings` scene registers a handler
    /// for the standard `showSettingsWindow:` selector (older
    /// `showPreferencesWindow:` on macOS 12 and earlier; we target
    /// macOS 26 so `showSettingsWindow:` is the only path). The
    /// runtime selector lookup avoids importing the SettingsLink
    /// symbol indirectly.
    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let selector = NSSelectorFromString("showSettingsWindow:")
        NSApp.sendAction(selector, to: nil, from: nil)
    }

#if DEBUG
    /// DEBUG-only stress harness retained from Phase 1 — re-run the
    /// full Phase-4 pipeline (EventService → discovery walk → graph
    /// replace → badge update) under `MANIFOLD_LEAK_BENCH=N` and
    /// attach `leaks(1)` to verify zero leaked bytes.
    private func runLeakBenchIfRequested() {
        guard
            let raw = ProcessInfo.processInfo.environment["MANIFOLD_LEAK_BENCH"],
            let count = Int(raw),
            count > 0
        else { return }

        Task { [discoveryService] in
            let start = Date()
            for _ in 0..<count {
                _ = try? await discoveryService.walk()
            }
            let elapsed = Date().timeIntervalSince(start)
            let line = String(
                format: "[Manifold leak-bench] %d walks completed in %.3f s — process held open for leaks(1) attach\n",
                count,
                elapsed
            )
            if let data = line.data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
            Log.app.notice("Leak bench: \(count, privacy: .public) walks in \(elapsed, privacy: .public)s")
        }
    }
#endif
}
