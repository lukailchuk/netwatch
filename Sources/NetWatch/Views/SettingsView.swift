import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @ObservedObject var travelManager = TravelModeManager.shared
    @AppStorage("costPerGB") private var costPerGB: Double = 4.0
    @State private var costInput: String = ""
    @State private var saveFeedback: Bool = false

    /// Local mirror of whitelist for snappy toggle rendering. Re-read after every mutation.
    @State private var whitelist: Set<String> = TravelWhitelistStore.load()
    @State private var helpersExpanded: Bool = false
    @State private var systemExpanded: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                costSection
                travelSection
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
        }
        .onAppear {
            costInput = String(format: "%.2f", costPerGB)
            whitelist = TravelWhitelistStore.load()
        }
    }

    // MARK: - Cost section

    private var costSection: some View {
        SettingsSection(
            title: "Cost estimate",
            footer: "Used to compute the EST. value in the header from your session bytes."
        ) {
            HStack(spacing: Spacing.sm) {
                Text("$")
                    .foregroundStyle(.secondary)
                TextField("4.00", text: $costInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 84)
                    .onSubmit { commitCost() }
                    .monospacedDigit()
                Text("per GB")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Apply") { commitCost() }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
        }
    }

    private func commitCost() {
        if let v = Double(costInput.replacingOccurrences(of: ",", with: ".")), v >= 0 {
            costPerGB = v
        }
        costInput = String(format: "%.2f", costPerGB)
    }

    // MARK: - Travel section

    /// Categorized snapshot of currently-tracked apps for the 3-tier UI.
    private var categorized: (userApps: [AppStat], helperGroups: [(parent: String, members: [AppStat])]) {
        let all = monitor.userApps
        let allBundleIds = Set(all.map(\.bundleId))

        var users: [AppStat] = []
        var helpersByParent: [String: [AppStat]] = [:]

        for app in all {
            switch ProcessCategory.categorize(app, allBundleIds: allBundleIds) {
            case .userApp:
                users.append(app)
            case .helper(let parent):
                helpersByParent[parent, default: []].append(app)
            case .systemDaemon:
                break  // Filtered earlier (monitor.userApps), kept for completeness
            }
        }

        users.sort { $0.total > $1.total }
        let groups = helpersByParent
            .map { (parent: $0.key, members: $0.value.sorted { $0.total > $1.total }) }
            .sorted { $0.members.reduce(0, { $0 + $1.total }) > $1.members.reduce(0, { $0 + $1.total }) }

        return (users, groups)
    }

    private var travelSection: some View {
        SettingsSection(
            title: "Travel Mode whitelist",
            footer: "Travel Mode pauses every app NOT in this list (SIGSTOP). Your foreground app, terminal, and NetWatch itself are always kept running."
        ) {
            if monitor.apps.isEmpty {
                emptyHint
            } else {
                userAppsBlock
                Divider().opacity(0.4)
                helpersBlock
                Divider().opacity(0.4)
                systemBlock
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: Spacing.xs) {
            Text("No traffic detected yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Open something that uses the network and wait a few seconds.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.lg)
    }

    private var userAppsBlock: some View {
        VStack(spacing: 0) {
            sectionLabel(text: "USER APPS (\(categorized.userApps.count))")
            ForEach(categorized.userApps) { app in
                appToggleRow(app: app, isHelper: false)
                if app.id != categorized.userApps.last?.id {
                    Divider().padding(.leading, Spacing.xl).opacity(0.5)
                }
            }
        }
    }

    private var helpersBlock: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(.netExpand) { helpersExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(helpersExpanded ? 90 : 0))
                        Text("HELPERS & BACKGROUND (\(categorized.helperGroups.count))")
                            .font(.netLabel)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.vertical, Spacing.xs + 2)
            .padding(.horizontal, 2)

            if helpersExpanded {
                ForEach(categorized.helperGroups, id: \.parent) { group in
                    helperGroupRow(parent: group.parent, members: group.members)
                    Divider().padding(.leading, Spacing.xl).opacity(0.5)
                }
                Text("Allowing a parent app auto-allows its helpers (e.g. Chrome → all Chrome renderers).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    private var systemBlock: some View {
        VStack(spacing: 0) {
            let agg = monitor.systemAggregate
            Button {
                withAnimation(.netExpand) { systemExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(systemExpanded ? 90 : 0))
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text("SYSTEM DAEMONS (\(agg.count))")
                        .font(.netLabel)
                    Spacer()
                    Text("\(agg.bytesIn.formattedBytes()) ↓  ·  \(agg.bytesOut.formattedBytes()) ↑")
                        .font(.netMonoSm)
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, Spacing.xs + 2)
            .padding(.horizontal, 2)

            if systemExpanded {
                ForEach(monitor.systemApps) { app in
                    systemRow(app: app)
                    Divider().padding(.leading, Spacing.xl).opacity(0.5)
                }
                Text("macOS protects UID < 500 processes from SIGSTOP. To block these, NetWatch would need a Network Extension (Apple Developer ID + entitlement).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, Spacing.xs)
                    .padding(.horizontal, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sectionLabel(text: String) -> some View {
        HStack {
            Text(text)
                .font(.netLabel)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, Spacing.xs + 2)
        .padding(.horizontal, 2)
    }

    private func appToggleRow(app: AppStat, isHelper: Bool) -> some View {
        let isAllowed = TravelWhitelistStore.isAllowed(app.bundleId, in: whitelist)
        return HStack(spacing: Spacing.md) {
            Toggle("", isOn: Binding(
                get: { isAllowed },
                set: { newValue in toggleAllow(app.bundleId, newValue: newValue) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

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

            Spacer()

            Text(app.total.formattedBytes())
                .font(.netMonoSm)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, Spacing.sm - 2)
        .padding(.horizontal, isHelper ? Spacing.md : 0)
    }

    private func helperGroupRow(parent: String, members: [AppStat]) -> some View {
        // Group toggle keys on `parent` — that's the canonical whitelist entry that
        // inheritance (TravelWhitelistStore.isAllowed prefix match) consults.
        let isAllowed = TravelWhitelistStore.isAllowed(parent, in: whitelist)
        let totalBytes = members.reduce(Int64(0)) { $0 + $1.total }
        return HStack(spacing: Spacing.md) {
            Toggle("", isOn: Binding(
                get: { isAllowed },
                set: { newValue in toggleAllow(parent, newValue: newValue) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text(parent.split(separator: ".").last.map(String.init) ?? parent)
                    .font(.netRowPrimary)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(parent) (×\(members.count))")
                    .font(.netRowSecondary)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(totalBytes.formattedBytes())
                .font(.netMonoSm)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, Spacing.sm - 2)
        .padding(.horizontal, Spacing.md)
    }

    private func systemRow(app: AppStat) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.appName)
                    .font(.netRowPrimary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(app.bundleId)
                    .font(.netRowSecondary)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(app.total.formattedBytes())
                .font(.netMonoSm)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, Spacing.sm - 2)
        .padding(.horizontal, Spacing.md)
    }

    private func toggleAllow(_ key: String, newValue: Bool) {
        Task { @MainActor in
            if newValue {
                await travelManager.allow(bundleId: key)
            } else {
                await travelManager.disallow(bundleId: key)
            }
            whitelist = TravelWhitelistStore.load()
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader(title: title)
                .padding(.horizontal, 2)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                content()
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(Palette.surfaceCard)
            }

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                    .lineSpacing(2)
            }
        }
    }
}
