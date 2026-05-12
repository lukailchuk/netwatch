import SwiftUI

struct SettingsView: View {
    @State private var targets: [TravelTarget] = TravelModeStore.load()
    @AppStorage("costPerGB") private var costPerGB: Double = 4.0
    @State private var costInput: String = ""
    @State private var saveFeedback: Bool = false

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
        }
    }

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

    private var travelSection: some View {
        SettingsSection(
            title: "Travel Mode targets",
            footer: "These apps and daemons are quit when you toggle Travel Mode on. Uncheck what you'd rather keep running."
        ) {
            VStack(spacing: 0) {
                ForEach(Array(targets.enumerated()), id: \.element.id) { index, target in
                    targetRow(target: $targets[index])
                    if index < targets.count - 1 {
                        Divider()
                            .padding(.leading, Spacing.xxxl)
                            .opacity(0.5)
                    }
                }
            }

            HStack(spacing: Spacing.sm) {
                Button {
                    TravelModeStore.save(targets)
                    flashSaveFeedback()
                } label: {
                    Label(saveFeedback ? "Saved" : "Save", systemImage: saveFeedback ? "checkmark.circle.fill" : "tray.and.arrow.down")
                        .font(.callout)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)

                Button {
                    targets = TravelModeStore.defaultTargets
                    TravelModeStore.save(targets)
                    flashSaveFeedback()
                } label: {
                    Label("Reset to defaults", systemImage: "arrow.uturn.backward")
                        .font(.callout)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding(.top, Spacing.sm)
        }
    }

    private func targetRow(target: Binding<TravelTarget>) -> some View {
        HStack(spacing: Spacing.md) {
            Toggle("", isOn: target.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text(target.wrappedValue.displayName)
                    .font(.netRowPrimary)
                    .foregroundStyle(.primary)
                if let bid = target.wrappedValue.bundleId {
                    Text(bid)
                        .font(.netRowSecondary)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if let ld = target.wrappedValue.launchdLabel {
                    HStack(spacing: 4) {
                        Text("launchd")
                            .font(.system(size: 9, weight: .semibold).smallCaps())
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color.secondary.opacity(0.15))
                            }
                        Text(ld)
                            .font(.netRowSecondary)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, Spacing.sm - 2)
    }

    private func commitCost() {
        if let v = Double(costInput.replacingOccurrences(of: ",", with: ".")), v >= 0 {
            costPerGB = v
        }
        costInput = String(format: "%.2f", costPerGB)
    }

    private func flashSaveFeedback() {
        withAnimation(.netContent) {
            saveFeedback = true
        }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run {
                withAnimation(.netContent) {
                    saveFeedback = false
                }
            }
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(.netSectionHeader)
                .foregroundStyle(.primary)
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
