import SwiftUI

/// Sub-rows shown under an expanded app row. Lists the top-5 destinations
/// for that app, sorted by current rate. Reads state populated by
/// TrafficMonitor's single sampler — no extra sampling here.
struct ConnectionsListView: View {
    let bundleId: String
    @EnvironmentObject var monitor: TrafficMonitor

    private var connections: [ConnectionStat] {
        let all = monitor.connectionStats[bundleId] ?? []
        return Array(all.prefix(5))
    }

    var body: some View {
        VStack(spacing: 2) {
            if connections.isEmpty {
                HStack {
                    Image(systemName: "moon.zzz")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("No active connections")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.leading, 46)
                .padding(.trailing, 12)
                .padding(.vertical, 4)
            } else {
                ForEach(connections) { conn in
                    row(conn)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func row(_ conn: ConnectionStat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: conn.rate > 0 ? "arrow.up.right.circle.fill" : "arrow.up.right.circle")
                .font(.caption2)
                .foregroundColor(conn.rate > 0 ? .orange : .secondary)

            VStack(alignment: .leading, spacing: 0) {
                Text(conn.host)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(":\(conn.port) · \(conn.proto)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 0) {
                Text(conn.formattedRate)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(conn.rate > 0 ? .orange : .secondary)
                Text(conn.sessionBytes.formattedBytes())
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.leading, 46)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
    }
}
