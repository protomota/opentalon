import CompanionCore
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double(hex >> 16 & 255) / 255,
            green: Double(hex >> 8 & 255) / 255,
            blue: Double(hex & 255) / 255
        )
    }
}

struct Palette {
    var theme: Theme
    var dark: Bool { theme == .graphite }
    var paper: Bool { theme == .paper }
    private var colors: OpenTalonColors { OpenTalonColors(theme: theme) }
    var canvas: Color { colors.canvas }
    var sidebar: Color { shade(0xeae3d9, 0x101114, 0xeef0f3) }
    var card: Color { colors.card }
    var panel: Color { shade(0xfaf7f1, 0x191a1e, 0xffffff) }
    var text: Color { colors.text }
    var muted: Color { colors.muted }
    var scrollThumb: Color { shade(0x927969, 0x767985, 0x76818f) }
    var line: Color { colors.line }
    var well: Color { shade(0xece6dc, 0x18191d, 0xf0f2f5) }
    var hover: Color { shade(0xe4dacd, 0x24252b, 0xe4e7ec) }
    var active: Color { shade(0xe7cdbb, 0x303139, 0xdde1e7) }
    var accent: Color { colors.accent }
    var actionAccent: Color { colors.actionAccent }
    var accentText: Color { shade(0xfffdf9, 0x1e1f25, 0xffffff) }
    var danger: Color { colors.danger }

    private func shade(_ paperValue: UInt32, _ darkValue: UInt32, _ lightValue: UInt32) -> Color {
        Color(hex: dark ? darkValue : paper ? paperValue : lightValue)
    }

    func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: paper ? .serif : .default)
    }

    func flow(_ status: WorkStatus) -> Color {
        switch status {
        case .todo: shade(0xcfc6b8, 0x4a4c55, 0xd3d7de)
        case .sent: shade(0xc99b45, 0xc9a45c, 0xc79a3b)
        case .working: shade(0xb9603a, 0x8ea4dc, 0x4f6fae)
        case .done: colors.done
        }
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette(theme: .light)
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

struct Surface: ViewModifier {
    @Environment(\.palette) private var palette
    var radius: CGFloat
    var fill: Color?
    func body(content: Content) -> some View {
        content
            .background(fill ?? palette.card, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(palette.line).allowsHitTesting(false))
    }
}

extension View {
    func surface(_ radius: CGFloat = 8, fill: Color? = nil) -> some View {
        modifier(Surface(radius: radius, fill: fill))
    }
}

struct GlassActionStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var enabled
    var prominent = false
    var height: CGFloat = 30

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        let destructive = configuration.role == .destructive
        let emphasized = prominent && !destructive
        let label = configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, prominent ? 15 : 12)
            .frame(minHeight: height)
        if enabled {
            label
                .foregroundStyle(emphasized ? palette.accentText : destructive ? palette.danger : palette.text)
                .glassControl(
                    in: Capsule(),
                    tint: emphasized ? palette.accent : nil,
                    fill: emphasized ? palette.accent : configuration.isPressed ? palette.hover : palette.card
                )
                .contentShape(Capsule())
                .opacity(configuration.isPressed ? 0.8 : 1)
        } else {
            label.foregroundStyle(palette.muted)
                .overlay { Capsule().strokeBorder(palette.line).allowsHitTesting(false) }
        }
    }
}

struct GlassToggleStyle: ToggleStyle {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 9) {
                Capsule()
                    .fill(configuration.isOn ? palette.accent : palette.well)
                    .overlay { Capsule().strokeBorder(palette.line.opacity(configuration.isOn ? 0 : 1)) }
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(configuration.isOn ? palette.accentText : palette.text.opacity(0.53))
                            .frame(width: 12, height: 12)
                            .padding(3)
                    }
                    .frame(width: 31, height: 18)
                configuration.label
                    .foregroundStyle(palette.text)
            }
            .frame(minHeight: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.46)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

struct IconButton: View {
    var symbol: String
    var label: String
    var action: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(hovered ? palette.hover : .clear, in: .rect(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

struct PriorityBadge: View {
    @Environment(\.palette) private var palette
    let priority: Priority
    var body: some View {
        let color = priority == .none ? palette.muted : priority.color(palette.dark)
        Label(priority.label, systemImage: priority == .none ? "minus" : "chart.bar.fill")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.10), in: .rect(cornerRadius: 4))
            .fixedSize()
    }
}

struct ProjectIcon: View {
    let key: String?
    var size: CGFloat = 14

    var body: some View {
        Group {
            if key == "feather" {
                FeatherOutline().stroke(style: StrokeStyle(lineWidth: size / 12, lineCap: .round, lineJoin: .round))
            } else {
                Image(systemName: BoardIcons.symbol(key)).font(.system(size: size))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct FeatherOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var outline = Path()
        outline.move(to: CGPoint(x: 20.2, y: 12.2))
        outline.addCurve(to: CGPoint(x: 11.8, y: 3.8), control1: CGPoint(x: 26, y: 6.4), control2: CGPoint(x: 17.6, y: -2))
        outline.addLines([CGPoint(x: 2, y: 13.5), CGPoint(x: 2, y: 22), CGPoint(x: 10.5, y: 22), CGPoint(x: 20.2, y: 12.2)])
        outline.move(to: CGPoint(x: 16, y: 8))
        outline.addLine(to: CGPoint(x: 2, y: 22))
        outline.move(to: CGPoint(x: 9, y: 15))
        outline.addLine(to: CGPoint(x: 17.4, y: 15))
        return outline.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}

enum Artwork {
    static let protomota = Bundle.main.url(forResource: "protomota-logo", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    static let wordmark = Bundle.main.url(forResource: "wordmark", withExtension: "png").flatMap(NSImage.init(contentsOf:))
}

struct Wordmark: View {
    @Environment(\.palette) private var palette
    var body: some View {
        Group {
            if let wordmark = Artwork.wordmark {
                Image(nsImage: wordmark).renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 181, height: 38)
            } else {
                Text("OpenTalon").font(.system(size: 24, weight: .black))
            }
        }
        .foregroundStyle(palette.dark ? .white : .black)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("OpenTalon")
    }
}

extension View {
    func glassPrimary() -> some View {
        buttonStyle(GlassActionStyle(prominent: true, height: 35))
    }

    func glassControl<S: Shape>(in shape: S, tint: Color? = nil, fill: Color, interactive: Bool = true) -> some View {
        modifier(GlassControlSurface(shape: shape, tint: tint, fill: fill, interactive: interactive))
    }

    @ViewBuilder
    func glassSearchSurface() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            surface(7)
        }
    }
}

private struct GlassControlSurface<S: Shape>: ViewModifier {
    @Environment(\.palette) private var palette
    var shape: S
    var tint: Color?
    var fill: Color
    var interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content.background(fill, in: shape)
                .overlay { shape.stroke(palette.line, lineWidth: 1).allowsHitTesting(false) }
        }
    }
}

struct GlassCommandGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 5) { content() }
        } else {
            content()
        }
    }
}
