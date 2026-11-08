import SwiftUI

/// Local dimensions shared by the menu-bar panel's rendering components.
enum PanelMetrics {
    static let width: CGFloat = 400
    static let height: CGFloat = 500
    static let inset: CGFloat = 12
    static let toolbarHeight: CGFloat = 48
    static let footerHeight: CGFloat = 32
    static let avatarSize: CGFloat = 28
    static let titleSize: CGFloat = 13
    static let metadataSize: CGFloat = 11
    static let toolSize: CGFloat = 28
    static let symbolSize: CGFloat = 14
}

enum PanelMotion {
    static func feedback(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.10)
    }

    static func state(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.14)
    }

    static func disclosure(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.18)
    }

    static func filter(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)
    }
}

/// Compact borderless tools share the panel surface and keep feedback local.
struct PanelToolButtonStyle: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .buttonStyle(.borderless)
            .controlSize(.small)
            .background {
                Circle()
                    .fill(Color.primary.opacity(isHovered && isEnabled ? (contrast == .increased ? 0.14 : 0.06) : 0))
                    .allowsHitTesting(false)
            }
            .animation(PanelMotion.feedback(reduceMotion: reduceMotion), value: isHovered && isEnabled)
            .onHover { isHovered = $0 }
    }

}

extension View {
    func panelToolButton() -> some View {
        modifier(PanelToolButtonStyle())
    }
}
