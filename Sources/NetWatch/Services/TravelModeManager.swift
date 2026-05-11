import Foundation
import AppKit

@MainActor
final class TravelModeManager {
    static let shared = TravelModeManager()
    private init() {}

    /// UserDefaults key holding `[String]` of bundle IDs that were ACTUALLY running
    /// when the user activated Travel Mode. Only these get re-launched on deactivate —
    /// apps that were already closed pre-activation stay closed. Without this snapshot,
    /// toggling off would launch every app in the preset list, even ones the user
    /// hasn't opened in months (Steam, Discord, OneDrive). Bug-fix v1.0.1.
    private let snapshotKey = "netwatch.travelModeSnapshot"

    func activate() async {
        let targets = TravelModeStore.load().filter { $0.enabled }
        print("[TravelMode] activating, \(targets.count) enabled targets")

        // 1. Snapshot pre-activation running state — source of truth for deactivate.
        var snapshot: [String] = []
        for target in targets {
            if let bid = target.bundleId, AppController.isAppRunning(bundleId: bid) {
                snapshot.append(bid)
            }
        }
        UserDefaults.standard.set(snapshot, forKey: snapshotKey)
        print("[TravelMode] snapshot: \(snapshot.count) running app(s) to restore later")

        // 2. Quit only apps that ARE in snapshot (others already closed — skip).
        for target in targets {
            if let bid = target.bundleId, snapshot.contains(bid) {
                try? await AppController.quitApp(bundleId: bid)
                print("[TravelMode] quit \(target.displayName)")
            }

            // launchd agents are a separate concern from GUI apps. We bootout
            // those that are currently loaded; on next login they'll auto-start
            // again per their launchd plist. Snapshot doesn't track them yet.
            if let label = target.launchdLabel, AppController.isLaunchAgentLoaded(label: label) {
                let result = AppController.disableUserLaunchAgent(label: label)
                switch result {
                case .success:
                    print("[TravelMode] disabled launchd: \(label)")
                case .failure(let err):
                    print("[TravelMode] could not disable \(label): \(err.localizedDescription) — likely a system daemon (needs admin)")
                }
            }
        }
    }

    func deactivate() async {
        let snapshot = UserDefaults.standard.stringArray(forKey: snapshotKey) ?? []
        print("[TravelMode] deactivating, snapshot has \(snapshot.count) app(s)")

        guard !snapshot.isEmpty else {
            print("[TravelMode] empty snapshot — nothing to restore")
            return
        }

        // Build a bundleId → appPath lookup from preset (preset config is authoritative
        // for "where on disk this app lives"; snapshot tells us "which ones to start").
        var pathByBundle: [String: String] = [:]
        for t in TravelModeStore.load() {
            if let bid = t.bundleId, let path = t.appPath {
                pathByBundle[bid] = path
            }
        }

        for bid in snapshot {
            guard let path = pathByBundle[bid],
                  FileManager.default.fileExists(atPath: path),
                  !AppController.isAppRunning(bundleId: bid)
            else { continue }
            AppController.launchApp(at: path)
            print("[TravelMode] re-launched \(bid)")
        }

        UserDefaults.standard.removeObject(forKey: snapshotKey)
        print("[TravelMode] snapshot cleared")
    }
}
