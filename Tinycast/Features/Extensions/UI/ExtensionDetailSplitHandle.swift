import AppKit
import SwiftUI

/// The list/detail seam's invisible drag strip: the hairline stays a sibling, this adds the handle.
struct ExtensionDetailSplitHandle: NSViewRepresentable {
    var onBegan: () -> Void
    var onDragged: (CGFloat) -> Void
    var onEnded: () -> Void
    var onReset: () -> Void

    func makeNSView(context: Context) -> NSView { SplitHandleView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? SplitHandleView else { return }
        view.bind(onBegan: onBegan, onDragged: onDragged, onEnded: onEnded, onReset: onReset)
    }
}

/// Tracks the press itself: a nested tracking loop is the only thing that says when the mouse rose.
private final class SplitHandleView: NSView {
    /// Slop before a press is a drag, so a click on the seam never nudges the split.
    private static let dragSlop: CGFloat = 3
    /// A mark sized against itself rather than the content, like `hairline`.
    private static let gripWidth: CGFloat = 3
    private static let gripHeight: CGFloat = 20

    private var onBegan: (() -> Void)?
    private var onDragged: ((CGFloat) -> Void)?
    private var onEnded: (() -> Void)?
    private var onReset: (() -> Void)?
    private var isHovered = false
    private var isDragging = false
    private var hoverTracking: NSTrackingArea?

    func bind(
        onBegan: @escaping () -> Void,
        onDragged: @escaping (CGFloat) -> Void,
        onEnded: @escaping () -> Void,
        onReset: @escaping () -> Void
    ) {
        self.onBegan = onBegan
        self.onDragged = onDragged
        self.onEnded = onEnded
        self.onReset = onReset
    }

    private var showsGrip: Bool { isHovered || isDragging }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        // `.activeAlways`: the palette is a non-activating panel, so key status is not hover's cue.
        let tracking = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    /// The first click may arrive while the palette is inactive; it still has to start the drag.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount < 2 else {
            onReset?()
            return
        }
        guard let window else { return }
        NSCursor.resizeLeftRight.set()
        let start = NSEvent.mouseLocation.x
        var dragged = false
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration,
            mode: .eventTracking
        ) { tracked, stop in
            guard let tracked, tracked.type != .leftMouseUp else {
                stop.pointee = true
                return
            }
            let translation = NSEvent.mouseLocation.x - start
            guard dragged || abs(translation) > Self.dragSlop else { return }
            if !dragged {
                dragged = true
                self.isDragging = true
                self.onBegan?()
            }
            self.onDragged?(translation)
            self.needsDisplay = true
            NSCursor.resizeLeftRight.set()
        }
        guard dragged else { return }
        isDragging = false
        onEnded?()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let hairline = Theme.Size.hairline
        let line = NSRect(
            x: ((bounds.width - hairline) / 2).rounded(), y: 0, width: hairline,
            height: bounds.height)
        NSColor(showsGrip ? Theme.Colors.border : Theme.Colors.separator).setFill()
        line.fill()
        guard showsGrip else { return }
        let grip = NSRect(
            x: ((bounds.width - Self.gripWidth) / 2).rounded(),
            y: ((bounds.height - Self.gripHeight) / 2).rounded(),
            width: Self.gripWidth, height: Self.gripHeight)
        NSColor(Theme.Colors.textTertiary).setFill()
        NSBezierPath(
            roundedRect: grip, xRadius: Self.gripWidth / 2, yRadius: Self.gripWidth / 2
        ).fill()
    }
}
