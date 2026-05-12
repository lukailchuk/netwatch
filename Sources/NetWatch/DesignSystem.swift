import SwiftUI
import AppKit

// MARK: - Spacing

enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

// MARK: - Radius

enum Radius {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 10
    static let lg: CGFloat = 14
    static let xl: CGFloat = 20
}

// MARK: - Palette

enum Palette {
    static let liveDot = Color.green
    static let highTraffic = Color.orange
    static let danger = Color.red
    static let success = Color.green
    static let accent = Color.accentColor

    static let surfaceSubtle = Color.primary.opacity(0.04)
    static let surfaceHover = Color.primary.opacity(0.06)
    static let surfaceActive = Color.accentColor.opacity(0.10)
    static let surfaceCard = Color.primary.opacity(0.05)
    static let divider = Color.primary.opacity(0.08)
}

// MARK: - Typography

extension Font {
    static let netHero = Font.system(size: 40, weight: .semibold, design: .rounded)
    static let netHeroUnit = Font.system(size: 14, weight: .medium, design: .rounded)
    static let netLabel = Font.system(size: 10, weight: .semibold).smallCaps()
    static let netCardValue = Font.system(.subheadline, design: .rounded).weight(.medium)
    static let netSectionHeader = Font.system(.subheadline).weight(.semibold)
    static let netRowPrimary = Font.system(.callout).weight(.medium)
    static let netRowSecondary = Font.system(.caption2)
    static let netMono = Font.system(.caption, design: .monospaced).weight(.medium)
    static let netMonoSm = Font.system(.caption2, design: .monospaced)
    static let netMicroMono = Font.system(size: 9, design: .monospaced)
}

// MARK: - Animation tokens

extension Animation {
    static let netContent = Animation.easeInOut(duration: 0.22)
    static let netHover = Animation.easeInOut(duration: 0.15)
    static let netToggle = Animation.spring(response: 0.3, dampingFraction: 0.75)
    static let netExpand = Animation.spring(response: 0.4, dampingFraction: 0.82)
}

// MARK: - Visual Effect Blur (NSVisualEffectView wrapper)

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Live Pulse Indicator

struct LivePulseDot: View {
    var isActive: Bool
    var color: Color = Palette.liveDot
    var size: CGFloat = 7
    @State private var animate = false

    var body: some View {
        ZStack {
            if isActive {
                Circle()
                    .fill(color.opacity(0.4))
                    .frame(width: size * 2.2, height: size * 2.2)
                    .scaleEffect(animate ? 1.0 : 0.4)
                    .opacity(animate ? 0.0 : 0.8)
            }
            Circle()
                .fill(isActive ? color : Color.secondary.opacity(0.5))
                .frame(width: size, height: size)
        }
        .frame(width: size * 2.2, height: size * 2.2)
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
    }
}

// MARK: - Reusable Components

struct StatCard: View {
    let label: String
    let value: String
    var accent: Color? = nil
    var isSelected: Bool = false
    var onTap: (() -> Void)? = nil

    private var labelColor: Color {
        isSelected ? Color.accentColor : .secondary
    }

    private var valueColor: Color {
        if let accent { return accent }
        return isSelected ? Color.accentColor : .primary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.netLabel)
                .foregroundStyle(labelColor)
            Text(value)
                .font(.netCardValue)
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.sm)
        .padding(.horizontal, Spacing.md - 2)
        .background {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Palette.surfaceCard)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.45) : Color.clear,
                    lineWidth: 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .onTapGesture {
            onTap?()
        }
        .animation(.easeInOut(duration: 0.18), value: isSelected)
    }
}

struct SectionHeader: View {
    let title: String
    var accessory: AnyView? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.netSectionHeader)
                .foregroundStyle(.primary)
            Spacer()
            if let accessory {
                accessory
            }
        }
    }
}

// MARK: - View Modifiers

struct RowStyle: ViewModifier {
    let isActive: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(rowFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(isActive ? Color.accentColor.opacity(0.18) : Color.clear, lineWidth: 1)
            }
    }

    private var rowFill: Color {
        if isActive { return Palette.surfaceActive }
        if isHovered { return Palette.surfaceHover }
        return Palette.surfaceSubtle
    }
}

extension View {
    func rowStyle(isActive: Bool = false, isHovered: Bool = false) -> some View {
        modifier(RowStyle(isActive: isActive, isHovered: isHovered))
    }
}
