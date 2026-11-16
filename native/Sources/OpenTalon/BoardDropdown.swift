import SwiftUI

struct BoardDropdown<Value: Hashable>: View {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var enabled
    @Binding var selection: Value
    let title: String
    let symbol: String
    let choices: [Value]
    var compact = false
    var symbolColor: Color? = nil
    var agentBrand: ((Value) -> Agent)? = nil
    let label: (Value) -> String

    @State private var isOpen = false
    @State private var highlighted: Int?
    @State private var hovered: Int?
    @State private var triggerHovered = false
    @FocusState private var menuFocused: Bool

    var body: some View {
        Button {
            highlighted = choices.firstIndex(of: selection)
            isOpen.toggle()
        } label: {
            HStack(spacing: 10) {
                Group {
                    if let agentBrand {
                        AgentBrandIcon(agent: agentBrand(selection))
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(symbolColor ?? palette.accent)
                    }
                }
                .frame(width: compact ? 16 : 29, height: compact ? 16 : 29)
                .background(palette.accent.opacity(compact ? 0 : 0.11), in: .rect(cornerRadius: 8))
                if compact {
                    valueLabel
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(palette.muted)
                        valueLabel
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .foregroundStyle(palette.muted)
            }
            .padding(.horizontal, compact ? 12 : 10)
            .frame(height: compact ? 34 : 50)
            .glassControl(
                in: RoundedRectangle(cornerRadius: compact ? 17 : 13),
                tint: triggerHovered || isOpen ? palette.accent.opacity(0.16) : nil,
                fill: triggerHovered || isOpen ? palette.hover : palette.card,
                interactive: enabled
            )
            .contentShape(.rect(cornerRadius: compact ? 17 : 13))
        }
        .buttonStyle(.plain)
        .onHover { triggerHovered = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(label(selection))
        .disabled(choices.isEmpty)
        .opacity(enabled && !choices.isEmpty ? 1 : 0.46)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) { options }
        .onChange(of: isOpen) { _, open in
            if !open { hovered = nil }
        }
    }

    private var valueLabel: some View {
        Text(label(selection))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(palette.text)
            .lineLimit(1)
    }

    private var options: some View {
        ScrollViewReader { scroll in
            ThemedScrollView(track: palette.card) {
                VStack(spacing: 3) {
                    ForEach(choices.indices, id: \.self) { index in
                        choiceRow(index)
                            .id(index)
                    }
                }
                .padding(7)
            }
            .frame(width: 236, height: min(CGFloat(choices.count * 37 + 11), 310))
            .scrollBounceBehavior(.basedOnSize)
            .surface(12)
            .focusable()
            .focused($menuFocused)
            .focusEffectDisabled()
            .onAppear {
                menuFocused = true
                if let highlighted { scroll.scrollTo(highlighted) }
            }
            .onKeyPress(.upArrow) { moveHighlight(by: -1, scroll: scroll) }
            .onKeyPress(.downArrow) { moveHighlight(by: 1, scroll: scroll) }
            .onKeyPress(.return) {
                guard let highlighted else { return .ignored }
                choose(highlighted)
                return .handled
            }
            .onExitCommand { isOpen = false }
        }
    }

    private func choiceRow(_ index: Int) -> some View {
        let selected = choices[index] == selection
        return Button { choose(index) } label: {
            HStack(spacing: 9) {
                if let agentBrand { AgentBrandIcon(agent: agentBrand(choices[index])) }
                Text(label(choices[index]))
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(rowFill(index, selected: selected), in: .rect(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = index }
            else if hovered == index { hovered = nil }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func rowFill(_ index: Int, selected: Bool) -> Color {
        if (hovered ?? highlighted) == index { return palette.hover }
        return selected ? palette.active.opacity(0.5) : .clear
    }

    private func moveHighlight(by offset: Int, scroll: ScrollViewProxy) -> KeyPress.Result {
        guard !choices.isEmpty else { return .ignored }
        let next = min(max((highlighted ?? 0) + offset, 0), choices.count - 1)
        hovered = nil
        highlighted = next
        scroll.scrollTo(next)
        return .handled
    }

    private func choose(_ index: Int) {
        guard choices.indices.contains(index) else { return }
        selection = choices[index]
        isOpen = false
    }
}
