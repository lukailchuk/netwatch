import SwiftUI
import AppKit

struct AppsGridView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @State private var processingId: String? = nil
    @State private var expandedBundleIds: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if monitor.apps.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "network.slash")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No traffic data yet")
                            .foregroundColor(.secondary)
                        Text("Give nettop a minute to populate.\nIf it stays empty, grant Full Disk Access to NetWatch in System Settings → Privacy & Security.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 40)
                    .padding(.horizontal, 16)
                } else {
                    ForEach(monitor.apps.prefix(25)) { app in
                        VStack(spacing: 0) {
                            AppRow(
                                app: app,
                                isProcessing: processingId == app.id,
                                isExpanded: expandedBundleIds.contains(app.bundleId),
                                onAction: { action in handle(action: action, for: app) },
                                onToggleExpand: { toggleExpand(app.bundleId) }
                            )

                            if expandedBundleIds.contains(app.bundleId) {
                                ConnectionsListView(bundleId: app.bundleId)
                                    .environmentObject(monitor)
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private func toggleExpand(_ bundleId: String) {
        if expandedBundleIds.contains(bundleId) {
            expandedBundleIds.remove(bundleId)
        } else {
            expandedBundleIds.insert(bundleId)
        }
        // Tell monitor whether to bother parsing per-connection rows
        monitor.drilldownActive = !expandedBundleIds.isEmpty
    }

    private func handle(action: AppRowAction, for app: AppStat) {
        Task { @MainActor in
            processingId = app.id
            defer { processingId = nil }

            switch action {
            case .quit:
                try? await AppController.quitApp(bundleId: app.bundleId)
            case .launch:
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleId) {
                    AppController.launchApp(at: url.path)
                }
            }
        }
    }
}

enum AppRowAction {
    case quit
    case launch
}

struct AppRow: View {
    let app: AppStat
    let isProcessing: Bool
    let isExpanded: Bool
    let onAction: (AppRowAction) -> Void
    let onToggleExpand: () -> Void
    @State private var icon: NSImage?

    var isRunning: Bool {
        AppController.isAppRunning(bundleId: app.bundleId)
    }

    private var rateText: String {
        if app.rate < 100 { return "" }  // hide flicker for sub-100B/s noise
        return app.rate.formattedRate()
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggleExpand) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.borderless)

            iconView

            VStack(alignment: .leading, spacing: 1) {
                Text(app.appName)
                    .font(.callout)
                    .lineLimit(1)
                Text(app.bundleId)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                if !rateText.isEmpty {
                    Text(rateText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.orange)
                }
                Text(app.formattedTotal)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .frame(minWidth: 78, alignment: .trailing)

            actionButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(6)
        .onAppear {
            icon = AppIconCache.shared.icon(forBundleId: app.bundleId)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.25))
                .frame(width: 26, height: 26)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if isProcessing {
            ProgressView()
                .controlSize(.small)
                .frame(width: 22, height: 22)
        } else if isRunning {
            Button {
                onAction(.quit)
            } label: {
                Image(systemName: "power.circle.fill")
                    .foregroundColor(.red)
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Quit \(app.appName)")
        } else {
            Button {
                onAction(.launch)
            } label: {
                Image(systemName: "play.circle.fill")
                    .foregroundColor(.green)
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Re-launch \(app.appName)")
        }
    }
}
