import SwiftUI

/// Colors shared with the app icon.
enum Theme {
    static let bg = Color(hex: 0x0D1321)
    static let card = Color(hex: 0x161E32)
    static let line = Color(hex: 0x26304A)
    static let text = Color(hex: 0xF2F4F8)
    static let muted = Color(hex: 0x9AA6BF)
    static let mint = Color(hex: 0x35E0C2)
    static let amber = Color(hex: 0xF5A524)
    static let red = Color(hex: 0xFF6B6B)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Rounded section container.
struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.muted)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var filled = true
    var color = Theme.mint

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(filled ? Theme.bg : color)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(filled ? color : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(color, lineWidth: filled ? 0 : 1.5))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
