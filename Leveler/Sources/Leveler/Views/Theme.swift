import SwiftUI

enum Theme {
    static let background = Color(hex: 0xF4F5F7)
    static let card = Color.white
    static let ink = Color(hex: 0x1A1A1A)
    static let secondary = Color(hex: 0x5F6368)
    static let accent = Color(hex: 0xFF6B2C)
    static let chip = Color(hex: 0xF0F1F4)
    static let pillOff = Color(hex: 0xE1E3E7)
    static let originalLine = Color(hex: 0xB9BCC2)
    static let grid = Color(hex: 0xE6E8EC)
    static let zeroLine = Color(hex: 0xD5D8DD)

    static let spring = Animation.spring(response: 0.5, dampingFraction: 0.72)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// Cards slide up and fade in one after another when the panel opens.
struct RiseIn: ViewModifier {
    let visible: Bool
    let index: Int

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 14)
            .animation(.spring(response: 0.55, dampingFraction: 0.85).delay(Double(index) * 0.07), value: visible)
    }
}

extension View {
    func riseIn(_ visible: Bool, _ index: Int) -> some View { modifier(RiseIn(visible: visible, index: index)) }

    func card() -> some View {
        background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.card))
    }
}

/// Slight press-down effect for buttons.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// The "leveler" logo mark: a line with one calm bump.
struct LogoMark: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24, sy = rect.height / 24
        var p = Path()
        p.move(to: CGPoint(x: 3 * sx, y: 12 * sy))
        p.addLine(to: CGPoint(x: 6 * sx, y: 12 * sy))
        p.addLine(to: CGPoint(x: 8 * sx, y: 7 * sy))
        p.addLine(to: CGPoint(x: 12 * sx, y: 17 * sy))
        p.addLine(to: CGPoint(x: 14 * sx, y: 12 * sy))
        p.addLine(to: CGPoint(x: 21 * sx, y: 12 * sy))
        return p
    }
}
