import SwiftUI

struct HeaderView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @ObservedObject var travelManager = TravelModeManager.shared
    @Binding var selectedPeriod: Period
    @Binding var inSettings: Bool
    let onPeriodTap: (Period) -> Void

    @AppStorage("costPerGB") private var costPerGB: Double = 4.0
    @AppStorage("netwatch.hasSeenTravelPreview") private var hasSeenTravelPreview: Bool = false
    @State private var showResetConfirm = false
    @State private var showTravelPreview = false

    private let highTrafficThreshold: Double = 200_000

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            topRow
            heroRate
            statsRow
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.lg)
        .padding(.bottom, Spacing.md)
        .sheet(isPresented: $showTravelPreview) {
            TravelModePreviewSheet(
                candidates: travelManager.previewCandidates(),
                onConfirm: {
                    hasSeenTravelPreview = true
                    showTravelPreview = false
                    Task { await travelManager.activate() }
                },
                onCancel: { showTravelPreview = false }
            )
        }
    }

    private var topRow: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            HStack(spacing: 6) {
                LivePulseDot(isActive: monitor.liveRate > 0)
                Text("LIVE")
                    .font(.netLabel)
                    .foregroundStyle(.secondary)
                    .tracking(0.8)
            }
            Spacer()
            if travelManager.isActive {
                panicButton
            }
            travelToggle
            resetButton
            settingsButton
            quitButton
        }
    }

    private var travelToggle: some View {
        Button {
            withAnimation(.netToggle) {
                if travelManager.isActive {
                    Task { await travelManager.deactivate() }
                } else if hasSeenTravelPreview {
                    Task { await travelManager.activate() }
                } else {
                    showTravelPreview = true
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: travelManager.isActive ? "airplane.circle.fill" : "airplane")
                    .font(.system(size: 11, weight: .semibold))
                Text("Travel")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(travelManager.isActive ? Color.white : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule()
                    .fill(travelManager.isActive ? Color.accentColor : Palette.surfaceSubtle)
            }
            .overlay {
                Capsule()
                    .strokeBorder(travelManager.isActive ? Color.clear : Palette.divider, lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(travelManager.isActive ? "Disable Travel Mode" : "Activate Travel Mode")
    }

    /// Emergency release. Visible only while Travel Mode is on. One click → SIGCONT all
    /// session-paused bundles + deactivate. Recovery path if something user needed got caught.
    private var panicButton: some View {
        Button {
            Task { await travelManager.panicResume() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("Resume all")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                Capsule()
                    .fill(Palette.danger)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("PANIC: resume every app Travel Mode paused and turn it off")
    }

    private var resetButton: some View {
        circleIconButton(systemName: "arrow.counterclockwise", help: "Reset Session") {
            showResetConfirm = true
        }
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

    private var settingsButton: some View {
        circleIconButton(
            systemName: "gearshape",
            activeSystemName: "gearshape.fill",
            isActive: inSettings,
            help: inSettings ? "Close Settings" : "Open Settings"
        ) {
            withAnimation(.netContent) {
                inSettings.toggle()
            }
        }
    }

    private var quitButton: some View {
        circleIconButton(systemName: "power", help: "Quit NetWatch") {
            NSApp.terminate(nil)
        }
    }

    private func circleIconButton(
        systemName: String,
        activeSystemName: String? = nil,
        isActive: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: isActive ? (activeSystemName ?? systemName) : systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)
                .background {
                    Circle()
                        .fill(isActive ? Color.accentColor.opacity(0.14) : Palette.surfaceSubtle)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var heroRate: some View {
        let parts = splitRate(monitor.liveRate)
        let isHigh = monitor.liveRate > highTrafficThreshold
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(parts.value)
                .font(.netHero)
                .monospacedDigit()
                .foregroundStyle(isHigh ? Palette.highTraffic : Color.primary)
                .contentTransition(.numericText())
                .animation(.snappy, value: parts.value)
            Text(parts.unit)
                .font(.netHeroUnit)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Spacer(minLength: 0)
        }
    }

    private var statsRow: some View {
        HStack(spacing: Spacing.sm) {
            StatCard(
                label: "SESSION",
                value: monitor.sessionTotal.formattedBytes(),
                isSelected: !inSettings && selectedPeriod == .session,
                onTap: { onPeriodTap(.session) }
            )
            StatCard(
                label: "TODAY",
                value: monitor.todayTotal.formattedBytes(),
                isSelected: !inSettings && selectedPeriod == .today,
                onTap: { onPeriodTap(.today) }
            )
            StatCard(
                label: "WEEK",
                value: monitor.weekTotal.formattedBytes(),
                isSelected: !inSettings && selectedPeriod == .week,
                onTap: { onPeriodTap(.week) }
            )
            StatCard(
                label: "EST.",
                value: estimatedCost(monitor.sessionTotal),
                accent: Palette.accent
            )
        }
    }

    private func splitRate(_ rate: Double) -> (value: String, unit: String) {
        let formatted = rate.formattedRate()
        if let lastSpace = formatted.lastIndex(of: " ") {
            let value = String(formatted[..<lastSpace])
            let unit = String(formatted[formatted.index(after: lastSpace)...])
            return (value, unit)
        }
        return (formatted, "")
    }

    private func estimatedCost(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        let usd = gb * costPerGB
        return String(format: "$%.2f", usd)
    }
}
