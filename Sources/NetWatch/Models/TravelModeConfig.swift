import Foundation

struct TravelTarget: Codable, Identifiable {
    let id: UUID
    var displayName: String
    var bundleId: String?       // for GUI apps (NSWorkspace.runningApplications match)
    var launchdLabel: String?   // for daemons (com.apple.bird, com.apple.backupd-auto, ...)
    var appPath: String?        // for re-launch via `open -a`
    var enabled: Bool

    init(
        id: UUID = UUID(),
        displayName: String,
        bundleId: String? = nil,
        launchdLabel: String? = nil,
        appPath: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleId = bundleId
        self.launchdLabel = launchdLabel
        self.appPath = appPath
        self.enabled = enabled
    }
}

enum TravelModeStore {
    private static let key = "netwatch.travelTargets"

    static func load() -> [TravelTarget] {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([TravelTarget].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        save(defaultTargets)
        return defaultTargets
    }

    static func save(_ targets: [TravelTarget]) {
        if let data = try? JSONEncoder().encode(targets) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static let defaultTargets: [TravelTarget] = [
        // GUI apps — quit via AppleScript / NSRunningApplication.terminate()
        .init(displayName: "Dropbox",
              bundleId: "com.getdropbox.dropbox",
              appPath: "/Applications/Dropbox.app"),
        .init(displayName: "Google Drive",
              bundleId: "com.google.drivefs",
              appPath: "/Applications/Google Drive.app"),
        .init(displayName: "OneDrive",
              bundleId: "com.microsoft.OneDrive",
              appPath: "/Applications/OneDrive.app"),
        .init(displayName: "Spotify",
              bundleId: "com.spotify.client",
              appPath: "/Applications/Spotify.app"),
        .init(displayName: "Slack",
              bundleId: "com.tinyspeck.slackmacgap",
              appPath: "/Applications/Slack.app"),
        .init(displayName: "Telegram",
              bundleId: "ru.keepcoder.Telegram",
              appPath: "/Applications/Telegram.app"),
        .init(displayName: "Discord",
              bundleId: "com.hnc.Discord",
              appPath: "/Applications/Discord.app"),
        .init(displayName: "Steam",
              bundleId: "com.valvesoftware.steam",
              appPath: "/Applications/Steam.app"),
        // launchd-managed daemons — bootout requires admin password (one-time per session)
        .init(displayName: "iCloud Drive (bird)",
              launchdLabel: "com.apple.bird"),
        .init(displayName: "Photo Library sync",
              launchdLabel: "com.apple.cloudphotod"),
        .init(displayName: "Time Machine auto-backup",
              launchdLabel: "com.apple.backupd-auto"),
        .init(displayName: "Adobe Updater",
              launchdLabel: "com.adobe.AdobeCreativeCloud"),
        .init(displayName: "Microsoft AutoUpdate",
              launchdLabel: "com.microsoft.update.agent"),
    ]
}
