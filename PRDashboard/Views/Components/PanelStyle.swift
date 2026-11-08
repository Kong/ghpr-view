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
}

/// One native material layer per functional toolbar/footer button.
struct PanelToolButtonStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.buttonStyle(.glass)
                .controlSize(.small)
                .overlay(border)
        } else {
            content.buttonStyle(.bordered)
                .controlSize(.small)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(border)
        }
    }

    @ViewBuilder
    private var border: some View {
        if contrast == .increased {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    func panelToolButton() -> some View {
        modifier(PanelToolButtonStyle())
    }
}
