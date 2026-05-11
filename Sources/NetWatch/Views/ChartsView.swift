import SwiftUI
import Charts

struct ChartsView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @State private var weekData: [WeekPoint] = []

    struct WeekPoint: Identifiable {
        var id: String { date }
        let date: String
        let total: Int64
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Last 7 days")
                    .font(.headline)
                    .padding(.horizontal, 4)

                if weekData.isEmpty {
                    Text("No history yet")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    Chart(weekData) { point in
                        BarMark(
                            x: .value("Day", String(point.date.suffix(5))),
                            y: .value("Bytes", point.total)
                        )
                        .foregroundStyle(.linearGradient(
                            colors: [.blue.opacity(0.4), .blue],
                            startPoint: .bottom,
                            endPoint: .top
                        ))
                        .cornerRadius(3)
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let bytes = value.as(Int64.self) {
                                    Text(bytes.formattedBytes()).font(.caption2)
                                }
                            }
                        }
                    }
                    .frame(height: 180)
                }

                Divider()

                Text("Today by app")
                    .font(.headline)
                    .padding(.horizontal, 4)

                if monitor.apps.isEmpty {
                    Text("No traffic recorded yet today")
                        .foregroundColor(.secondary)
                        .font(.caption)
                } else {
                    ForEach(monitor.apps.prefix(15)) { app in
                        HStack {
                            Text(app.appName)
                                .lineLimit(1)
                                .font(.caption)
                            Spacer()
                            Text(app.formattedTotal)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(12)
        }
        .task {
            await loadWeek()
        }
        .onChange(of: monitor.todayTotal) { _, _ in
            Task { await loadWeek() }
        }
    }

    private func loadWeek() async {
        let data = Database.shared.getWeeklyTotals()
        self.weekData = data.map { WeekPoint(date: $0.date, total: $0.total) }
    }
}
