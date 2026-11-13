import AppKit
import Observation
import SwiftUI

/// Observe the value in the native view, outside SwiftUI body/layout evaluation.
/// The parent owns the size; changing digits only invalidates this view's pixels.
struct LiveReadout: NSViewRepresentable {
    var size: CGFloat = 10
    var alignment: NSTextAlignment = .left
    var secondary = false
    let value: @MainActor () -> String

    func makeNSView(context: Context) -> ReadoutView { ReadoutView() }
    func updateNSView(_ view: ReadoutView, context: Context) {
        view.configure(size: size, alignment: alignment, secondary: secondary, value: value)
    }
    static func dismantleNSView(_ view: ReadoutView, coordinator: ()) { view.stop() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReadoutView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 140, height: proposal.height ?? ceil(size * 1.4))
    }
}

@MainActor final class ReadoutView: NSView {
    private var value: (@MainActor () -> String)?
    private var generation = 0
    private var fontSize: CGFloat = 10
    private var alignment: NSTextAlignment = .left
    private var secondary = false
    private var text: String?
    private var attributed = NSAttributedString()
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(size: CGFloat, alignment: NSTextAlignment, secondary: Bool, value: @escaping @MainActor () -> String) {
        if size != fontSize || alignment != self.alignment || secondary != self.secondary { text = nil }
        fontSize = size; self.alignment = alignment; self.secondary = secondary; self.value = value
        generation += 1
        enqueueRefresh(generation)
    }
    func stop() { generation += 1; value = nil }
    private func enqueueRefresh(_ expected: Int) {
        // Do not evaluate the model inside updateNSView: that registers the
        // dependency with the enclosing SwiftUI graph and defeats the boundary.
        DispatchQueue.main.async { [weak self] in self?.refresh(expected) }
    }
    private func refresh(_ expected: Int) {
        guard generation == expected, let value else { return }
        let next = withObservationTracking { value() } onChange: { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.refresh(expected) }
        }
        guard next != text else { return }
        text = next
        let style = NSMutableParagraphStyle(); style.alignment = alignment; style.lineBreakMode = .byTruncatingTail
        let base = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: fontSize > 20 ? .light : .regular)
        let font = fontSize > 20 ? NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: fontSize) ?? base : base
        attributed = NSAttributedString(string: next, attributes: [
            .font: font, .foregroundColor: secondary ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: style])
        setAccessibilityValue(next)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let height = ceil(fontSize * 1.4)
        attributed.draw(in: CGRect(x: 0, y: max(0, (bounds.height - height) / 2), width: bounds.width, height: height))
    }
}
