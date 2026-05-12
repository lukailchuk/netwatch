import Foundation
import AppKit
import Darwin
import os

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

/// SSTOP constant from <sys/proc.h>. Swift's Darwin module doesn't re-export it,
/// so we mirror the kernel value here. Stable since BSD; checked against macOS 14/15/26.
private let kProcStatusStopped: UInt32 = 4

@MainActor
enum AppController {

    private static let log = Logger(subsystem: "io.netwatch", category: "process-control")

    /// Bundles currently in user-intended paused state, with the pids we actually SIGSTOP'd.
    /// Source of intent — kernel state (sysctl) is the source of truth for "is this pid stopped right now".
    /// We keep the pid set so `resumeAllPaused()` can find them at terminate time.
    private static var pausedTracker: [String: Set<pid_t>] = [:]

    // MARK: - Pause / Resume

    /// Pause an app's full process tree via SIGSTOP.
    /// Walks down through children (Browser Helper, GPU process, renderers...) so the whole app
    /// freezes — not just the network-talking pids. Otherwise main GUI stays reactive until the
    /// first network call, then beachballs (confusing UX).
    static func pause(bundleId: String, pids: Set<pid_t>) async {
        let tree = Self.processTree(rootPids: pids)
        guard !tree.isEmpty else {
            log.warning("pause(\(bundleId, privacy: .public)): empty pid tree, nothing to do")
            return
        }

        var stopped: Set<pid_t> = []
        for pid in tree {
            if kill(pid, SIGSTOP) == 0 {
                stopped.insert(pid)
            } else {
                let err = errno
                if err != ESRCH {
                    log.error("SIGSTOP pid=\(pid, privacy: .public) failed: errno=\(err) (\(String(cString: strerror(err)), privacy: .public))")
                }
            }
        }
        pausedTracker[bundleId, default: []].formUnion(stopped)
        log.info("paused \(bundleId, privacy: .public): \(stopped.count) pids")
    }

    /// Resume an app's process tree via SIGCONT.
    /// Unions current tree with previously-tracked pids in case some children spawned/died between pause and resume.
    static func resume(bundleId: String, pids: Set<pid_t>) async {
        let tree = Self.processTree(rootPids: pids).union(pausedTracker[bundleId] ?? [])
        for pid in tree {
            if kill(pid, SIGCONT) != 0 {
                let err = errno
                if err != ESRCH {
                    log.error("SIGCONT pid=\(pid, privacy: .public) failed: errno=\(err) (\(String(cString: strerror(err)), privacy: .public))")
                }
            }
        }
        pausedTracker.removeValue(forKey: bundleId)
        log.info("resumed \(bundleId, privacy: .public): \(tree.count) pids")
    }

    /// Whether a bundle is in user-intended paused state. UI uses this for toggle rendering.
    static func isPausedBundle(_ bundleId: String) -> Bool {
        pausedTracker.keys.contains(bundleId)
    }

    /// Resume every process we ever paused. Called from `applicationWillTerminate` so the user
    /// doesn't quit NetWatch and find Arc/Spotify/etc. still frozen with no way to recover.
    static func resumeAllPaused() {
        for (bundleId, pids) in pausedTracker {
            for pid in pids {
                _ = kill(pid, SIGCONT)  // best-effort, ignore errors at shutdown
            }
            log.info("terminate-resume \(bundleId, privacy: .public): \(pids.count) pids")
        }
        pausedTracker.removeAll()
    }

    /// Auto-pause newly-spawned pids belonging to a bundle that's already in paused intent.
    /// Called by TrafficMonitor each sample so children spawned after pause don't slip through.
    static func reconcilePausedBundle(_ bundleId: String, currentPids: Set<pid_t>) {
        guard pausedTracker.keys.contains(bundleId) else { return }
        let known = pausedTracker[bundleId] ?? []
        let tree = Self.processTree(rootPids: currentPids)
        let newcomers = tree.subtracting(known)
        guard !newcomers.isEmpty else { return }

        var stopped: Set<pid_t> = []
        for pid in newcomers where Self.isPaused(pid: pid) == false {
            if kill(pid, SIGSTOP) == 0 {
                stopped.insert(pid)
            }
        }
        pausedTracker[bundleId]?.formUnion(stopped)
        if !stopped.isEmpty {
            log.info("reconcile \(bundleId, privacy: .public): paused \(stopped.count) new pids")
        }
    }

    // MARK: - Process introspection (libproc + sysctl)

    /// BFS down the process tree from the given root pids. Apple's `proc_listpids` + per-pid
    /// `proc_pidinfo(PROC_PIDTBSDINFO)` — same approach Activity Monitor uses internally.
    nonisolated static func processTree(rootPids: Set<pid_t>) -> Set<pid_t> {
        guard !rootPids.isEmpty else { return [] }

        let bytesNeeded = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytesNeeded > 0 else { return rootPids }

        let pidCapacity = Int(bytesNeeded) / MemoryLayout<pid_t>.size
        var allPids = [pid_t](repeating: 0, count: pidCapacity)
        let actualBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &allPids, bytesNeeded)
        guard actualBytes > 0 else { return rootPids }
        let actualCount = Int(actualBytes) / MemoryLayout<pid_t>.size

        // Build parent → children map in one pass. O(N) where N ~ 500 on a typical Mac.
        var children: [pid_t: [pid_t]] = [:]
        for i in 0..<actualCount {
            let pid = allPids[i]
            guard pid > 0, let ppid = Self.parentPid(of: pid) else { continue }
            children[ppid, default: []].append(pid)
        }

        // BFS from every root.
        var result = rootPids
        var queue = Array(rootPids)
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            for child in children[parent] ?? [] where !result.contains(child) {
                result.insert(child)
                queue.append(child)
            }
        }
        return result
    }

    /// macOS UID convention: 0-99 system services, 200 _developer, 500+ regular users.
    /// We treat anything < 500 as system to prevent users from SIGSTOP'ing mDNSResponder etc.
    nonisolated static func isSystemProcess(pid: pid_t) -> Bool {
        guard let info = Self.bsdInfo(of: pid) else { return false }
        return info.pbi_uid < 500
    }

    /// Reads `kp_proc.p_stat` via `proc_pidinfo`. Returns true iff the process is in SSTOP state.
    /// Source of truth — kernel; we never trust an in-memory mirror.
    nonisolated static func isPaused(pid: pid_t) -> Bool {
        guard let info = Self.bsdInfo(of: pid) else { return false }
        return info.pbi_status == kProcStatusStopped
    }

    nonisolated private static func parentPid(of pid: pid_t) -> pid_t? {
        guard let info = Self.bsdInfo(of: pid) else { return nil }
        return pid_t(info.pbi_ppid)
    }

    nonisolated private static func bsdInfo(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard result == size else { return nil }
        return info
    }

    // MARK: - Kill (existing, retained for × secondary action and TravelMode)

    /// Universal kill for any process(es) — works for GUI apps, helpers, daemons, CLI tools.
    /// Strategy:
    ///   1. If bundleId resolves to a GUI app → graceful NSRunningApplication.terminate() (lets app save state).
    ///   2. SIGTERM all pids in parallel.
    ///   3. Wait 3s, then SIGKILL anything still alive.
    /// Permission denied (EPERM) for system daemons is logged, not thrown — kernel guards them.
    static func killProcesses(pids: Set<Int32>, bundleId: String?) async {
        if let bundleId,
           let guiApp = NSWorkspace.shared.runningApplications.first(where: {
               $0.bundleIdentifier == bundleId
           }) {
            guiApp.terminate()
        }

        guard !pids.isEmpty else { return }

        for pid in pids {
            if kill(pid, SIGTERM) != 0 {
                let err = errno
                if err != ESRCH {
                    log.error("SIGTERM pid=\(pid, privacy: .public) failed: errno=\(err) (\(String(cString: strerror(err)), privacy: .public))")
                }
            }
        }

        try? await Task.sleep(nanoseconds: 3_000_000_000)

        for pid in pids where kill(pid, 0) == 0 {
            if kill(pid, SIGKILL) != 0 {
                let err = errno
                if err != ESRCH {
                    log.error("SIGKILL pid=\(pid, privacy: .public) failed: errno=\(err) (\(String(cString: strerror(err)), privacy: .public))")
                }
            }
        }
    }

    // MARK: - Legacy (TravelMode integration)

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
