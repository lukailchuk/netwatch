import SwiftUI
import AppKit

struct AppsGridView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @State private var processingId: String? = nil
    @State private var expandedBundleIds: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if monitor.apps.isEmpty {
                    emptyState
                        .padding(.top, Spacing.xxxl)
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
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .move(edge: .top)),
                                        removal: .opacity
                                    ))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(Palette.surfaceSubtle)
                    .frame(width: 64, height: 64)
                Image(systemName: "network.slash")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: Spacing.xs) {
                Text("No traffic yet")
                    .font(.system(.headline))
                    .foregroundStyle(.primary)
                Text("Give nettop a minute to populate. If it stays empty, grant Full Disk Access to NetWatch in System Settings → Privacy & Security.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            .padding(.horizontal, Spacing.xl)
        }
        .frame(maxWidth: .infinity)
    }

    private func toggleExpand(_ bundleId: String) {
        withAnimation(.netExpand) {
            if expandedBundleIds.contains(bundleId) {
                expandedBundleIds.remove(bundleId)
            } else {
                expandedBundleIds.insert(bundleId)
            }
        }
        monitor.drilldownActive = !expandedBundleIds.isEmpty
    }

    private func handle(action: AppRowAction, for app: AppStat) {
        Task { @MainActor in
            processingId = app.id
            defer { processingId = nil }

            switch action {
            case .pause:
                await AppController.pause(bundleId: app.bundleId, pids: app.pids)
            case .resume:
                await AppController.resume(bundleId: app.bundleId, pids: app.pids)
            case .kill:
                await AppController.killProcesses(pids: app.pids, bundleId: app.bundleId)
            }
        }
    }
}

enum AppRowAction {
    case pause
    case resume
    case kill
}

struct AppRow: View {
    let app: AppStat
    let isProcessing: Bool
    let isExpanded: Bool
    let onAction: (AppRowAction) -> Void
    let onToggleExpand: () -> Void

    @State private var icon: NSImage?
    @State private var isHovered: Bool = false
    @State private var showPauseInfo: Bool = false
    @AppStorage("netwatch.firstPauseShown") private var firstPauseShown: Bool = false

    private let rateNoiseFloor: Double = 100

    private var isActive: Bool {
        app.rate >= rateNoiseFloor
    }

    private var rateText: String {
        if app.rate < rateNoiseFloor { return "" }
        return app.rate.formattedRate()
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            chevron
            iconView
            nameBlock
            Spacer(minLength: Spacing.sm)
            rateBlock
            actionButton
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm + 2)
        .contentShape(Rectangle())
        .rowStyle(isActive: isActive || isExpanded, isHovered: isHovered)
        .onTapGesture {
            onToggleExpand()
        }
        .onHover { hovering in
            withAnimation(.netHover) {
                isHovered = hovering
            }
        }
        .onAppear {
            icon = AppIconCache.shared.icon(forBundleId: app.bundleId)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 10)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(.netToggle, value: isExpanded)
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
                .shadow(color: .black.opacity(0.08), radius: 1, x: 0, y: 0.5)
        } else {
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
        }
    }

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(app.appName)
                .font(.netRowPrimary)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(app.bundleId)
                .font(.netRowSecondary)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var rateBlock: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if !rateText.isEmpty {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Palette.liveDot)
                        .frame(width: 5, height: 5)
                    Text(rateText)
                        .font(.netMono)
                        .foregroundStyle(Palette.highTraffic)
                        .monospacedDigit()
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            Text(app.formattedTotal)
                .font(.netMonoSm)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(minWidth: 84, alignment: .trailing)
        .animation(.netContent, value: rateText.isEmpty)
    }

    @ViewBuilder
    private var actionButton: some View {
        if isProcessing {
            ProgressView()
                .controlSize(.small)
                .frame(width: 26, height: 26)
        } else if app.isSystem {
            disabledIcon(
                systemName: "lock.circle.fill",
                help: "\(app.appName) — system process, managed by macOS"
            )
        } else if !app.isLive {
            disabledIcon(
                systemName: "power.circle.fill",
                help: "No active process for \(app.appName)"
            )
        } else {
            HStack(spacing: 4) {
                pauseToggle
                killSecondary
            }
        }
    }

    private var pauseToggle: some View {
        Button {
            if !app.isPaused && !firstPauseShown {
                showPauseInfo = true
                firstPauseShown = true
            }
            onAction(app.isPaused ? .resume : .pause)
        } label: {
            Image(systemName: app.isPaused ? "pause.circle.fill" : "power.circle.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(
                    app.isPaused ? Palette.warning : Palette.danger,
                    (app.isPaused ? Palette.warning : Palette.danger).opacity(0.15)
                )
                .symbolRenderingMode(.palette)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(app.isPaused ? "Resume \(app.appName)" : "Pause \(app.appName) (freezes the whole process)")
        .popover(isPresented: $showPauseInfo, arrowEdge: .trailing) {
            pauseInfoPopover
        }
    }

    private var killSecondary: some View {
        Button {
            onAction(.kill)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(
                    isHovered ? Palette.danger : Color.secondary,
                    (isHovered ? Palette.danger : Color.secondary).opacity(0.15)
                )
                .symbolRenderingMode(.palette)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Kill \(app.appName)")
    }

    private func disabledIcon(systemName: String, help: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.tertiary, Color.secondary.opacity(0.1))
            .symbolRenderingMode(.palette)
            .frame(width: 26, height: 26)
            .help(help)
    }

    private var pauseInfoPopover: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Palette.warning)
                Text("Heads up — это pause, не firewall")
                    .font(.headline)
            }
            Text("Pause freezes the **whole process** (UI included), not just network. The app's window will become unresponsive until you resume.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("True per-process firewalling needs a Network Extension — planned for a future version.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Got it") { showPauseInfo = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.md)
        .frame(width: 320)
    }
}
