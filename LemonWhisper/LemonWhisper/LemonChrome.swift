import SwiftUI

enum LemonChrome {
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let subtleBorder = border.opacity(0.35)
    static let shadow = Color.black.opacity(0.10)
    static let progressTint = Color(nsColor: .tertiaryLabelColor)
    static let buttonBorder = border
    static let buttonPressedFill = Color.primary.opacity(0.08)
    static let buttonDisabledFill = Color.primary.opacity(0.04)
    static let buttonDisabledForeground = Color(nsColor: .tertiaryLabelColor)
    static let accentWash = Color.accentColor.opacity(0.035)
    static let warmWash = Color.yellow.opacity(0.012)
}

struct NeutralActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(isEnabled ? Color.primary : LemonChrome.buttonDisabledForeground)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(backgroundFill(isEnabled: isEnabled, isPressed: configuration.isPressed))
                    }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(LemonChrome.buttonBorder, lineWidth: 1)
            )
            .shadow(color: LemonChrome.shadow.opacity(isEnabled ? 0.8 : 0), radius: 6, x: 0, y: 2)
    }

    private func backgroundFill(isEnabled: Bool, isPressed: Bool) -> Color {
        guard isEnabled else { return LemonChrome.buttonDisabledFill }
        return isPressed ? LemonChrome.buttonPressedFill : .clear
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
            .background {
                Circle()
                    .fill(.thinMaterial)
                    .overlay {
                        Circle()
                            .fill(configuration.isPressed ? LemonChrome.buttonPressedFill : .clear)
                    }
            }
            .overlay(
                Circle()
                    .stroke(LemonChrome.subtleBorder, lineWidth: 1)
            )
            .shadow(color: LemonChrome.shadow, radius: 5, x: 0, y: 2)
    }
}

private struct LemonWindowBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            ZStack {
                Rectangle()
                    .fill(.thinMaterial)

                LinearGradient(
                    colors: [
                        LemonChrome.accentWash,
                        .clear,
                        LemonChrome.warmWash
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .allowsHitTesting(false)
            }
            .ignoresSafeArea()
        }
    }
}

private struct LemonSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let showsBorder: Bool
    let showsShadow: Bool

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.06),
                                    Color.white.opacity(0.01),
                                    LemonChrome.accentWash.opacity(0.22)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

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
    func lemonWindowBackground() -> some View {
        modifier(LemonWindowBackgroundModifier())
    }

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
