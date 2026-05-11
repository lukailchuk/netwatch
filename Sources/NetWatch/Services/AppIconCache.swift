import AppKit
import SwiftUI

@MainActor
final class AppIconCache {
    static let shared = AppIconCache()
    private var cache: [String: NSImage] = [:]

    /// Returns an app icon for a bundle ID. Falls back to a generic document
    /// icon for non-installed apps (background daemons without a .app).
    func icon(forBundleId bundleId: String) -> NSImage {
        if let cached = cache[bundleId] {
            return cached
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            cache[bundleId] = icon
            return icon
        }

        // Generic fallback — matches the macOS "executable binary" icon
        let generic = NSWorkspace.shared.icon(for: .unixExecutable)
        cache[bundleId] = generic
        return generic
    }
}
