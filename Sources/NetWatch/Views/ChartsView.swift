import SwiftUI
import Charts

struct ChartsView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @Binding var selectedPeriod: Period
    @State private var weekApps: [PeriodApp] = []
    @State private var weekTimeline: [WeekPoint] = []

    struct WeekPoint: Identifiable {
        var id: String { date }
        let date: String
        let total: Int64

        var dayLabel: String {
            String(date.suffix(5))
        }
    }

    private var periodApps: [PeriodApp] {
        switch selectedPeriod {
        case .session, .today:
            return monitor.appsForPeriod(selectedPeriod)
        case .week:
            return weekApps
        }
    }

    private var maxAppTotal: Int64 {
        periodApps.prefix(15).map(\.total).max() ?? 1
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                if selectedPeriod == .week {
                    weekChartSection
                }
                appBreakdownSection
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
        }
        .onAppear {
            if selectedPeriod == .week {
                reloadWeek()
            }
        }
        .onChange(of: selectedPeriod) { _, newValue in
            if newValue == .week {
                reloadWeek()
            } else {
                weekApps = []
                weekTimeline = []
            }
        }
        .onChange(of: monitor.todayTotal) { _, _ in
            if selectedPeriod == .week {
                reloadWeek()
            }
        }
    }

    private var weekChartSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title: "Last 7 days")

            if weekTimeline.isEmpty {
                placeholderCard(icon: "chart.line.uptrend.xyaxis", message: "No history yet")
            } else {
                weekChart
                    .padding(Spacing.md)
                    .background {
                        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            .fill(Palette.surfaceCard)
                    }
            }
        }
    }

    private var weekChart: some View {
        Chart(weekTimeline) { point in
            AreaMark(
                x: .value("Day", point.dayLabel),
                y: .value("Bytes", point.total)
            )
            .foregroundStyle(
                .linearGradient(
                    colors: [
                        Color.accentColor.opacity(0.45),
                        Color.accentColor.opacity(0.02)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("Day", point.dayLabel),
                y: .value("Bytes", point.total)
            )
            .foregroundStyle(Color.accentColor)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.monotone)

            PointMark(
                x: .value("Day", point.dayLabel),
                y: .value("Bytes", point.total)
            )
            .foregroundStyle(Color.accentColor)
            .symbolSize(28)
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                    .foregroundStyle(Palette.divider)
                AxisValueLabel {
                    if let bytes = value.as(Int64.self) {
                        Text(bytes.formattedBytes())
                            .font(.netMicroMono)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .font(.netMicroMono)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 160)
        .animation(.easeInOut(duration: 0.4), value: weekTimeline.map(\.total))
    }

    private var appBreakdownSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(selectedPeriod.breakdownTitle)
                    .font(.netSectionHeader)
                    .foregroundStyle(.primary)
                Spacer()
                if !periodApps.isEmpty {
                    Text("\(periodApps.count) apps")
                        .font(.netMonoSm)
                        .foregroundStyle(.tertiary)
                }
            }

            if periodApps.isEmpty {
                placeholderCard(icon: "tray", message: selectedPeriod.emptyMessage)
            } else {
                let cappedMax = maxAppTotal
                VStack(spacing: 8) {
                    ForEach(periodApps.prefix(15)) { app in
                        AppBreakdownRow(app: app, maxTotal: cappedMax)
                    }
                }
                .padding(Spacing.md)
                .background {
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .fill(Palette.surfaceCard)
                }
            }
        }
    }

    private func placeholderCard(icon: String, message: String) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(Palette.surfaceCard)
        }
    }

    private func reloadWeek() {
        weekApps = Database.shared.getAppTotalsForWeek()
        weekTimeline = Database.shared.getWeeklyTotals().map { WeekPoint(date: $0.date, total: $0.total) }
    }
}

private struct AppBreakdownRow: View {
    let app: PeriodApp
    let maxTotal: Int64
    @State private var icon: NSImage?

    private let iconSize: CGFloat = 20

    private var fraction: Double {
        maxTotal > 0 ? Double(app.total) / Double(maxTotal) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: Spacing.sm) {
                iconView
                Text(app.appName)
                    .font(.system(.caption).weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: Spacing.sm)
                Text(app.formattedTotal)
                    .font(.netMonoSm)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            progressBar
                .padding(.leading, iconSize + Spacing.sm)
        }
        .padding(.vertical, 2)
        .onAppear {
            if icon == nil {
                icon = AppIconCache.shared.icon(forBundleId: app.bundleId)
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
                .shadow(color: .black.opacity(0.08), radius: 1, x: 0, y: 0.5)
        } else {
            RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: iconSize, height: iconSize)
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Palette.surfaceHover)
                    .frame(height: 3)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.7), Color.accentColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(2, geo.size.width * fraction), height: 3)
                    .animation(.easeOut(duration: 0.5), value: fraction)
            }
        }
        .frame(height: 3)
    }
}
