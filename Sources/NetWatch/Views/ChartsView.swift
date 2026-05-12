import SwiftUI
import Charts

struct ChartsView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @Binding var selectedPeriod: Period
    @State private var weekApps: [PeriodApp] = []
    @State private var weekTimeline: [WeekPoint] = []
    @State private var selectedDay: String?

    struct WeekPoint: Identifiable {
        var id: String { date }
        let date: String
        let total: Int64

        var dayLabel: String {
            String(date.suffix(5))
        }

        var fullDateLabel: String {
            let inFmt = DateFormatter()
            inFmt.dateFormat = "yyyy-MM-dd"
            inFmt.locale = Locale(identifier: "en_US_POSIX")
            guard let d = inFmt.date(from: date) else { return date }
            let outFmt = DateFormatter()
            outFmt.setLocalizedDateFormatFromTemplate("EEEMMMd")
            return outFmt.string(from: d)
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
            let isDimmed = selectedDay != nil && selectedDay != point.dayLabel

            BarMark(
                x: .value("Day", point.dayLabel),
                y: .value("Bytes", point.total),
                width: .ratio(0.6)
            )
            .foregroundStyle(
                .linearGradient(
                    colors: [
                        Color.accentColor.opacity(isDimmed ? 0.3 : 1),
                        Color.accentColor.opacity(isDimmed ? 0.18 : 0.65)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .cornerRadius(3)

            if let selectedDay, point.dayLabel == selectedDay {
                RuleMark(x: .value("Day", point.dayLabel))
                    .foregroundStyle(Color.primary.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(
                        position: .top,
                        spacing: 6,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        tooltipCard(for: point)
                    }
            }
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
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotAnchor = proxy.plotFrame else { return }
                            let plot = geo[plotAnchor]
                            let xInPlot = location.x - plot.minX
                            guard xInPlot >= 0, xInPlot <= plot.width else {
                                if selectedDay != nil { selectedDay = nil }
                                return
                            }
                            let day: String? = proxy.value(atX: xInPlot, as: String.self)
                            if selectedDay != day { selectedDay = day }
                        case .ended:
                            if selectedDay != nil { selectedDay = nil }
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.4), value: weekTimeline.map(\.total))
        .animation(.netHover, value: selectedDay)
    }

    private func tooltipCard(for point: WeekPoint) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(point.fullDateLabel)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.3)
            Text(point.total.formattedBytes())
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
        .fixedSize()
    }

    private var appBreakdownSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(
                title: selectedPeriod.breakdownTitle,
                accessory: periodApps.isEmpty ? nil : AnyView(
                    Text("\(periodApps.count) apps")
                        .font(.netMonoSm)
                        .foregroundStyle(.tertiary)
                )
            )

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
                Text(app.total.formattedBytes())
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
