import SwiftUI

struct ConnectionsListView: View {
    let bundleId: String
    @EnvironmentObject var monitor: TrafficMonitor

    private var connections: [ConnectionStat] {
        let all = monitor.connectionStats[bundleId] ?? []
        return Array(all.prefix(5))
    }

    var body: some View {
        VStack(spacing: 1) {
            if connections.isEmpty {
                emptyRow
            } else {
                ForEach(connections) { conn in
                    row(conn)
                }
            }
        }
        .padding(.leading, 52)
        .padding(.trailing, Spacing.md)
        .padding(.top, 2)
        .padding(.bottom, Spacing.sm)
    }

    private var emptyRow: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text("No active connections")
                .font(.netRowSecondary)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, Spacing.sm)
    }

    private func row(_ conn: ConnectionStat) -> some View {
        let isActive = conn.rate > 0
        return HStack(spacing: Spacing.sm) {
            LivePulseDot(isActive: isActive, color: Palette.highTraffic, size: 5)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(conn.host)
                    .font(.system(.caption).weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(":\(conn.port)")
                        .monospacedDigit()
                    Text("·")
                    Text(conn.proto)
                }
                .font(.netMicroMono)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: Spacing.sm)

            VStack(alignment: .trailing, spacing: 1) {
                Text(conn.formattedRate)
                    .font(.netMonoSm)
                    .monospacedDigit()
                    .foregroundStyle(isActive ? AnyShapeStyle(Palette.highTraffic) : AnyShapeStyle(.tertiary))
                Text(conn.sessionBytes.formattedBytes())
                    .font(.netMicroMono)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, Spacing.sm)
    }
}
