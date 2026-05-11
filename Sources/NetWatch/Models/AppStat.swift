import Foundation

struct AppStat: Identifiable, Equatable, Hashable {
    var id: String { bundleId.isEmpty ? appName : bundleId }
    let bundleId: String
    let appName: String
    let bytesIn: Int64
    let bytesOut: Int64
    let rate: Double  // bytes/sec, last sample

    var total: Int64 { bytesIn + bytesOut }

    var formattedTotal: String {
        ByteCountFormatter.string(fromByteCount: total, countStyle: .binary)
    }
}

struct ConnectionStat: Identifiable, Equatable, Hashable {
    let id: String
    let host: String
    let port: Int
    let proto: String
    let sessionBytes: Int64
    let rate: Double  // bytes/sec

    /// "234 KB/min" — derived from instantaneous bytes/sec
    var formattedRate: String {
        let perMinute = Int64(rate * 60)
        if perMinute < 1024 { return "idle" }
        return ByteCountFormatter.string(fromByteCount: perMinute, countStyle: .binary) + "/min"
    }
}

extension Int64 {
    func formattedBytes() -> String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .binary)
    }
}

extension Double {
    func formattedRate() -> String {
        let bytes = Int64(self)
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary) + "/s"
    }
}
