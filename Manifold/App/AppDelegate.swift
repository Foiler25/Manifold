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

    /// Phase 14: invoked by `SettingsScene`'s GeneralPane via the
    /// closure threaded through ManifoldApp. Forwards the new
    /// rate to TelemetrySampler whose `didSet` clamps to
    /// `[0.5, 5.0]` and restarts the timer if it's running.
    func applySampleRate(_ hz: Double) {
        telemetrySampler?.sampleRate = hz
    }

    private var statusItemController: StatusItemController?
    private var telemetrySampler: TelemetrySampler?
    private let samplerLifecycle = SamplerLifecycle()
    private var eventConsumerTask: Task<Void, Never>?
    private var graphObservationTask: Task<Void, Never>?

    // MARK: - Phase 21 Cable diagnostics

    /// Phase 21: cable-diagnostics engine. Wraps the absorbed
    /// `CableDarwinProvider` IOKit watchers and exposes an
    /// `@Observable snapshot` for the Cables tab. Started/stopped
    /// alongside the main window via `cableEngineLifecycle` so
    /// idle CPU stays at zero when the window is closed.
    private let cableEngine = CableEngine()
    private let cableEngineLifecycle = CableEngineLifecycle()
    private let powerTelemetryEngine = PowerTelemetryEngine()
    private let powerTelemetryLifecycle = PowerTelemetryLifecycle()
    private var cablePowerObservationTask: Task<Void, Never>?

    /// Public accessor used by `ManifoldApp.body` — same
    /// "private model, exposed via published accessor" pattern as
    /// `publishedPortGraph`.
    var publishedCableEngine: CableEngine { cableEngine }
    var publishedPowerTelemetryEngine: PowerTelemetryEngine { powerTelemetryEngine }

    // MARK: - Phase 18 Battery

    /// Push-driven observer for the AppleSmartBattery
    /// `kIOGeneralInterest` callback. Forwards every property update
    /// (percent, charging state, plug state, temperature, voltage,
    /// instantaneous current/power, cycle count, raw mAh) into
    /// `portGraph.applyBattery(_:)`. Empty-diff callbacks are
    /// filtered inside the observer. This is the primary battery
    /// data path on portable Macs.
    private var batteryInterestObserver: BatteryInterestObserver?

    /// Belt-and-suspenders observer subscribed to
    /// `IOPSNotificationCreateRunLoopSource`. The IOPS public API
    /// covers the same percent / charging / plug-state events the
    /// `kIOGeneralInterest` path covers, kept registered so a future
    /// macOS revision that changes how AppleSmartBattery exposes
    /// interest notifications doesn't strand the menu-bar icon and
    /// alert engine. Both observers feed the same sink
    /// (`portGraph.applyBattery(_:)`); duplicate forwards on shared
    /// events are absorbed by `applyBattery`'s overwrite semantics.
    private var batteryNotificationObserver: BatteryNotificationObserver?

    /// Last `BatteryInfo.isExternalConnected` value forwarded from
    /// either battery observer. Used by `handleBatterySnapshot(_:)`
    /// to detect plug / unplug edges and request a full graph
    /// rebuild — `host.inputAdapter` is only refreshed inside
    /// `DiscoveryService.walk()`, which today only runs on
    /// `.fullRefresh` events. MagSafe (and other non-USB power
    /// sources) don't fire USB IOKit events on plug/unplug, so
    /// without this nudge `inputAdapter` would freeze at the value
    /// the last walk saw.
    private var lastObservedExternalConnected: Bool?

    /// Secondary `NSStatusItem` controller. nil on desktop Macs
    /// (probe returns nil) AND when the user has disabled the
    /// item via the MenuBarPane toggle. Live install / uninstall
    /// is driven by the AppStorage observer below.
    private var batteryStatusItemController: BatteryStatusItemController?

    /// Result of the one-shot probe at app start. nil → desktop
    /// Mac (no `AppleSmartBattery` service), so the secondary
    /// status item is never installed regardless of the
    /// AppStorage value.
    private var batteryHardwarePresent: Bool = false

    /// `UserDefaults.didChangeNotification` observer. Held so the
    /// observer survives the closure scope.
    private var menubarBatteryItemObserver: (any NSObjectProtocol)?

    /// Snapshot of the last applied AppStorage value so the
    /// `didChangeNotification` handler can debounce — UserDefaults
    /// posts the notification for ANY default change, not just
    /// the one we care about.
    private var lastObservedBatteryItemVisible: Bool?

    /// Per-`graph.battery` observer task — pushes the latest
    /// `BatteryInfo?` into the secondary status item controller's
    /// `setBattery(_:)` whenever the graph's battery field changes.
    /// Mirrors the `startBadgeObserver` Pattern A from §13.5.
    private var batteryObservationTask: Task<Void, Never>?

    // MARK: - Phase 19 Battery alerts (notch-pop)

    /// Notch-anchored panel controller. Shared owner of the
    /// `NotchPanel` + `NSHostingController`. Constructed only when
    /// `batteryHardwarePresent == true` per SPEC §21.11; nil on
    /// desktop Macs.
    private var notchPanelController: NotchPanelController?

    /// Stateful consumer of `BatteryInfo` per SPEC §21.5. Wired into
    /// the existing 50ms battery observer — `engine.handle(info)` is
    /// called alongside `controller.setBattery(info)` in
    /// `startBatteryObserver`. Constructed only on portable Macs.
    private var batteryAlertEngine: BatteryAlertEngine?

    /// `@Observable` user preferences shared between MenuBarPane and
    /// the alert engine. Source of truth for the alert list + the
    /// power-source flags + the master sound toggle. Seeded on first
    /// read per SPEC §21.7. Constructed only on portable Macs.
    private var batteryAlertPreferences: BatteryAlertPreferences?

    /// Public accessor so `ManifoldApp` can pass the same
    /// preferences instance into `MenuBarPane` for the Settings UI.
    /// nil on desktop Macs (battery probe returned nil) — the pane
    /// hides its battery-alert sections in that case.
    var publishedBatteryAlertPreferences: BatteryAlertPreferences? { batteryAlertPreferences }

    /// Per-`graph.battery` observer task that feeds the alert
    /// engine. Independent of `batteryObservationTask` (which feeds
    /// the status item) so the engine fires regardless of whether
    /// the user has the secondary menubar item visible.
    private var batteryAlertEngineObservationTask: Task<Void, Never>?

    /// Phase 20: DiskArbitration callback subscription. Fires a
    /// `.fullRefresh` whenever a USB / TB volume mounts, unmounts,
    /// or its description changes (volume name appearing post-mount).
    /// Most plug events resolve through this fast (<1 s on a single-
    /// volume drive).
    private var volumeMountObserver: VolumeMountObserver?

    /// Phase 20: staggered poll fallback for the rare cases where
    /// DA's callback pipeline doesn't fire for late mounts —
    /// observed on multi-LUN USB Mass Storage devices (a card reader
    /// with two cards) where the second-card mount can land after
    /// the DA observer's burst settles, and on Macs where USB
    /// accessory authorization gates the mount until the user
    /// consents (delayed several seconds, sometimes minutes). The
    /// poll bails out as soon as every storage device has a
    /// `friendlyName`, so the typical fast-mount path it doesn't
    /// run extra rebuilds.
    private var deferredVolumeNameRefreshTask: Task<Void, Never>?

    /// Phase 20: IOKit general-interest observer on `AppleSDXCSlot`.
    /// Fires when the slot's properties change — most importantly
    /// `Card Present` flipping after the
    /// `AppleSDXCBlockStorageDevice`-doesn't-terminate quirk
    /// (Finder-eject + physical pull leaves the BlockStorageDevice
    /// in IOReg as a stale instance, but the slot's `Card Present`
    /// does flip to No, and that flip emits a general-interest
    /// message we can subscribe to). Replaces a previous
    /// 3-second poll with proper IOKit-native event delivery —
    /// idle CPU is zero now.
    private var sdCardSlotInterestObserver: SDCardSlotInterestObserver?

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

    // MARK: - Phase 13 Widget snapshot

    /// Debounced snapshot writer. Constructed in `applicationDidFinishLaunching`
    /// once `portGraph` is wired. nil only on the unlikely path
    /// where the App-Support container resolution fails (Phase 13
    /// deviation: no App Group entitlement, so the path is
    /// `~/Library/Application Support/com.Loofa.Manifold/`).
    private var snapshotCoordinator: SnapshotCoordinator?

    // MARK: - Phase 16 Sparkle

    /// Lazy so the SPUStandardUpdaterController construction cost
    /// only lands when the user actually opens Settings ▸ Updates.
    /// UpdatesPane reaches it via `publishedUpdaterController`.
    private lazy var _updaterController: UpdaterController = UpdaterController()
    var publishedUpdaterController: UpdaterController { _updaterController }

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
#if DEBUG
        // Manifold normally launches as a menu-bar accessory. UI tests
        // that exercise the standalone window opt into a regular app
        // activation policy before SwiftUI constructs its WindowGroup,
        // making the initial scene deterministic without changing the
        // production launch experience.
        if ProcessInfo.processInfo.environment["MANIFOLD_AUTOOPEN_WINDOW"] != nil {
            NSApp.setActivationPolicy(.regular)
        }
#endif
    }

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

        // Phase 20: subscribe to DiskArbitration mount events so a
        // newly-mounted USB / TB / SD volume's name (e.g. "PlanckSSD")
        // lands in the row the moment DA publishes it — without us
        // having to poll on a timer. The observer debounces internally,
        // so DA's natural callback burst at mount (disk-appeared +
        // description-changed for each LUN) collapses to one
        // `.fullRefresh` emission. AppDelegate's existing event
        // handler picks that up and runs `rebuildGraph()`.
        volumeMountObserver = VolumeMountObserver { [weak self] in
            self?.eventService?.requestRefresh()
        }

        // Phase 20: subscribe to AppleSDXCSlot general-interest
        // messages. Catches the `AppleSDXCBlockStorageDevice` doesn't-
        // terminate quirk without polling — see the observer's
        // header comment for the bug detail.
        sdCardSlotInterestObserver = SDCardSlotInterestObserver { [weak self] in
            self?.eventService?.requestRefresh()
        }
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
        // Phase 14: apply the user's persisted sample-rate
        // preference at boot. Falls back to the default (1.0 Hz)
        // when the key is absent. The `didSet` clamps; an
        // out-of-range stored value gets normalised on assignment.
        let persistedRate = UserDefaults.standard.double(forKey: SettingsKeys.sampleRateHz)
        if persistedRate > 0 {
            sampler.sampleRate = persistedRate
        }
        samplerLifecycle.attach(sampler: sampler)

        // Phase 21: cable engine binds to its lifecycle. The engine
        // itself is `@Observable` and lives on AppDelegate so the
        // single instance is shared between MainWindow and any
        // future surfaces (Settings tab, etc.).
        cableEngineLifecycle.attach(cableEngine)
        powerTelemetryLifecycle.attach(powerTelemetryEngine)
        startCablePowerObserver()

        // Phase 18: battery sampler on a parallel timer, lifecycle-
        // paused alongside the USB telemetry sampler. The closure
        // forwards each tick to `portGraph.applyBattery(_:)`.
        installBatterySampler()
        installBatteryStatusItemIfEligible()
        startBatteryItemVisibilityObserver()

        // Seed the initial walk by calling rebuildGraph directly.
        // We previously routed through `service.requestRefresh()` for
        // shape uniformity with subsequent refreshes, but that
        // racy: `startEventConsumer` spawns a Task whose `for await
        // event in service.events()` doesn't register its continuation
        // until the Task body actually runs, which is later than the
        // synchronous `requestRefresh()` emission. The `.fullRefresh`
        // would fire into an empty continuation set + get dropped → the
        // initial PortGraph populate never happened. Calling
        // `rebuildGraph` directly closes the race; subsequent runtime
        // refreshes still flow through `.fullRefresh` correctly because
        // by then the consumer is established.
        Task { @MainActor [weak self] in
            await self?.rebuildGraph()
        }

        // Phase 9: prompt for notification authorization once per
        // install. Detached Task because requestAuthorization is
        // async and we don't want to block app launch on the user's
        // permission dialog response.
        Task { [notificationService] in
            await notificationService.requestAuthorizationIfNeeded()
        }

        // Phase 12: register the AppIntents data-source bridge so
        // ManifoldShortcuts intents can reach the live graph + the
        // event repository. IntentEnvironment is nil-checked by the
        // queries / intents so a Shortcut invoked before app launch
        // completes returns empty data instead of crashing.
        IntentEnvironment.dataSource = LiveIntentDataSource(
            graph: portGraph,
            eventRepository: eventRepository
        )

        // Phase 13: snapshot coordinator. Debounced writes (≤2 Hz)
        // + WidgetCenter.reloadAllTimelines on each successful
        // write. Initial write fires after the first walk completes
        // via the same `requestSnapshotUpdate()` path the event
        // consumer uses.
        snapshotCoordinator = SnapshotCoordinator(graph: portGraph)
        snapshotCoordinator?.requestUpdate()

#if DEBUG
        runLeakBenchIfRequested()
        autoOpenPopoverIfRequested()
        autoOpenWindowIfRequested()
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

    /// DEBUG-only companion to the popover hook. The early activation
    /// policy change in `applicationWillFinishLaunching` normally makes
    /// SwiftUI create the WindowGroup; this next-tick bring-up also
    /// handles a restored window that starts miniaturized or behind
    /// another app.
    private func autoOpenWindowIfRequested() {
        guard ProcessInfo.processInfo.environment["MANIFOLD_AUTOOPEN_WINDOW"] != nil else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.openMainWindow()
        }
    }
#endif

    func applicationWillTerminate(_ notification: Notification) {
        eventConsumerTask?.cancel()
        graphObservationTask?.cancel()
        batteryObservationTask?.cancel()
        // Phase 19: cancel the engine observer + synchronously dismiss
        // the notch panel so a half-open panel doesn't linger as the
        // app exits (per SPEC §21.11).
        batteryAlertEngineObservationTask?.cancel()
        // Phase 21.7 push-driven battery observers. Both are
        // independent of `samplerLifecycle` (battery data path is
        // not surface-gated), so they need explicit teardown.
        batteryInterestObserver?.stop()
        batteryInterestObserver = nil
        batteryNotificationObserver?.stop()
        batteryNotificationObserver = nil
        // Phase 20: tear down the DA volume-mount subscription before
        // the AppDelegate strong reference drops.
        volumeMountObserver?.stop()
        volumeMountObserver = nil
        sdCardSlotInterestObserver?.stop()
        sdCardSlotInterestObserver = nil
        deferredVolumeNameRefreshTask?.cancel()
        notchPanelController?.dismiss()
        samplerLifecycle.shutdown()
        // Phase 21: tear down the cable engine alongside the rest of
        // the lifecycle-managed surfaces. Idempotent.
        cableEngineLifecycle.shutdown()
        cablePowerObservationTask?.cancel()
        cablePowerObservationTask = nil
        powerTelemetryLifecycle.shutdown()
        eventService?.shutdown()
        downsamplingJob?.stop()
        snapshotCoordinator?.shutdown()
        if let observer = menubarBatteryItemObserver {
            NotificationCenter.default.removeObserver(observer)
            menubarBatteryItemObserver = nil
        }
    }

    /// Fires when the user clicks the dock icon (or our popover-button
    /// `NSWorkspace.openApplication` re-trigger) while no main window
    /// is visible. Returning true lets SwiftUI's WindowGroup default
    /// behavior recreate the window from the scene definition.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return true
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
                // Brief settling delay before re-walking IOReg.
                // The chassis controller (`AppleTCControllerType10`)
                // and the USB plane (`IOUSBHostDevice`) propagate
                // plug / unplug events at different rates — a
                // rebuild that fires the instant the IOKit
                // notification arrives can read one source pre-
                // propagation and the other post-, which is exactly
                // how phantom rows like "USB Receiver still showing
                // alongside Port 2 — Empty" leak in. 200 ms is well
                // under the human-visible threshold for plug events
                // and large enough that both registries have caught
                // up in the field.
                try? await Task.sleep(for: .milliseconds(200))
                await rebuildGraph()
                // Phase 20: schedule a staggered poll as a fallback
                // to the DA observer. Multi-LUN USB Mass Storage
                // (e.g. a card reader with two cards) sometimes has
                // its second mount land after the DA observer's
                // initial post-attach burst settles, and macOS USB
                // accessory authorization can delay the mount
                // beyond a single observer-debounce window. The
                // poll cancels itself early once every storage row
                // has a `friendlyName`, so single-volume drives
                // (handled fast by the DA observer) don't run the
                // extra rebuilds.
                scheduleDeferredVolumeNameRefresh()
            }
            // Phase 13: schedule a debounced snapshot write. The
            // 500 ms debounce means a 1 Hz telemetry tick + a
            // hot-plug event in the same window collapse to one
            // snapshot file + one widget reload.
            recordEventForSnapshot(event)
            snapshotCoordinator?.requestUpdate()
        }
    }

    /// Phase 20 fallback: staggered re-walks at 1 s, 3 s, 6 s, 10 s
    /// after a plug event. Always runs the full set; early-bailing
    /// on "every storage device has a friendlyName" was tried first
    /// but proved too aggressive — a multi-LUN card reader's parent
    /// port has `kind = .other` (Phase 2 default), so the bail check
    /// passed as soon as any other already-mounted drive's row was
    /// stable, killing the poll before the card reader's LUNs got
    /// a chance to mount. Four extra rebuilds at ≈1 ms each is well
    /// inside the noise floor — safer to always run them.
    ///
    /// Multiple plug events in quick succession cancel the in-flight
    /// poll (debounced).
    @MainActor
    private func scheduleDeferredVolumeNameRefresh() {
        deferredVolumeNameRefreshTask?.cancel()
        deferredVolumeNameRefreshTask = Task { @MainActor [weak self] in
            for delayMs in [1000, 2000, 3000, 4000] {
                try? await Task.sleep(for: .milliseconds(delayMs))
                guard !Task.isCancelled, let self else { return }
                await self.rebuildGraph()
            }
        }
    }

    /// Stamp `lastEventAt` on the snapshot coordinator for
    /// user-visible events. Telemetry + fullRefresh aren't
    /// "events" in the user-facing sense; they don't update the
    /// snapshot's `lastEventAt` field.
    private func recordEventForSnapshot(_ event: PortEvent) {
        switch event {
        case .attached, .detached, .diagnostic:
            snapshotCoordinator?.recordEventTimestamp(.now)
        case .telemetry, .fullRefresh:
            break
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
            // F25 closure (Phase 12 review): donate the
            // WatchForDeviceConnectIntent with this device's
            // identity so Siri / Shortcuts learns to suggest the
            // intent when the user plugs the same device again.
            // Donations are best-effort — failure logs + drops.
            IntentDonor.donateAttachedDevice(device)
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
            // Phase 13: post-rebuild snapshot. The event-consumer
            // path covers per-event updates; this covers the cold
            // launch + the `.fullRefresh` re-walk path where no
            // per-event handler runs.
            snapshotCoordinator?.requestUpdate()
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
    /// status-item badge. Change-driven via
    /// `Observation.withObservationTracking`: the loop applies the
    /// current value, then suspends on a `CheckedContinuation` until
    /// the next mutation fires `onChange`. No tight polling, no idle
    /// CPU between mutations.
    private func startBadgeObserver(controller: StatusItemController) {
        graphObservationTask = Task { @MainActor [weak self, weak controller] in
            while !Task.isCancelled {
                guard let self, let controller else { return }
                controller.setDeviceCount(self.portGraph.totalDeviceCount)
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self.portGraph.totalDeviceCount
                    } onChange: {
                        cont.resume()
                    }
                }
            }
        }
    }

    // MARK: - Phase 18 Battery wiring

    /// Stand up the battery data path. Two push observers, no
    /// polling:
    ///
    ///   1. `BatteryInterestObserver` — primary. Subscribes to
    ///      `kIOGeneralInterest` on AppleSmartBattery; the kernel
    ///      fires for every property update (percent, charging,
    ///      plug state, temperature, voltage, current/power, cycle
    ///      count, raw mAh, time-remaining). Validated empirically
    ///      (Phase 21.7 PoC) to cover every field the BatteryView
    ///      surfaces.
    ///   2. `BatteryNotificationObserver` — belt-and-suspenders.
    ///      Subscribes to `IOPSNotificationCreateRunLoopSource`,
    ///      Apple's documented public API. Overlaps the interest
    ///      observer on percent / charging / plug-state events; kept
    ///      for resilience against a future macOS change to
    ///      AppleSmartBattery's interest behavior.
    ///
    /// Both feed the same sink (`portGraph.applyBattery(_:)`).
    /// `applyBattery` is idempotent — re-assigning the same value is
    /// harmless — so duplicate forwards on shared events don't cause
    /// behavioral issues.
    private func installBatterySampler() {
        // Primary push path. `deliverInitialSnapshot()` runs a
        // synchronous read so the graph has a non-nil battery value
        // before SwiftUI's first frame, even if no organic interest
        // event has fired yet.
        let interest = BatteryInterestObserver { [weak self] info in
            self?.handleBatterySnapshot(info)
        }
        interest.deliverInitialSnapshot()
        batteryInterestObserver = interest

        // Belt-and-suspenders IOPS observer. Same sink, same shape.
        let notification = BatteryNotificationObserver { [weak self] info in
            self?.handleBatterySnapshot(info)
        }
        notification.deliverInitialSnapshot()
        batteryNotificationObserver = notification
    }

    /// Common sink for both battery push observers
    /// (`BatteryInterestObserver` and `BatteryNotificationObserver`).
    /// Forwards the snapshot into `portGraph.applyBattery(_:)` and,
    /// on a real edge in `isExternalConnected`, asks `EventService`
    /// for a `.fullRefresh` so `host.inputAdapter` is re-walked.
    /// MagSafe / non-USB power sources don't fire USB IOKit events
    /// on plug/unplug, so without this nudge the host's adapter
    /// info would stay stale at the previous walk's value.
    private func handleBatterySnapshot(_ info: BatteryInfo?) {
        portGraph.applyBattery(info)
        let currentExternal = info?.isExternalConnected
        let isFlip = lastObservedExternalConnected != nil
            && lastObservedExternalConnected != currentExternal
        lastObservedExternalConnected = currentExternal
        if isFlip {
            eventService?.requestRefresh()
        }
    }

    /// One-shot probe + AppStorage gate. Per SPEC §20.6 + Q12:
    /// the secondary status item is installed iff the probe returns
    /// non-nil AND the AppStorage toggle is true. Desktop Macs
    /// (probe nil) never install regardless of the toggle.
    ///
    /// Phase 19: this is also where the alert stack
    /// (`BatteryAlertPreferences`, `NotchPanelController`,
    /// `BatteryAlertEngine`) gets instantiated — gated on
    /// `batteryHardwarePresent` per SPEC §21.11.
    private func installBatteryStatusItemIfEligible() {
        let probe = BatterySnapshotReader.currentSnapshot()
        let probeHasBattery = (probe != nil)
        batteryHardwarePresent = probeHasBattery
        // Seed the graph with the probe so the Battery tab + status
        // item have data on the first frame, before the first
        // sampler tick lands.
        if let probe {
            portGraph.applyBattery(probe)
        }

        // Phase 19 alert stack — entire stack only when
        // batteryHardwarePresent. Desktop Macs see nothing.
        if probeHasBattery {
            installBatteryAlertStack()
        }

        let toggleOn = (UserDefaults.standard.object(forKey: SettingsKeys.menubarBatteryItemVisible) as? Bool)
            ?? SettingsDefaults.menubarBatteryItemVisible
        lastObservedBatteryItemVisible = toggleOn

        guard probeHasBattery, toggleOn else {
            return
        }
        installBatteryStatusItemController()
    }

    /// Stand up the Phase 19 alert stack — preferences, notch panel
    /// controller, alert engine. The engine's adapter-description
    /// closure walks the live `portGraph.hosts` for an
    /// `inputAdapter.description`, falling back to nil so the engine
    /// uses its localized fallback subtitle.
    ///
    /// The engine observer is started here (not gated on the status
    /// item being installed) so battery alerts continue to fire when
    /// the user has the menubar item disabled but still wants
    /// alerts. The observer mirrors the §13.5 Pattern A loop the
    /// status item uses, with its own 50ms cadence.
    private func installBatteryAlertStack() {
        let preferences = BatteryAlertPreferences()
        let panelController = NotchPanelController()
        let engine = BatteryAlertEngine(
            preferences: preferences,
            notchPanelController: panelController,
            adapterDescription: { [weak self] in
                self?.portGraph.hosts.first?.inputAdapter?.description
            },
            // Pass the graph so plug/unplug alerts can re-render their
            // time-remaining caption live during the 3 s panel lifespan
            // (matches whatever the popover would show at the same
            // instant). Observation is scoped to the SwiftUI view
            // tree — torn down on auto-dismiss, no cost while no
            // alert is on screen.
            liveBatteryGraph: portGraph
        )
        self.batteryAlertPreferences = preferences
        self.notchPanelController = panelController
        self.batteryAlertEngine = engine
        startBatteryAlertEngineObserver(engine: engine)
    }

    /// Per-graph battery observer for the alert engine. Feeds
    /// `engine.handle(info)` on every change to `portGraph.battery`.
    /// Independent of the status-item observer so the engine fires
    /// regardless of whether the user has the secondary menubar
    /// item visible. Change-driven (see `startBadgeObserver`).
    private func startBatteryAlertEngineObserver(engine: BatteryAlertEngine) {
        batteryAlertEngineObservationTask?.cancel()
        batteryAlertEngineObservationTask = Task { @MainActor [weak self, weak engine] in
            while !Task.isCancelled {
                guard let self, let engine else { return }
                if let info = self.portGraph.battery {
                    engine.handle(info)
                }
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self.portGraph.battery
                    } onChange: {
                        cont.resume()
                    }
                }
            }
        }
    }

    /// Concrete install path. Builds the controller, runs `install()`,
    /// kicks off the per-graph observer that pushes battery snapshots
    /// to the menu-bar glyph + percent.
    private func installBatteryStatusItemController() {
        guard batteryStatusItemController == nil else { return }
        let controller = BatteryStatusItemController(
            graph: portGraph,
            onOpenWindow: { [weak self] in self?.openMainWindow() },
            onOpenSettings: { [weak self] in self?.openSettingsOnBatteryPane() },
            onPopoverDidShow: { [weak self] in self?.samplerLifecycle.popoverDidOpen() },
            onPopoverDidClose: { [weak self] in self?.samplerLifecycle.popoverDidClose() }
        )
        controller.install()
        batteryStatusItemController = controller
        startBatteryObserver(controller: controller)
    }

    /// Pattern A observer per §13.5 — same shape as `startBadgeObserver`.
    /// Change-driven: pushes `graph.battery` into `controller.setBattery`,
    /// then suspends until the next mutation fires `onChange`.
    private func startBatteryObserver(controller: BatteryStatusItemController) {
        batteryObservationTask?.cancel()
        batteryObservationTask = Task { @MainActor [weak self, weak controller] in
            while !Task.isCancelled {
                guard let self, let controller else { return }
                controller.setBattery(self.portGraph.battery)
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self.portGraph.battery
                    } onChange: {
                        cont.resume()
                    }
                }
            }
        }
    }

    /// Watch `UserDefaults.didChangeNotification` for changes to
    /// the battery-item-visible AppStorage value. On a transition
    /// from on → off OR off → on, install / uninstall the
    /// controller accordingly. Probe gate (`batteryHardwarePresent`)
    /// still applies — desktop Macs never install regardless.
    private func startBatteryItemVisibilityObserver() {
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            // Hop to MainActor — the observer queue is .main so this
            // is already on the main thread, but the `Task @MainActor`
            // hop satisfies Swift 6 strict-concurrency around the
            // captured `self`.
            Task { @MainActor [weak self] in
                self?.handleBatteryItemVisibilityChange()
            }
        }
        menubarBatteryItemObserver = observer
    }

    /// Compare the live AppStorage value against
    /// `lastObservedBatteryItemVisible`; install / uninstall on a
    /// real transition only. UserDefaults posts didChange for any
    /// default change so the dedup is load-bearing.
    private func handleBatteryItemVisibilityChange() {
        let toggleOn = (UserDefaults.standard.object(forKey: SettingsKeys.menubarBatteryItemVisible) as? Bool)
            ?? SettingsDefaults.menubarBatteryItemVisible
        guard toggleOn != lastObservedBatteryItemVisible else { return }
        lastObservedBatteryItemVisible = toggleOn

        if !batteryHardwarePresent {
            // Desktop Mac path — toggle is documented as a no-op.
            return
        }
        if toggleOn {
            installBatteryStatusItemController()
        } else {
            uninstallBatteryStatusItemController()
        }
    }

    private func uninstallBatteryStatusItemController() {
        batteryObservationTask?.cancel()
        batteryObservationTask = nil
        batteryStatusItemController?.uninstall()
        batteryStatusItemController = nil
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
        // Pin the NSWindow's minSize directly. SwiftUI's
        // `.frame(minWidth:)` plus `.windowResizability(.contentMinSize)`
        // is supposed to do this, but a stale autosaved frame from an
        // earlier build with a smaller min could still restore below
        // current values + leave SwiftUI in a sidebar-only collapsed
        // state. Setting AppKit's minSize as a hard floor stops that.
        window.minSize = MainWindowConstants.minimumWindowSize

        // If the restored frame is smaller than the new floor, grow it
        // back up to the minimum so the user doesn't see a clipped
        // window on next launch.
        var frame = window.frame
        var needsResize = false
        if frame.width < window.minSize.width {
            frame.size.width = window.minSize.width
            needsResize = true
        }
        if frame.height < window.minSize.height {
            frame.size.height = window.minSize.height
            needsResize = true
        }
        if needsResize {
            window.setFrame(frame, display: true, animate: false)
        }

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
    /// wires them. Also flips the activation policy to `.regular` so
    /// the Dock icon appears alongside the visible window.
    func notifyMainWindowDidAppear() {
        samplerLifecycle.windowDidAppear()
        // Phase 21: bring the cable engine online alongside the
        // telemetry sampler. Idempotent — repeat appears are no-ops.
        cableEngineLifecycle.windowDidAppear()
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    /// Mirror of the appear-side hook. Switches the activation policy
    /// to `.accessory` when the main window goes away so Manifold
    /// becomes a menu-bar-only app — the Dock icon disappears, the
    /// status item stays. Re-opening the window via the popover's
    /// "Open Manifold" button (which runs `openMainWindow`) drops
    /// back into `.regular` automatically through this method's
    /// `onAppear`-side counterpart.
    func notifyMainWindowDidDisappear() {
        samplerLifecycle.windowDidDisappear()
        // Phase 21: stop the cable engine when the window closes —
        // 1Hz IOKit polling is wasted work with no observer.
        cableEngineLifecycle.windowDidDisappear()
        // Defer the policy flip one runloop tick. SwiftUI's
        // `onDisappear` fires before the NSWindow is fully closed;
        // switching policy mid-close can leave AppKit thinking a
        // closing window still has focus, which suppresses the next
        // `applicationShouldHandleReopen`.
        DispatchQueue.main.async {
            if NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func notifyPowerSurfaceDidAppear(_ id: String) {
        powerTelemetryLifecycle.surfaceDidAppear(id)
    }

    func notifyPowerSurfaceDidDisappear(_ id: String) {
        powerTelemetryLifecycle.surfaceDidDisappear(id)
    }

    private func startCablePowerObserver() {
        cablePowerObservationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.powerTelemetryEngine.updatePorts(self.cableEngine.snapshot?.ports ?? [])
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self.cableEngine.snapshot
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    // MARK: - Toolbar actions

    /// Activate the app + bring the standalone window forward. If no
    /// titled+resizable window is present (user closed it entirely),
    /// re-open the app bundle to trigger the
    /// `applicationShouldHandleReopen` path that SwiftUI's WindowGroup
    /// listens to, which recreates the window.
    private func openMainWindow() {
        // Match the same heuristic `installMainWindowFrameAutosaveName`
        // uses for the WindowGroup's NSWindow — the popover's
        // _NSPopoverWindow is not .titled, the Settings window is
        // typically not .resizable, so this isolates the main window.
        let mainWindow = NSApp.windows.first(where: { window in
            window.styleMask.contains(.titled)
                && window.styleMask.contains(.resizable)
        })

        if let mainWindow {
            NSApp.activate(ignoringOtherApps: true)
            if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }

        // Window has been closed entirely. Re-launching the bundle
        // hits `applicationShouldHandleReopen` which SwiftUI's
        // WindowGroup default behavior handles by re-creating the
        // window. The completion handler runs off-main; logging only.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: config
        ) { _, error in
            if let error {
                Log.app.error("openMainWindow re-open failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// AppKit-side complement to `PopoverRoot`'s
    /// `@Environment(\.openSettings)` action: activate the app so the
    /// Settings window comes to the front when SwiftUI presents it
    /// (the popover's `_NSPopoverWindow` is not key, so without an
    /// explicit activate the new Settings window can open behind
    /// whatever app was previously active).
    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Variant of `openSettings()` that pre-selects the Menu Bar
    /// pane via `SettingsKeys.selectedSettingsPaneId`. Wired to the
    /// battery popover's gear button so the user lands directly on
    /// the Battery / Menu Bar settings instead of wherever they were
    /// last. Writing the AppStorage key first lets `SettingsScene`'s
    /// `TabView` selection binding pick up the new value when SwiftUI
    /// presents the window from `@Environment(\.openSettings)`.
    private func openSettingsOnBatteryPane() {
        UserDefaults.standard.set(
            SettingsTabID.menubar.rawValue,
            forKey: SettingsKeys.selectedSettingsPaneId
        )
        NSApp.activate(ignoringOtherApps: true)
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
