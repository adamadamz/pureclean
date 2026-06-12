import SwiftUI

/// 极简深空灰 + 绿。全 App 仅此一处定义颜色。
enum Theme {
    static let bg = Color(red: 0.086, green: 0.098, blue: 0.125)       // #161924 深空灰
    static let card = Color(red: 0.133, green: 0.149, blue: 0.184)     // #222630
    static let cardBorder = Color.white.opacity(0.06)
    static let accent = Color(red: 0.20, green: 0.80, blue: 0.478)     // #33CC7A 绿
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.42)

    static let corner: CGFloat = 16
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: Theme.corner)
                        .stroke(Theme.cardBorder, lineWidth: 1)))
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}

/// 主操作按钮（绿色，大圆角）
struct PrimaryButtonStyle: ButtonStyle {
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(enabled ? Color.black : Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .fill(enabled ? Theme.accent : Theme.card))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
