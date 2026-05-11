import SwiftUI

struct MenubarView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @State private var selectedTab: Tab = .apps

    enum Tab { case apps, charts, settings }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
                .environmentObject(monitor)

            Divider()

            Group {
                switch selectedTab {
                case .apps:
                    AppsGridView()
                        .environmentObject(monitor)
                case .charts:
                    ChartsView()
                        .environmentObject(monitor)
                case .settings:
                    SettingsView()
                }
            }

            Divider()

            HStack(spacing: 6) {
                tabButton(.apps, label: "Apps", icon: "square.grid.2x2")
                tabButton(.charts, label: "Charts", icon: "chart.bar")
                tabButton(.settings, label: "Settings", icon: "gear")
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Quit NetWatch")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: 400, height: 520)
    }

    @ViewBuilder
    private func tabButton(_ tab: Tab, label: String, icon: String) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(label).font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selectedTab == tab ? Color.accentColor.opacity(0.18) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.borderless)
    }
}
