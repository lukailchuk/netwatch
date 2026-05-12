import Foundation
import AppKit
import Combine
import os

/// Default-deny Travel Mode. When active, every non-whitelisted user-space app is SIGSTOP'd.
/// Deactivate resumes only what THIS session paused — manual pauses from the grid stay paused.
@MainActor
final class TravelModeManager: ObservableObject {
    static let shared = TravelModeManager()

    private let log = Logger(subsystem: "io.netwatch", category: "travel-mode")

    @Published private(set) var isActive: Bool = false

    /// Bundle IDs that THIS activation paused. Source of truth for what deactivate should resume.
    /// Excludes anything already paused before activation (manual user pauses stay manual).
    private var sessionPausedBundles: Set<String> = []

    /// Apps the user explicitly launched during Travel Mode → auto-allowed for this session.
    /// Not persisted — clears on deactivate. User intent: "I just opened it, I want it."
    private var sessionWhitelist: Set<String> = []

    /// NSWorkspace observer token, kept so we can unsubscribe on deactivate.
    private var launchObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Lifecycle

    func activate() async {
        let whitelist = effectiveWhitelist()
        log.info("activate: whitelist size \(whitelist.count)")

        let monitor = TrafficMonitor.shared
        var paused: Set<String> = []

        for app in monitor.apps {
            // System procs: SIGSTOP doesn't work (UID < 500). Show them but don't touch.
            if app.isSystem { continue }
            // No live pids = nothing to pause (DB-only history row).
            if app.pids.isEmpty { continue }
            // Already paused (manual) — leave alone, not our jurisdiction.
            if AppController.isPausedBundle(app.bundleId) { continue }
            // Whitelisted explicitly or via parent inheritance.
            if TravelWhitelistStore.isAllowed(app.bundleId, in: whitelist) { continue }

            await AppController.pause(bundleId: app.bundleId, pids: app.pids)
            paused.insert(app.bundleId)
        }

        sessionPausedBundles = paused
        isActive = true
        startLaunchObserver()
        log.info("activate done: paused \(paused.count) bundles")
    }

    func deactivate() async {
        log.info("deactivate: resuming \(self.sessionPausedBundles.count) bundles")
        stopLaunchObserver()

        let snapshot = AppController.pausedBundlesSnapshot()
        for bundleId in sessionPausedBundles {
            let pids = snapshot[bundleId] ?? []
            await AppController.resume(bundleId: bundleId, pids: pids)
        }

        sessionPausedBundles.removeAll()
        sessionWhitelist.removeAll()
        isActive = false
    }

    /// Emergency button. Same as deactivate but distinct for telemetry/logging context.
    func panicResume() async {
        log.warning("PANIC: resuming all \(self.sessionPausedBundles.count) bundles")
        await deactivate()
    }

    // MARK: - Whitelist mutations (called from Settings UI)

    /// Persist whitelist entry. If currently paused by THIS session, resume immediately.
    func allow(bundleId: String) async {
        TravelWhitelistStore.allow(bundleId)

        guard isActive, sessionPausedBundles.contains(bundleId) else { return }
        let pids = AppController.pausedBundlesSnapshot()[bundleId] ?? []
        await AppController.resume(bundleId: bundleId, pids: pids)
        sessionPausedBundles.remove(bundleId)
        TrafficMonitor.shared.tickNow()
    }

    /// Remove from whitelist. If Travel Mode active and bundle currently running, pause it.
    func disallow(bundleId: String) async {
        TravelWhitelistStore.disallow(bundleId)

        guard isActive else { return }
        guard let app = TrafficMonitor.shared.apps.first(where: { $0.bundleId == bundleId }) else { return }
        guard !app.isSystem, !app.pids.isEmpty else { return }
        guard !AppController.isPausedBundle(bundleId) else { return }  // already paused

        await AppController.pause(bundleId: bundleId, pids: app.pids)
        sessionPausedBundles.insert(bundleId)
        TrafficMonitor.shared.tickNow()
    }

    // MARK: - Reconciliation (called each sample tick)

    /// Auto-pause new processes that appeared since last sample. Default-deny consistency:
    /// no fresh traffic can sneak through while Travel Mode is on.
    func reconcile(currentApps: [AppStat]) async {
        guard isActive else { return }
        let whitelist = effectiveWhitelist()

        for app in currentApps {
            // Re-check between awaits — PANIC button or deactivate may have flipped state
            // while we suspended on the previous `await pause`. Without this we keep pausing
            // after the user already hit Resume all.
            guard isActive else { return }
            if app.isSystem || app.pids.isEmpty { continue }
            if sessionPausedBundles.contains(app.bundleId) { continue }
            if AppController.isPausedBundle(app.bundleId) { continue }
            if TravelWhitelistStore.isAllowed(app.bundleId, in: whitelist) { continue }

            await AppController.pause(bundleId: app.bundleId, pids: app.pids)
            sessionPausedBundles.insert(app.bundleId)
            log.info("reconcile: paused new bundle \(app.bundleId, privacy: .public)")
        }
    }

    // MARK: - Preview (first-run UX)

    /// Apps that would be paused if user toggled Travel Mode on right now.
    /// Used by the first-run preview sheet.
    func previewCandidates() -> [AppStat] {
        let whitelist = effectiveWhitelist()
        return TrafficMonitor.shared.apps.filter { app in
            !app.isSystem
                && !app.pids.isEmpty
                && !AppController.isPausedBundle(app.bundleId)
                && !TravelWhitelistStore.isAllowed(app.bundleId, in: whitelist)
        }
    }

    // MARK: - Helpers

    /// User whitelist ∪ activation-time baseline ∪ session auto-launches.
    private func effectiveWhitelist() -> Set<String> {
        TravelWhitelistStore.load()
            .union(TravelBaseline.compute())
            .union(sessionWhitelist)
    }

    private func startLaunchObserver() {
        guard launchObserver == nil else { return }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier else { return }
            Task { @MainActor in
                guard let self else { return }
                guard self.isActive else { return }
                self.sessionWhitelist.insert(bid)
                self.log.info("session auto-allow: \(bid, privacy: .public) (user launched)")
            }
        }
    }

    private func stopLaunchObserver() {
        if let observer = launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            launchObserver = nil
        }
    }
}
