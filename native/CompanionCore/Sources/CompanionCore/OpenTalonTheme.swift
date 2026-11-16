import SwiftUI

public enum OpenTalonTheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case graphite, paper = "warm-paper", light = "native-light", system

    public var id: Self { self }
    public var title: String {
        switch self {
        case .graphite: "Graphite"
        case .paper: "Warm Paper"
        case .light: "Native Light"
        case .system: "Match System"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .graphite: .dark
        case .paper, .light: .light
        case .system: nil
        }
    }
}

public struct OpenTalonAgentMark: View {
    private let image: Image
    private let isClaude: Bool
    private let darkSurface: Bool
    private let size: CGFloat

    public init(image: Image, isClaude: Bool, darkSurface: Bool, size: CGFloat) {
        self.image = image
        self.isClaude = isClaude
        self.darkSurface = darkSurface
        self.size = size
    }

    public var body: some View {
        let needsBacking = !isClaude && darkSurface
        image
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .scaleEffect(isClaude ? 1.5 : needsBacking ? 0.75 : 1)
            .foregroundStyle(isClaude ? Color(red: 217.0 / 255, green: 119.0 / 255, blue: 87.0 / 255) : .black)
            .background {
                if needsBacking { Circle().fill(.white) }
            }
            .accessibilityHidden(true)
    }
}

public struct OpenTalonColors {
    private let theme: OpenTalonTheme

    public init(theme: OpenTalonTheme, systemScheme: ColorScheme = .light) {
        self.theme = theme == .system ? (systemScheme == .dark ? .graphite : .light) : theme
    }

    public var canvas: Color { shade(0xf5f2ec, 0x141518, 0xfafbfc) }
    public var card: Color { shade(0xfffdf9, 0x202125, 0xffffff) }
    public var text: Color { shade(0x2b2723, 0xf1f1f3, 0x1b1d21) }
    public var muted: Color { shade(0x746b61, 0xa8aab0, 0x6c717a) }
    public var line: Color { shade(0xded7cc, 0x303136, 0xe0e3e8) }
    public var accent: Color { shade(0xb9603a, 0xe4e5ea, 0x202328) }
    public var actionAccent: Color { shade(0xb9603a, 0x61d9e3, 0x056370) }
    public var tipAmountBorder: Color { theme == .light ? actionAccent.opacity(0.40) : line }
    public var danger: Color { shade(0xb44036, 0xf18d85, 0xba413a) }
    public var done: Color { shade(0x7b9472, 0x7fb08c, 0x5f9a72) }

    private func shade(_ paper: UInt32, _ graphite: UInt32, _ light: UInt32) -> Color {
        let hex = theme == .graphite ? graphite : theme == .paper ? paper : light
        return Color(
            red: Double(hex >> 16 & 255) / 255,
            green: Double(hex >> 8 & 255) / 255,
            blue: Double(hex & 255) / 255
        )
    }
}
