import Foundation
import AppKit

enum AppControllerError: LocalizedError {
    case appNotRunning
    case launchctlFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .appNotRunning:
            return "App is not currently running"
        case .launchctlFailed(let code):
            return "launchctl failed (exit \(code))"
        }
    }
}

@MainActor
enum AppController {

    /// Quit a GUI app gracefully via NSRunningApplication.terminate().
    /// Falls back to forceTerminate after 3s if the app didn't honor the request.
    static func quitApp(bundleId: String) async throws {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleId
        }) else {
            throw AppControllerError.appNotRunning
        }

        app.terminate()

        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if !app.isTerminated {
            app.forceTerminate()
        }
    }

    static func launchApp(at path: String) {
        let url = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }

    static func isAppRunning(bundleId: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleId
        }
    }

    /// Disable a user-domain launchd agent (e.g. com.apple.bird, com.apple.cloudphotod).
    /// Works without sudo for user agents. System daemons would need admin — out of v1 scope.
    static func disableUserLaunchAgent(label: String) -> Result<Void, AppControllerError> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                return .success(())
            }
            return .failure(.launchctlFailed(proc.terminationStatus))
        } catch {
            return .failure(.launchctlFailed(-1))
        }
    }

    /// Check if a launchd job is currently loaded in the user GUI domain.
    static func isLaunchAgentLoaded(label: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["print", "gui/\(getuid())/\(label)"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }
}
