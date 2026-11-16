import AppKit
import SwiftUI

struct ThemedScrollView<Content: View>: View {
    @Environment(\.palette) private var palette
    private let axes: Axis.Set
    private let track: Color?
    private let content: Content

    init(_ axes: Axis.Set = .vertical, track: Color? = nil, @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.track = track
        self.content = content()
    }

    var body: some View {
        ScrollView(axes) {
            content.background {
                ScrollbarProbe(track: track ?? palette.canvas, thumb: palette.scrollThumb)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct ScrollbarProbe: NSViewRepresentable {
    let track: Color
    let thumb: Color

    func makeNSView(context: Context) -> ScrollbarAnchor { ScrollbarAnchor() }

    func updateNSView(_ view: ScrollbarAnchor, context: Context) {
        view.track = NSColor(track)
        view.thumb = NSColor(thumb)
        view.scheduleUpdate()
    }
}

private final class ScrollbarAnchor: NSView {
    var track = NSColor.clear
    var thumb = NSColor.gray
    private var updateScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleUpdate()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleUpdate()
    }

    func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        // Let SwiftUI install the native scroll view and its scrollers before styling them.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.updateScrollbars()
        }
    }

    private func updateScrollbars() {
        guard let scrollView = enclosingScrollView else { return }
        if let current = scrollView.verticalScroller {
            update(current) { scrollView.verticalScroller = $0 }
        }
        if let current = scrollView.horizontalScroller {
            update(current) { scrollView.horizontalScroller = $0 }
        }
    }

    private func update(_ current: NSScroller, install: (NSScroller) -> Void) {
        if let scroller = current as? PaletteScroller {
            scroller.apply(track: track, thumb: thumb)
            return
        }

        let scroller = PaletteScroller(frame: current.frame)
        scroller.controlSize = current.controlSize
        scroller.target = current.target
        scroller.action = current.action
        scroller.isEnabled = current.isEnabled
        scroller.doubleValue = current.doubleValue
        scroller.knobProportion = current.knobProportion
        scroller.apply(track: track, thumb: thumb)
        install(scroller)
    }
}

private final class PaletteScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    private var track = NSColor.clear
    private var thumb = NSColor.gray

    func apply(track: NSColor, thumb: NSColor) {
        guard self.track != track || self.thumb != thumb else { return }
        self.track = track
        self.thumb = thumb
        needsDisplay = true
    }

    override func drawKnobSlot(in slot: NSRect, highlight flag: Bool) {
        guard scrollerStyle == .legacy else { return }
        track.setFill()
        slot.fill()
    }

    override func drawKnob() {
        guard isEnabled else { return }
        let vertical = bounds.height > bounds.width
        let knob = rect(for: .knob).insetBy(dx: vertical ? 3 : 1, dy: vertical ? 1 : 3)
        guard knob.width > 0, knob.height > 0 else { return }
        let radius = min(knob.width, knob.height) / 2
        thumb.setFill()
        NSBezierPath(roundedRect: knob, xRadius: radius, yRadius: radius).fill()
    }
}
