import SwiftUI

enum AppPalette {
    static let background = Color(
        red: 246 / 255,
        green: 241 / 255,
        blue: 231 / 255
    )
    static let ink = Color(
        red: 49 / 255,
        green: 45 / 255,
        blue: 39 / 255
    )
    static let secondary = Color(
        red: 108 / 255,
        green: 101 / 255,
        blue: 91 / 255
    )
    static let line = Color.black.opacity(0.09)
}

extension View {
    @ViewBuilder
    func adaptiveGlass(cornerRadius: CGFloat = 22) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                .regular.tint(Color.white.opacity(0.12)),
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(AppPalette.line, lineWidth: 1)
                }
        }
    }

    /// Makes the complete visual control clickable and supplies hover/press feedback.
    func interactiveButton(cornerRadius: CGFloat) -> some View {
        buttonStyle(ResponsivePlainButtonStyle(cornerRadius: cornerRadius))
            .modifier(HoverHighlight(cornerRadius: cornerRadius))
    }
}

private struct ResponsivePlainButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct HoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.white.opacity(isHovering ? 0.18 : 0))
                    .allowsHitTesting(false)
            }
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

struct AdaptiveIconButton: View {
    let symbol: String
    let help: String
    var selected = false
    let action: () -> Void

    var body: some View {
        if #available(macOS 26.0, *) {
            if selected {
                Button(action: action) { icon }
                    .buttonStyle(GlassProminentButtonStyle())
                    .help(help)
            } else {
                Button(action: action) { icon }
                    .buttonStyle(GlassButtonStyle())
                    .help(help)
            }
        } else {
            Button(action: action) {
                icon
                    .background(
                        selected ? Color.white.opacity(0.68) : Color.white.opacity(0.30),
                        in: Circle()
                    )
                    .overlay(Circle().stroke(AppPalette.line, lineWidth: 1))
            }
            .interactiveButton(cornerRadius: 19)
            .help(help)
        }
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(AppPalette.ink)
            .frame(width: 38, height: 38)
            .contentShape(Circle())
    }
}

struct AdaptiveActionButton<Label: View>: View {
    let prominent: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    init(
        prominent: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.prominent = prominent
        self.action = action
        self.label = label
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            if prominent {
                Button(action: action, label: label)
                    .buttonStyle(GlassProminentButtonStyle())
            } else {
                Button(action: action, label: label)
                    .buttonStyle(GlassButtonStyle())
            }
        } else {
            Button(action: action) {
                label()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .contentShape(Capsule())
                    .background(
                        prominent ? Color.white.opacity(0.76) : Color.white.opacity(0.38),
                        in: Capsule()
                    )
                    .overlay(Capsule().stroke(AppPalette.line, lineWidth: 1))
            }
            .interactiveButton(cornerRadius: 20)
        }
    }
}
