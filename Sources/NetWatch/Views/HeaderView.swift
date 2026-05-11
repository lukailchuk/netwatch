import SwiftUI

struct HeaderView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @AppStorage("travelModeActive") private var travelModeOn: Bool = false
    @AppStorage("costPerGB") private var costPerGB: Double = 4.0
    @State private var showResetConfirm = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LIVE")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(monitor.liveRate.formattedRate())
                        .font(.system(.title2, design: .monospaced))
                        .foregroundColor(monitor.liveRate > 200_000 ? .orange : .primary)
                        .contentTransition(.numericText())
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Toggle(isOn: $travelModeOn) {
                        Label("Travel Mode", systemImage: "airplane")
                            .font(.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: travelModeOn) { _, newValue in
                        Task {
                            if newValue {
                                await TravelModeManager.shared.activate()
                            } else {
                                await TravelModeManager.shared.deactivate()
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                stat(title: "SESSION", value: monitor.sessionTotal.formattedBytes())
                stat(title: "TODAY", value: monitor.todayTotal.formattedBytes())
                stat(title: "WEEK", value: monitor.weekTotal.formattedBytes())
                stat(title: "EST.", value: estimatedCost(monitor.sessionTotal))
            }

            HStack {
                Spacer()
                Button {
                    showResetConfirm = true
                } label: {
                    Label("Reset Session", systemImage: "arrow.counterclockwise")
                        .font(.caption2)
                }
                .controlSize(.mini)
                .confirmationDialog(
                    "Reset session counters?",
                    isPresented: $showResetConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) {
                        monitor.resetSession()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This zeros the Session column and clears the per-host drilldowns. Daily/Week stays.")
                }
            }
        }
        .padding(12)
    }

    private func stat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(6)
    }

    private func estimatedCost(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        let usd = gb * costPerGB
        return String(format: "$%.2f", usd)
    }
}
