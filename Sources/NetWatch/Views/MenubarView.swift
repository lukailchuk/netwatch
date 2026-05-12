import SwiftUI

struct MenubarView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @State private var selectedPeriod: Period = .session
    @State private var inSettings: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(
                selectedPeriod: $selectedPeriod,
                inSettings: $inSettings,
                onPeriodTap: handlePeriodTap
            )
            .environmentObject(monitor)

            Divider()
                .opacity(0.4)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 400, height: 520)
        .background {
            VisualEffectBlur(material: .popover, blendingMode: .behindWindow)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if inSettings {
                SettingsView()
                    .transition(.opacity)
            } else {
                switch selectedPeriod {
                case .session:
                    AppsGridView()
                        .environmentObject(monitor)
                        .transition(.opacity)
                case .today, .week:
                    ChartsView(selectedPeriod: $selectedPeriod)
                        .environmentObject(monitor)
                        .transition(.opacity)
                }
            }
        }
        .animation(.netContent, value: inSettings)
        .animation(.netContent, value: selectedPeriod)
    }

    private func handlePeriodTap(_ period: Period) {
        withAnimation(.netContent) {
            inSettings = false
            selectedPeriod = period
        }
    }
}
