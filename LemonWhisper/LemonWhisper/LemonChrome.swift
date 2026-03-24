import SwiftUI

enum LemonChrome {
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let subtleBorder = border.opacity(0.35)
    static let shadow = Color.black.opacity(0.08)
    static let progressTint = Color(nsColor: .tertiaryLabelColor)
    static let buttonBorder = border
    static let buttonFill = windowBackground
    static let buttonPressedFill = surface
    static let buttonDisabledFill = surface
    static let buttonDisabledForeground = Color(nsColor: .tertiaryLabelColor)
}

struct NeutralActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(isEnabled ? Color.primary : LemonChrome.buttonDisabledForeground)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(backgroundFill(isEnabled: isEnabled, isPressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(LemonChrome.buttonBorder, lineWidth: 1)
            )
    }

    private func backgroundFill(isEnabled: Bool, isPressed: Bool) -> Color {
        guard isEnabled else { return LemonChrome.buttonDisabledFill }
        return isPressed ? LemonChrome.buttonPressedFill : LemonChrome.buttonFill
    }
}

struct NeutralIconButtonStyle: ButtonStyle {
    let foreground: Color
    let size: CGFloat

    init(foreground: Color = .primary, size: CGFloat = 34) {
        self.foreground = foreground
        self.size = size
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .frame(width: size, height: size)
            .foregroundStyle(foreground)
            .background(
                Circle()
                    .fill(LemonChrome.windowBackground)
            )
            .overlay(
                Circle()
                    .stroke(LemonChrome.subtleBorder, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.88 : 1)
    }
}

private struct LemonSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let showsBorder: Bool
    let showsShadow: Bool

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LemonChrome.surface)
                .overlay {
                    if showsBorder {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(LemonChrome.subtleBorder, lineWidth: 1)
                    }
                }
                .shadow(
                    color: showsShadow ? LemonChrome.shadow : .clear,
                    radius: showsShadow ? 10 : 0,
                    x: 0,
                    y: showsShadow ? 4 : 0
                )
        )
    }
}

extension View {
    func lemonNeutralProgressTint() -> some View {
        tint(LemonChrome.progressTint)
    }

    func lemonSurface(
        cornerRadius: CGFloat = 18,
        showsBorder: Bool = false,
        showsShadow: Bool = false
    ) -> some View {
        modifier(
            LemonSurfaceModifier(
                cornerRadius: cornerRadius,
                showsBorder: showsBorder,
                showsShadow: showsShadow
            )
        )
    }
}
