import Foundation
import Combine
import AppKit
import os

enum Period: String, CaseIterable, Identifiable, Hashable {
    case session, today, week

    var id: String { rawValue }

    var label: String {
        switch self {
        case .session: return "Session"
        case .today: return "Today"
        case .week: return "Week"
        }
    }

    var breakdownTitle: String {
        switch self {
        case .session: return "Session — by app"
        case .today: return "Today — by app"
        case .week: return "Last 7 days — by app"
        }
    }

    var emptyMessage: String {
        switch self {
        case .session: return "No traffic this session yet"
        case .today: return "No traffic recorded today"
        case .week: return "No history this week"
        }
    }
}

/// Single shared sampler. One `nettop` process per tick (5s) emits both
/// per-process aggregates AND per-connection breakdowns — we parse both
/// in one pass. Drilldown views read existing state, no extra sampling.
@MainActor
final class TrafficMonitor: ObservableObject {
    static let shared = TrafficMonitor()

    nonisolated private static let log = Logger(subsystem: "io.netwatch", category: "traffic-monitor")

    @Published var liveRate: Double = 0       // total bytes/sec
    @Published var apps: [AppStat] = []        // sorted by rate DESC
    @Published var todayTotal: Int64 = 0
    @Published var weekTotal: Int64 = 0
    @Published var sessionTotal: Int64 = 0     // bytes since last reset
    @Published var connectionStats: [String: [ConnectionStat]] = [:]

    /// SSoT for "is this bundle paused right now". Mirrors AppController.pausedTracker.keys.
    /// AppController.pause/resume are the only writers (via setPaused). UI is pure reader.
    /// Sample loop NEVER touches this — separation prevents race between snapshot timing and user intent.
    @Published var pausedBundles: Set<String> = []

    // Delta tracking (cumulative counters from nettop, used for diff between samples)
    private var lastAppSnapshot: [String: (bytesIn: Int64, bytesOut: Int64)] = [:]
    private var lastConnSnapshot: [String: [String: (bytesIn: Int64, bytesOut: Int64)]] = [:]

    // Session accumulators (since app start or last resetSession())
    private var sessionAppBytes: [String: Int64] = [:]
    private var sessionConnBytes: [String: [String: Int64]] = [:]

    /// When false, parser skips the (expensive) per-connection rows entirely —
    /// they account for ~80% of nettop output volume in default mode.
    /// UI flips this to true while any app row is expanded.
    var drilldownActive: Bool = false

    private var sampleTimer: Timer?
    private var lastSampleAt: Date = Date()
    private let sampleInterval: TimeInterval = 7

    private init() {}

    func start() {
        startSampleLoop()
        refreshStats()
    }

    func stop() {
        sampleTimer?.invalidate()
    }

    /// Trigger a sample immediately (don't wait for the next 7s tick).
    /// Called after pause/resume/kill actions so the UI reflects state within ~1-2s
    /// (nettop's own sample window) instead of the full sample interval.
    func tickNow() {
        runSampleAsync()
    }

    /// Optimistic UI flip — apply isPaused to the matching row immediately.
    /// Sample loop will confirm with kernel state within 1-2s, but UI doesn't wait.
    /// If bundleId isn't in self.apps yet (paused before any traffic recorded),
    /// synthesize a row from AppController.pausedBundlesSnapshot + NSRunningApplication name.
    /// SSoT mutation point for paused state. Called by AppController.pause/resume.
    /// Mutates @Published Set → SwiftUI re-renders within a frame. No AppStat copy magic,
    /// no race with sample loop — sample loop never reads/writes this Set.
    /// Also synthesizes a stub AppStat row if bundleId isn't in self.apps yet
    /// (paused fast after launch, no traffic recorded).
    func setPaused(bundleId: String, isPaused: Bool) {
        if isPaused {
            pausedBundles.insert(bundleId)
            Self.log.info("[setPaused] inserted \(bundleId, privacy: .public), set size=\(self.pausedBundles.count, privacy: .public)")

            // Make sure UI has a row for this bundle even if it wasn't in DB/sample.
            if !apps.contains(where: { $0.bundleId == bundleId }) {
                let trackedPids = AppController.pausedBundlesSnapshot()[bundleId] ?? []
                let appName = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                    .first?.localizedName ?? bundleId
                apps.append(AppStat(
                    bundleId: bundleId,
                    appName: appName,
                    bytesIn: 0, bytesOut: 0, rate: 0,
                    pids: trackedPids,
                    isSystem: trackedPids.first.map { AppController.isSystemProcess(pid: $0) } ?? false
                ))
                Self.log.info("[setPaused] synthesized AppStat for \(bundleId, privacy: .public)")
            }
        } else {
            pausedBundles.remove(bundleId)
            Self.log.info("[setPaused] removed \(bundleId, privacy: .public), set size=\(self.pausedBundles.count, privacy: .public)")
        }
    }

    func resetSession() {
        sessionAppBytes.removeAll()
        sessionConnBytes.removeAll()
        sessionTotal = 0
        connectionStats.removeAll()
        refreshStats()
    }

    // MARK: - Period queries

    func totalForPeriod(_ period: Period) -> Int64 {
        switch period {
        case .session: return sessionTotal
        case .today: return todayTotal
        case .week: return weekTotal
        }
    }

    /// Per-app breakdown for a given period. Session derives from in-memory
    /// session accumulators; Today reuses the live `apps` array; Week hits the DB.
    func appsForPeriod(_ period: Period) -> [PeriodApp] {
        switch period {
        case .session:
            let nameByBundle = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleId, $0.appName) })
            return sessionAppBytes
                .filter { $0.value > 0 }
                .map { bundleId, bytes in
                    PeriodApp(
                        bundleId: bundleId,
                        appName: nameByBundle[bundleId] ?? bundleId,
                        total: bytes
                    )
                }
                .sorted { $0.total > $1.total }
        case .today:
            return apps
                .filter { $0.total > 0 }
                .map { PeriodApp(bundleId: $0.bundleId, appName: $0.appName, total: $0.total) }
                .sorted { $0.total > $1.total }
        case .week:
            return Database.shared.getAppTotalsForWeek()
        }
    }

    // MARK: - Sample loop

    private func startSampleLoop() {
        runSampleAsync()
        sampleTimer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runSampleAsync()
            }
        }
    }

    private func runSampleAsync() {
        Task.detached(priority: .utility) { [weak self] in
            let output = Self.captureNettopSample()
            await MainActor.run {
                self?.ingestNettopData(output)
            }
        }
    }

    /// Single-shot nettop in DEFAULT mode (no -P) — emits both process aggregates
    /// AND per-connection rows nested under them.
    nonisolated private static func captureNettopSample() -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        proc.arguments = [
            "-x",                       // machine-readable (no curses)
            "-t", "external",           // skip loopback
            "-s", "1",                  // 1s sample window
            "-L", "1",                  // one sample then exit
            "-J", "bytes_in,bytes_out"  // only columns we need
        ]
        let outputPipe = Pipe()
        proc.standardOutput = outputPipe
        proc.standardError = Pipe()

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            Self.log.error("nettop spawn failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Parse

    private func ingestNettopData(_ chunk: String) {
        let lines = chunk.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        // Aggregates we build during this sample, then diff against lastSnapshots.
        var appSample: [String: (bytesIn: Int64, bytesOut: Int64, name: String, pids: Set<Int32>)] = [:]
        var connSample: [String: [String: (bytesIn: Int64, bytesOut: Int64, port: Int, proto: String)]] = [:]
        var currentBundleId: String?

        for line in lines where !line.isEmpty {
            if line.lowercased().contains("bytes_in") { continue }  // header line
            // nettop -x -L 1 -J bytes_in,bytes_out emits TERSE 4-field rows:
            //   nameOrConn, bytes_in, bytes_out, <empty trailing>
            // where nameOrConn is either "ProcessName.PID" or "tcp4 ip<->host:port".
            // Connection rows are detected by protocol prefix in nameOrConn.
            let parts = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }

            let nameOrConn = parts[0]
            let bytesInStr = parts[1]
            let bytesOutStr = parts[2]

            guard let bytesIn = Int64(bytesInStr.trimmingCharacters(in: .whitespaces)),
                  let bytesOut = Int64(bytesOutStr.trimmingCharacters(in: .whitespaces))
            else { continue }

            let isConnRow = nameOrConn.hasPrefix("tcp") || nameOrConn.hasPrefix("udp") || nameOrConn.hasPrefix("quic")

            // Fast path: when no app row is expanded, the per-host drilldown is
            // invisible — skip the expensive connection rows entirely.
            if isConnRow && !drilldownActive { continue }

            if !isConnRow {
                // Process aggregate row
                let (cleanName, pid) = splitNameAndPID(from: nameOrConn.trimmingCharacters(in: .whitespaces))
                guard !cleanName.isEmpty, cleanName != "nettop" else {
                    currentBundleId = nil
                    continue
                }
                let (bundleId, displayName) = resolveParentApp(processName: cleanName)
                currentBundleId = bundleId

                // Aggregate (helper procs roll into parent here, all pids accumulated)
                if var existing = appSample[bundleId] {
                    existing.bytesIn += bytesIn
                    existing.bytesOut += bytesOut
                    if let pid { existing.pids.insert(pid) }
                    appSample[bundleId] = existing
                } else {
                    var pids: Set<Int32> = []
                    if let pid { pids.insert(pid) }
                    appSample[bundleId] = (bytesIn, bytesOut, displayName, pids)
                }
            } else {
                // Connection row under the most recent process header
                guard let bundleId = currentBundleId else { continue }
                guard let conn = parseConnEndpoint(nameOrConn) else { continue }

                let key = "\(conn.host):\(conn.port)"
                var hostMap = connSample[bundleId] ?? [:]
                if var existing = hostMap[key] {
                    existing.bytesIn += bytesIn
                    existing.bytesOut += bytesOut
                    hostMap[key] = existing
                } else {
                    hostMap[key] = (bytesIn, bytesOut, conn.port, conn.proto)
                }
                connSample[bundleId] = hostMap
            }
        }

        processSnapshot(appSample: appSample, connSample: connSample)
    }

    private struct ParsedEndpoint {
        let host: String
        let port: Int
        let proto: String
    }

    /// Parses "tcp4 192.168.0.1:63325<->host.example.com:443" → remote endpoint.
    /// Skips wildcards (e.g. "udp6 *.5353<->*.*") — those aren't real flows.
    private func parseConnEndpoint(_ s: String) -> ParsedEndpoint? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let protoSplit = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard protoSplit.count == 2 else { return nil }
        let proto = protoSplit[0]
        let endpoints = protoSplit[1].components(separatedBy: "<->")
        guard endpoints.count == 2 else { return nil }

        let remote = endpoints[1]
        if remote.contains("*") { return nil }

        // IPv6 addrs contain colons → use LAST colon as port separator
        guard let lastColon = remote.lastIndex(of: ":") else { return nil }
        let portStr = String(remote[remote.index(after: lastColon)...])
        guard let port = Int(portStr) else { return nil }

        var host = String(remote[..<lastColon])
        // Strip IPv6 brackets if any, or zone IDs (".en0")
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let pctIdx = host.firstIndex(of: "%") {
            host = String(host[..<pctIdx])
        }
        return ParsedEndpoint(host: host, port: port, proto: proto)
    }

    /// nettop format "ProcessName.PID" → (name, pid). Returns (raw, nil) if no numeric suffix.
    private func splitNameAndPID(from raw: String) -> (name: String, pid: Int32?) {
        if let dotIdx = raw.lastIndex(of: ".") {
            let suffix = String(raw[raw.index(after: dotIdx)...])
            if let pid = Int32(suffix) {
                return (String(raw[..<dotIdx]), pid)
            }
        }
        return (raw, nil)
    }

    /// Walks the executable path up to the outermost .app bundle. Helper
    /// sub-processes (Browser Helper, GPU Process) roll up under parent app.
    private func resolveParentApp(processName: String) -> (bundleId: String, displayName: String) {
        for app in NSWorkspace.shared.runningApplications {
            let nameMatches = app.localizedName == processName
            let exeMatches = app.executableURL?.lastPathComponent == processName
            guard nameMatches || exeMatches, let exePath = app.executableURL?.path else { continue }

            let pathComponents = exePath.split(separator: "/").map(String.init)
            var outermostAppPath: String?
            var partial = ""
            for component in pathComponents {
                partial += "/" + component
                if component.hasSuffix(".app") {
                    outermostAppPath = partial
                    break
                }
            }

            if let parentPath = outermostAppPath,
               let bundle = Bundle(path: parentPath),
               let parentBundleId = bundle.bundleIdentifier {
                let displayName = (bundle.infoDictionary?["CFBundleName"] as? String)
                    ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (parentPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
                return (parentBundleId, displayName)
            }
            return (app.bundleIdentifier ?? processName, app.localizedName ?? processName)
        }
        return (processName, processName)
    }

    // MARK: - Delta computation

    private func processSnapshot(
        appSample: [String: (bytesIn: Int64, bytesOut: Int64, name: String, pids: Set<Int32>)],
        connSample: [String: [String: (bytesIn: Int64, bytesOut: Int64, port: Int, proto: String)]]
    ) {
        let now = Date()
        let timeDelta = now.timeIntervalSince(lastSampleAt)
        var totalDeltaBytes: Int64 = 0
        var appRates: [String: Double] = [:]
        var appPids: [String: Set<Int32>] = [:]
        var appSystem: [String: Bool] = [:]

        // Per-app deltas → DB + session + rate
        for (bundleId, data) in appSample {
            appPids[bundleId] = data.pids

            // Auto-pause any new pids that spawned under a bundle the user already paused.
            // Cheap when bundle isn't in paused intent (early-return inside).
            AppController.reconcilePausedBundle(bundleId, currentPids: data.pids)

            // Read system flag from kernel — UID won't change at runtime, one probe is enough.
            // We DON'T probe paused state here — that's owned by self.pausedBundles via AppController.
            if let probePid = data.pids.first {
                appSystem[bundleId] = AppController.isSystemProcess(pid: probePid)
            }

            if let prev = lastAppSnapshot[bundleId] {
                let deltaIn = max(0, data.bytesIn - prev.bytesIn)
                let deltaOut = max(0, data.bytesOut - prev.bytesOut)
                let delta = deltaIn + deltaOut

                if delta > 0 {
                    Database.shared.recordDelta(
                        bundleId: bundleId,
                        appName: data.name,
                        deltaIn: deltaIn,
                        deltaOut: deltaOut
                    )
                    sessionAppBytes[bundleId, default: 0] += delta
                    totalDeltaBytes += delta
                }
                appRates[bundleId] = timeDelta > 0 ? Double(delta) / timeDelta : 0
            }
            lastAppSnapshot[bundleId] = (data.bytesIn, data.bytesOut)
        }

        // Per-connection deltas → session + rate (no DB persistence)
        var newConnStats: [String: [ConnectionStat]] = [:]
        for (bundleId, hostMap) in connSample {
            let prevHosts = lastConnSnapshot[bundleId] ?? [:]
            var newPrev: [String: (bytesIn: Int64, bytesOut: Int64)] = [:]
            var stats: [ConnectionStat] = []

            for (key, data) in hostMap {
                let prev = prevHosts[key] ?? (0, 0)
                let delta = max(0, (data.bytesIn + data.bytesOut) - (prev.bytesIn + prev.bytesOut))

                if delta > 0 {
                    sessionConnBytes[bundleId, default: [:]][key, default: 0] += delta
                }

                let host = String(key.split(separator: ":").dropLast().joined(separator: ":"))
                let sessionBytes = sessionConnBytes[bundleId]?[key] ?? 0
                let rate = timeDelta > 0 ? Double(delta) / timeDelta : 0

                // Only show connections that have any session activity OR current rate.
                if sessionBytes > 0 || rate > 0 {
                    stats.append(ConnectionStat(
                        id: "\(bundleId)|\(key)",
                        host: host,
                        port: data.port,
                        proto: data.proto,
                        sessionBytes: sessionBytes,
                        rate: rate
                    ))
                }
                newPrev[key] = (data.bytesIn, data.bytesOut)
            }
            lastConnSnapshot[bundleId] = newPrev
            newConnStats[bundleId] = stats.sorted { $0.rate > $1.rate || ($0.rate == $1.rate && $0.sessionBytes > $1.sessionBytes) }
        }

        // Publish UI state
        self.liveRate = timeDelta > 0 ? Double(totalDeltaBytes) / timeDelta : 0
        self.lastSampleAt = now
        self.connectionStats = newConnStats
        self.sessionTotal = sessionAppBytes.values.reduce(0, +)

        // SIGSTOP'd processes stop emitting traffic → disappear from nettop's next sample.
        // Patch their pids back into the snapshot so the row stays in self.apps and the user
        // can click Resume. Paused state itself lives in self.pausedBundles, NOT here.
        let pausedSnapshot = AppController.pausedBundlesSnapshot()
        for (bundleId, trackedPids) in pausedSnapshot {
            if appPids[bundleId] == nil { appPids[bundleId] = trackedPids }
            if appSystem[bundleId] == nil, let probe = trackedPids.first {
                appSystem[bundleId] = AppController.isSystemProcess(pid: probe)
            }
        }

        refreshAppsFromDB(rates: appRates, pids: appPids, system: appSystem)
        Self.log.info("[snapshot] sample done: appSample=\(appSample.count, privacy: .public) pausedBundles=\(self.pausedBundles.count, privacy: .public) self.apps=\(self.apps.count, privacy: .public)")
    }

    /// Reloads `apps` from DB and applies current rates + pids + system flag + sort by rate DESC.
    /// Builds a [bundleId: AppStat] dictionary first, then converts to array — guarantees no
    /// duplicates by construction. Paused state is NOT here — it lives in self.pausedBundles.
    private func refreshAppsFromDB(
        rates: [String: Double],
        pids: [String: Set<Int32>],
        system: [String: Bool]
    ) {
        let stats = Database.shared.getTodayStats()
        let week = Database.shared.getWeeklyTotals()

        var byBundle: [String: AppStat] = [:]

        // Seed from DB (today's history).
        for existing in stats {
            byBundle[existing.bundleId] = AppStat(
                bundleId: existing.bundleId,
                appName: existing.appName,
                bytesIn: existing.bytesIn,
                bytesOut: existing.bytesOut,
                rate: rates[existing.bundleId] ?? 0,
                pids: pids[existing.bundleId] ?? [],
                isSystem: system[existing.bundleId] ?? false
            )
        }

        // Inject paused bundles that DB doesn't yet know about (paused fast after launch, no traffic recorded).
        for (bundleId, trackedPids) in AppController.pausedBundlesSnapshot() where byBundle[bundleId] == nil {
            let appName = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                .first?.localizedName ?? bundleId
            byBundle[bundleId] = AppStat(
                bundleId: bundleId,
                appName: appName,
                bytesIn: 0,
                bytesOut: 0,
                rate: 0,
                pids: trackedPids,
                isSystem: trackedPids.first.map { AppController.isSystemProcess(pid: $0) } ?? false
            )
        }

        self.apps = Array(byBundle.values).sorted {
            // Active (rate > 0) на верх, далі by session bytes, далі by today total
            if $0.rate != $1.rate { return $0.rate > $1.rate }
            let s0 = sessionAppBytes[$0.bundleId] ?? 0
            let s1 = sessionAppBytes[$1.bundleId] ?? 0
            if s0 != s1 { return s0 > s1 }
            return $0.total > $1.total
        }

        self.todayTotal = stats.reduce(Int64(0)) { $0 + $1.total }
        self.weekTotal = week.reduce(Int64(0)) { $0 + $1.total }
        Self.log.info("[refresh] published self.apps count=\(self.apps.count, privacy: .public) pausedBundles=\(self.pausedBundles.count, privacy: .public)")
    }

    private func refreshStats() {
        refreshAppsFromDB(rates: [:], pids: [:], system: [:])
    }
}
