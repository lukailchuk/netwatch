import SwiftUI
import AppKit

@main
struct NetWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var monitor: TrafficMonitor!
    private var menubarRefreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        _ = Database.shared
        monitor = TrafficMonitor.shared
        monitor.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            if let icon = NSImage(systemSymbolName: "network", accessibilityDescription: "NetWatch") {
                icon.isTemplate = true
                button.image = icon
                button.imagePosition = .imageLeading
                button.imageHugsTitle = true
            }
            button.title = " 0 B/s"
            button.font = NSFont.menuBarFont(ofSize: 0)
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 520)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenubarView()
                .environmentObject(monitor)
        )

        menubarRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateMenubarTitle()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Don't leave the user with frozen apps after we quit. Best-effort SIGCONT to anything we paused.
        AppController.resumeAllPaused()
        monitor?.stop()
    }

    private func updateMenubarTitle() {
        guard let button = statusItem.button else { return }
        button.title = " \(monitor.liveRate.formattedRate())"
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
