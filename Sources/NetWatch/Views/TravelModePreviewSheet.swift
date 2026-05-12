import SwiftUI

/// Shown once on first activation of Travel Mode. Lists the apps that are about to be
/// SIGSTOP'd so the user can sanity-check before something they need gets frozen.
struct TravelModePreviewSheet: View {
    let candidates: [AppStat]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 460, height: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: 8) {
                Image(systemName: "airplane.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Activate Travel Mode")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
            }
            Text("\(candidates.count) running app\(candidates.count == 1 ? "" : "s") will be paused (SIGSTOP). System daemons and your foreground app stay running.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                if candidates.isEmpty {
                    emptyState
                } else {
                    ForEach(candidates) { app in
                        row(for: app)
                    }
                }
            }
            .padding(Spacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surfaceCard)
    }

    private func row(for app: AppStat) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.warning)
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
                .font(.netMono)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, Spacing.xs + 1)
        .padding(.horizontal, Spacing.sm)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 30))
                .foregroundStyle(Palette.success)
            Text("Nothing to pause")
                .font(.headline)
            Text("No non-system apps currently using bandwidth. Travel Mode will still activate and catch new processes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, Spacing.xxl)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: Spacing.sm) {
            Text("This preview shows once. You can change the whitelist any time in Settings.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.sm)
            Button("Cancel") { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Activate") { onConfirm() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(Spacing.lg)
    }
}
