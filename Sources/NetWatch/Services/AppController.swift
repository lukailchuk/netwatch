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

/// SSTOP from <sys/proc.h>. Darwin module doesn't re-export it; stable since BSD.
private let kSSTOP: Int32 = 4
/// macOS UID convention: 0-99 system, 200 _developer, 500+ regular users.
/// Anything below is treated as system to block users from SIGSTOP'ing mDNSResponder/trustd etc.
private let kFirstUserUID: uid_t = 500

@MainActor
enum AppController {

    private static let log = Logger(subsystem: "io.netwatch", category: "process-control")

    /// Bundles currently in user-intended paused state, with the pids we actually SIGSTOP'd.
    /// Source of intent — kernel state (sysctl) is the source of truth for "is this pid stopped right now".
    /// We keep the pid set so `resumeAllPaused()` can find them at terminate time.
    private static var pausedTracker: [String: Set<pid_t>] = [:]

    // MARK: - Pause / Resume

    /// Pause an app's full process tree via SIGSTOP. Walks children (Browser Helper, GPU,
    /// renderers...) so the whole app freezes — otherwise the main GUI stays reactive until
    /// the first network call, then beachballs (confusing UX).
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
                    log.error("SIGSTOP pid=\(pid, privacy: .public) failed: errno=\(err)")
                }
            }
        }
        pausedTracker[bundleId, default: []].formUnion(stopped)
        TrafficMonitor.shared.setPaused(bundleId: bundleId, isPaused: true)
        log.info("paused \(bundleId, privacy: .public): \(stopped.count)/\(tree.count) pids")
    }

    /// Resume an app's process tree via SIGCONT. Unions current tree with previously-tracked
    /// pids in case children spawned/died between pause and resume.
    static func resume(bundleId: String, pids: Set<pid_t>) async {
        let tree = Self.processTree(rootPids: pids).union(pausedTracker[bundleId] ?? [])
        var sent = 0
        for pid in tree {
            if kill(pid, SIGCONT) == 0 {
                sent += 1
            } else {
                let err = errno
                if err != ESRCH {
                    log.error("SIGCONT pid=\(pid, privacy: .public) failed: errno=\(err)")
                }
            }
        }
        pausedTracker.removeValue(forKey: bundleId)
        TrafficMonitor.shared.setPaused(bundleId: bundleId, isPaused: false)
        log.info("resumed \(bundleId, privacy: .public): \(sent)/\(tree.count) pids")
    }

    /// Whether a bundle is in user-intended paused state. UI uses this for toggle rendering.
    static func isPausedBundle(_ bundleId: String) -> Bool {
        pausedTracker.keys.contains(bundleId)
    }

    /// Snapshot of (bundleId → tracked pids). Used to keep paused rows visible in UI
    /// after SIGSTOP'd apps stop emitting nettop traffic — otherwise the row disappears
    /// and the user has no Resume button.
    static func pausedBundlesSnapshot() -> [String: Set<pid_t>] {
        pausedTracker
    }

    /// Crash recovery: rebuild paused state when NetWatch restarted while apps were paused.
    /// Without this, paused apps stay frozen but invisible to the UI.
    static func recoverPausedState() {
        let procs = Self.allProcesses()
        guard !procs.isEmpty else { return }

        var recovered: [String: Set<pid_t>] = [:]
        for p in procs {
            let pid = p.kp_proc.p_pid
            guard pid > 0 else { continue }
            guard Int32(p.kp_proc.p_stat) == kSSTOP else { continue }
            guard p.kp_eproc.e_ucred.cr_uid >= kFirstUserUID else { continue }

            if let app = NSRunningApplication(processIdentifier: pid),
               let bundleId = app.bundleIdentifier {
                recovered[bundleId, default: []].insert(pid)
            }
        }

        guard !recovered.isEmpty else { return }
        for (bundleId, pids) in recovered {
            pausedTracker[bundleId, default: []].formUnion(pids)
            // Publish to UI immediately so recovered apps show up in Paused section.
            TrafficMonitor.shared.setPaused(bundleId: bundleId, isPaused: true)
        }
        log.info("recovered \(recovered.count) paused bundles after restart")
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
        // Keep pausedTracker.keys ≡ TrafficMonitor.pausedBundles invariant intact.
        TrafficMonitor.shared.pausedBundles.removeAll()
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

    // MARK: - Process introspection (sysctl(KERN_PROC))

    // Why sysctl over proc_pidinfo: PROC_PIDTBSDINFO returns nil for system processes
    // (UID < 500) without root, so isSystemProcess/isPaused gave false-negatives for
    // trustd, mDNSResponder, etc. — exactly the processes we need to detect to *protect*.
    // sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID) works for any pid without elevation.
    // Same path ps(1), top(1), Activity Monitor use.

    /// BFS down the process tree from the given root pids. One sysctl(KERN_PROC_ALL) call
    /// returns parent pid for every process — so the entire tree resolves in a single syscall.
    nonisolated static func processTree(rootPids: Set<pid_t>) -> Set<pid_t> {
        guard !rootPids.isEmpty else { return [] }
        let procs = Self.allProcesses()
        guard !procs.isEmpty else { return rootPids }

        var children: [pid_t: [pid_t]] = [:]
        for p in procs {
            let pid = p.kp_proc.p_pid
            guard pid > 0 else { continue }
            children[p.kp_eproc.e_ppid, default: []].append(pid)
        }

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

    nonisolated static func isSystemProcess(pid: pid_t) -> Bool {
        guard let info = Self.kinfoProc(pid: pid) else { return false }
        return info.kp_eproc.e_ucred.cr_uid < kFirstUserUID
    }

    nonisolated static func isPaused(pid: pid_t) -> Bool {
        guard let info = Self.kinfoProc(pid: pid) else { return false }
        return Int32(info.kp_proc.p_stat) == kSSTOP
    }

    /// Read `kinfo_proc` for a single pid. Works for any pid without root.
    nonisolated private static func kinfoProc(pid: pid_t) -> kinfo_proc? {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let nameCount = UInt32(name.count)
        var size = MemoryLayout<kinfo_proc>.stride
        var info = kinfo_proc()
        let result = name.withUnsafeMutableBufferPointer { buf -> Int32 in
            sysctl(buf.baseAddress, nameCount, &info, &size, nil, 0)
        }
        guard result == 0, size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        return info
    }

    /// Read all processes via single sysctl(KERN_PROC_ALL) call. Two-step pattern:
    /// first call to learn buffer size, second to fill. Standard BSD idiom.
    nonisolated private static func allProcesses() -> [kinfo_proc] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let nameCount = UInt32(name.count)
        var size: Int = 0
        let r1 = name.withUnsafeMutableBufferPointer { buf -> Int32 in
            sysctl(buf.baseAddress, nameCount, nil, &size, nil, 0)
        }
        guard r1 == 0, size > 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        let capacity = (size / stride) + 16  // small headroom — process count can change between calls
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * stride

        let r2 = name.withUnsafeMutableBufferPointer { buf -> Int32 in
            sysctl(buf.baseAddress, nameCount, &procs, &size, nil, 0)
        }
        guard r2 == 0 else { return [] }
        let actualCount = size / stride
        return Array(procs.prefix(actualCount))
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
