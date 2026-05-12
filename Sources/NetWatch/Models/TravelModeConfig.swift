import Foundation
import AppKit

/// Default-deny whitelist. Stores bundle_id (or raw exec name) of apps allowed to
/// run during Travel Mode. Helper sub-processes inherit via prefix match —
/// allow `com.google.Chrome` ⇒ `com.google.Chrome.helper.Renderer` auto-allowed.
enum TravelWhitelistStore {
    private static let key = "netwatch.travelWhitelist.v2"

    static func load() -> Set<String> {
        if let arr = UserDefaults.standard.array(forKey: key) as? [String] {
            return Set(arr)
        }
        return []
    }

    static func save(_ set: Set<String>) {
        UserDefaults.standard.set(Array(set), forKey: key)
    }

    /// Add a key (bundle id or exec name). Returns updated set.
    @discardableResult
    static func allow(_ key: String) -> Set<String> {
        var s = load()
        s.insert(key)
        save(s)
        return s
    }

    /// Remove a key. Returns updated set.
    @discardableResult
    static func disallow(_ key: String) -> Set<String> {
        var s = load()
        s.remove(key)
        save(s)
        return s
    }

    /// True if `bundleId` is explicitly whitelisted OR any whitelist entry is its parent.
    /// `com.google.Chrome` in whitelist ⇒ `com.google.Chrome.helper.Renderer` allowed.
    static func isAllowed(_ bundleId: String, in whitelist: Set<String>) -> Bool {
        if whitelist.contains(bundleId) { return true }
        for entry in whitelist where bundleId.hasPrefix(entry + ".") {
            return true
        }
        return false
    }
}

/// Auto-baseline applied at every activation. NetWatch itself + frontmost app + active terminal
/// always run, no matter what user did with the whitelist. Prevents the worst case: pausing
/// the UI you're using to manage pause state.
enum TravelBaseline {
    /// Bundle IDs that are ALWAYS allowed during Travel Mode (in addition to user whitelist).
    /// Computed at activation time (frontmost can change). Not persisted.
    @MainActor
    static func compute() -> Set<String> {
        var s: Set<String> = []
        // NetWatch itself — without this we pause our own UI and can't recover.
        if let me = Bundle.main.bundleIdentifier { s.insert(me) }
        // Whoever's in focus when user hit the button — current work, don't break it.
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            s.insert(front)
        }
        // Active terminal — likely running build/dev workflow.
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier else { continue }
            if bid == "com.apple.Terminal" || bid == "com.googlecode.iterm2" || bid == "dev.warp.Warp-Stable" {
                s.insert(bid)
            }
        }
        return s
    }
}

/// Categorizes an app for the 3-tier Settings UI.
enum ProcessCategory {
    case userApp        // top-level GUI app with bundle id
    case helper(parent: String)  // helper/renderer/gpu sub-process; `parent` = best-guess parent group key
    case systemDaemon   // UID < 500, locked

    /// Decide category from AppStat. `allBundleIds` lets us detect helper relationships:
    /// if `app.bundleId` is a strict prefix-child of another app's bundle id, it's a helper.
    static func categorize(_ app: AppStat, allBundleIds: Set<String>) -> ProcessCategory {
        if app.isSystem { return .systemDaemon }

        // Find longest known bundle id that is a strict parent of this one.
        // E.g. allBundleIds = ["com.google.Chrome", "com.google.Chrome.helper.Renderer"]
        // → helper.Renderer is child, parent = com.google.Chrome.
        var bestParent: String?
        for candidate in allBundleIds {
            guard candidate != app.bundleId else { continue }
            guard app.bundleId.hasPrefix(candidate + ".") else { continue }
            if bestParent == nil || candidate.count > bestParent!.count {
                bestParent = candidate
            }
        }
        if let parent = bestParent {
            return .helper(parent: parent)
        }

        // Heuristic fallback for known helper naming when parent not present (parent crashed/quit).
        let lowered = app.bundleId.lowercased()
        if lowered.contains(".helper") || lowered.contains(".gpu") || lowered.contains(".renderer")
            || lowered.contains(".plugin") || lowered.contains(".webcontent") {
            // Synthesize a parent group key by stripping the suffix after last `.` until base.
            let parts = app.bundleId.split(separator: ".")
            if parts.count >= 3 {
                let parent = parts.prefix(3).joined(separator: ".")
                return .helper(parent: parent)
            }
        }

        return .userApp
    }
}

