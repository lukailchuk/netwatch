import Foundation
import SQLite3

final class Database: @unchecked Sendable {
    static let shared = Database()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "netwatch.db", qos: .utility)
    private let path: String

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("NetWatch")

        try? FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true
        )

        self.path = appSupport.appendingPathComponent("stats.sqlite").path

        if sqlite3_open(path, &db) != SQLITE_OK {
            print("[Database] Cannot open at \(path)")
            return
        }

        bootstrapSchema()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func bootstrapSchema() {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS daily_aggregates (
                date TEXT NOT NULL,
                bundle_id TEXT NOT NULL,
                app_name TEXT NOT NULL,
                bytes_in INTEGER NOT NULL DEFAULT 0,
                bytes_out INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (date, bundle_id)
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_daily_date ON daily_aggregates(date)"
        ]
        for sql in statements {
            runStatement(sql)
        }
    }

    private func runStatement(_ sql: String) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    /// Record a delta of bytes for an app on a specific date.
    func recordDelta(bundleId: String, appName: String, deltaIn: Int64, deltaOut: Int64) {
        queue.async {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let date = formatter.string(from: Date())

            let sql = """
                INSERT INTO daily_aggregates (date, bundle_id, app_name, bytes_in, bytes_out)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(date, bundle_id) DO UPDATE SET
                    bytes_in = bytes_in + excluded.bytes_in,
                    bytes_out = bytes_out + excluded.bytes_out,
                    app_name = excluded.app_name;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, (date as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (bundleId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (appName as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 4, deltaIn)
            sqlite3_bind_int64(stmt, 5, deltaOut)
            sqlite3_step(stmt)
        }
    }

    func getTodayStats() -> [AppStat] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return getDayStats(date: formatter.string(from: Date()))
    }

    func getDayStats(date: String) -> [AppStat] {
        var results: [AppStat] = []
        queue.sync {
            let sql = """
                SELECT bundle_id, app_name, bytes_in, bytes_out
                FROM daily_aggregates
                WHERE date = ?
                ORDER BY (bytes_in + bytes_out) DESC
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, (date as NSString).utf8String, -1, nil)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let bundleId = String(cString: sqlite3_column_text(stmt, 0))
                let appName = String(cString: sqlite3_column_text(stmt, 1))
                let bytesIn = sqlite3_column_int64(stmt, 2)
                let bytesOut = sqlite3_column_int64(stmt, 3)
                results.append(AppStat(
                    bundleId: bundleId,
                    appName: appName,
                    bytesIn: bytesIn,
                    bytesOut: bytesOut,
                    rate: 0,         // injected later by TrafficMonitor.refreshAppsFromDB
                    pids: [],        // injected later by TrafficMonitor.refreshAppsFromDB
                    isSystem: false  // injected later by TrafficMonitor.refreshAppsFromDB
                ))
            }
        }
        return results
    }

    func getAppTotalsForWeek() -> [PeriodApp] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        var dates: [String] = []
        for i in (0..<7).reversed() {
            if let d = calendar.date(byAdding: .day, value: -i, to: Date()) {
                dates.append(formatter.string(from: d))
            }
        }
        guard !dates.isEmpty else { return [] }

        var results: [PeriodApp] = []
        queue.sync {
            let placeholders = dates.map { _ in "?" }.joined(separator: ",")
            let sql = """
                SELECT bundle_id, MAX(app_name) AS name, SUM(bytes_in + bytes_out) AS total
                FROM daily_aggregates
                WHERE date IN (\(placeholders))
                GROUP BY bundle_id
                ORDER BY total DESC
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

            for (i, date) in dates.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), (date as NSString).utf8String, -1, nil)
            }

            while sqlite3_step(stmt) == SQLITE_ROW {
                let bundleId = String(cString: sqlite3_column_text(stmt, 0))
                let appName = String(cString: sqlite3_column_text(stmt, 1))
                let total = sqlite3_column_int64(stmt, 2)
                results.append(PeriodApp(bundleId: bundleId, appName: appName, total: total))
            }
        }
        return results
    }

    func getWeeklyTotals() -> [(date: String, total: Int64)] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        var dates: [String] = []
        for i in (0..<7).reversed() {
            if let d = calendar.date(byAdding: .day, value: -i, to: Date()) {
                dates.append(formatter.string(from: d))
            }
        }

        var results: [(date: String, total: Int64)] = []
        queue.sync {
            for date in dates {
                let sql = """
                    SELECT COALESCE(SUM(bytes_in + bytes_out), 0)
                    FROM daily_aggregates
                    WHERE date = ?
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, (date as NSString).utf8String, -1, nil)
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        results.append((date: date, total: sqlite3_column_int64(stmt, 0)))
                    }
                }
                sqlite3_finalize(stmt)
            }
        }
        return results
    }
}
