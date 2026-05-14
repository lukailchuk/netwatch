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
        guard !s.contains(key) else { return s }
        s.insert(key)
        save(s)
        return s
    }

    /// Remove a key. Returns updated set.
    @discardableResult
    static func disallow(_ key: String) -> Set<String> {
        var s = load()
        guard s.contains(key) else { return s }
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
    /// Always-allowed terminals. Edit this set when adding new terminal apps to protect.
    static let terminalBundleIds: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "io.alacritty",
        "net.kovidgoyal.kitty",
    ]

    /// Bundle IDs that are ALWAYS allowed during Travel Mode (in addition to user whitelist).
    /// Computed at activation time (frontmost can change). Not persisted.
    @MainActor
    static func compute() -> Set<String> {
        var s: Set<String> = []
        if let me = Bundle.main.bundleIdentifier { s.insert(me) }
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            s.insert(front)
        }
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier else { continue }
            if terminalBundleIds.contains(bid) { s.insert(bid) }
        }
        return s
    }
}

/// Categorizes an app for the 3-tier Settings UI.
enum ProcessCategory {
    case userApp
    case helper(parent: String)
    case systemDaemon

    /// Substrings that mark a bundle id as a helper when no explicit parent is in the running set.
    private static let helperSuffixes: [String] = [
        ".helper", ".gpu", ".renderer", ".plugin", ".webcontent",
    ]

    /// Decide category from AppStat. `allBundleIds` lets us detect helper relationships:
    /// if `app.bundleId` is a strict prefix-child of another app's bundle id, it's a helper.
    static func categorize(_ app: AppStat, allBundleIds: Set<String>) -> ProcessCategory {
        if app.isSystem { return .systemDaemon }

        // Longest known bundle id that is a strict parent of this one wins.
        // E.g. ["com.google.Chrome", "com.google.Chrome.helper.Renderer"] → parent is "com.google.Chrome".
        var bestParent: String?
        var bestLength = 0
        for candidate in allBundleIds {
            guard candidate != app.bundleId,
                  app.bundleId.hasPrefix(candidate + "."),
                  candidate.count > bestLength
            else { continue }
            bestParent = candidate
            bestLength = candidate.count
        }
        if let parent = bestParent {
            return .helper(parent: parent)
        }

        // Parent isn't in the running set (crashed/quit) — fall back to naming convention.
        let lowered = app.bundleId.lowercased()
        if Self.helperSuffixes.contains(where: { lowered.contains($0) }) {
            let parts = app.bundleId.split(separator: ".")
            if parts.count >= 3 {
                let parent = parts.prefix(3).joined(separator: ".")
                return .helper(parent: parent)
            }
        }

        return .userApp
    }
}

