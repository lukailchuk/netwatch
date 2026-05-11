import Foundation
import Combine
import AppKit

/// Single shared sampler. One `nettop` process per tick (5s) emits both
/// per-process aggregates AND per-connection breakdowns — we parse both
/// in one pass. Drilldown views read existing state, no extra sampling.
@MainActor
final class TrafficMonitor: ObservableObject {
    static let shared = TrafficMonitor()

    @Published var liveRate: Double = 0       // total bytes/sec
    @Published var apps: [AppStat] = []        // sorted by rate DESC
    @Published var todayTotal: Int64 = 0
    @Published var weekTotal: Int64 = 0
    @Published var sessionTotal: Int64 = 0     // bytes since last reset
    @Published var connectionStats: [String: [ConnectionStat]] = [:]

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

    func resetSession() {
        sessionAppBytes.removeAll()
        sessionConnBytes.removeAll()
        sessionTotal = 0
        connectionStats.removeAll()
        refreshStats()
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
            print("[TrafficMonitor] nettop spawn failed: \(error)")
            return ""
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Parse

    private func ingestNettopData(_ chunk: String) {
        let lines = chunk.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        // Aggregates we build during this sample, then diff against lastSnapshots.
        var appSample: [String: (bytesIn: Int64, bytesOut: Int64, name: String)] = [:]
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
                let cleanName = stripPID(from: nameOrConn.trimmingCharacters(in: .whitespaces))
                guard !cleanName.isEmpty, cleanName != "nettop" else {
                    currentBundleId = nil
                    continue
                }
                let (bundleId, displayName) = resolveParentApp(processName: cleanName)
                currentBundleId = bundleId

                // Aggregate (helper procs roll into parent here)
                if var existing = appSample[bundleId] {
                    existing.bytesIn += bytesIn
                    existing.bytesOut += bytesOut
                    appSample[bundleId] = existing
                } else {
                    appSample[bundleId] = (bytesIn, bytesOut, displayName)
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

    private func stripPID(from raw: String) -> String {
        if let dotIdx = raw.lastIndex(of: ".") {
            let suffix = raw[raw.index(after: dotIdx)...]
            if Int(suffix) != nil { return String(raw[..<dotIdx]) }
        }
        return raw
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
        appSample: [String: (bytesIn: Int64, bytesOut: Int64, name: String)],
        connSample: [String: [String: (bytesIn: Int64, bytesOut: Int64, port: Int, proto: String)]]
    ) {
        let now = Date()
        let timeDelta = now.timeIntervalSince(lastSampleAt)
        var totalDeltaBytes: Int64 = 0
        var appRates: [String: Double] = [:]

        // Per-app deltas → DB + session + rate
        for (bundleId, data) in appSample {
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

        refreshAppsFromDB(rates: appRates)
    }

    /// Reloads `apps` from DB and applies current rates + sort by rate DESC.
    private func refreshAppsFromDB(rates: [String: Double]) {
        let stats = Database.shared.getTodayStats()
        let week = Database.shared.getWeeklyTotals()

        self.apps = stats.map { existing in
            AppStat(
                bundleId: existing.bundleId,
                appName: existing.appName,
                bytesIn: existing.bytesIn,
                bytesOut: existing.bytesOut,
                rate: rates[existing.bundleId] ?? 0
            )
        }.sorted {
            // Active (rate > 0) на верх, далі by session bytes, далі by today total
            if $0.rate != $1.rate { return $0.rate > $1.rate }
            let s0 = sessionAppBytes[$0.bundleId] ?? 0
            let s1 = sessionAppBytes[$1.bundleId] ?? 0
            if s0 != s1 { return s0 > s1 }
            return $0.total > $1.total
        }

        self.todayTotal = stats.reduce(Int64(0)) { $0 + $1.total }
        self.weekTotal = week.reduce(Int64(0)) { $0 + $1.total }
    }

    private func refreshStats() {
        refreshAppsFromDB(rates: [:])
    }
}
