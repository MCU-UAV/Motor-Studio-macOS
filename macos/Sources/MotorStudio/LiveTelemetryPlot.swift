import AppKit
import SwiftUI
import MotorCore

struct LiveTelemetryPlot: NSViewRepresentable {
    let model: StudioModel
    let display: ChartDisplay
    let metrics: [ChartMetric]
    let autoScale: Bool
    let lowerY: Double
    let upperY: Double
    func makeNSView(context: Context) -> PlotView { PlotView() }
    func updateNSView(_ view: PlotView, context: Context) {
        view.configure(model: model, display: display, metrics: metrics,
                       range: !autoScale && lowerY.isFinite && upperY.isFinite && lowerY < upperY ? lowerY...upperY : nil)
    }
    static func dismantleNSView(_ view: PlotView, coordinator: ()) { view.stop() }
}

/// A bounded, latest-only renderer. Curves are rebuilt on new data, labels on
/// changed text, and grid geometry on resize. Cursor movement reuses all three.
@MainActor final class PlotView: NSView {
    private var model: StudioModel?
    private var display: ChartDisplay?
    private var metrics: [ChartMetric] = []
    private var side: ControlSide = .output
    private var fixedRange: ClosedRange<Double>?
    private var shownRange: ClosedRange<Double> = -1...1
    private var snapshot = ChartSnapshot()
    private var timer: Timer?
    private var inFlight: Task<Void, Never>?
    private var generation = 0
    private var previousKey: RequestKey?
    private var lastRevision = -1
    private var cursorFraction: Double?
    private var cursorText: NSAttributedString?
    private var paths: [CGPath] = []
    private var mappedPaths: [CGPath] = []
    private var mappedRect = CGRect.zero
    private var mappedRange: ClosedRange<Double> = 0...1
    private var mappingDirty = true
    private var grid: CGPath?
    private var gridSize: CGRect = .zero
    private var labels: [String: NSAttributedString] = [:]
    private var legend: [NSAttributedString] = []
    private var dataStart = Date()
    private var dataDuration: Double = 1
    private var accessibilityValue = ""
    private(set) var queryCount = 0
    private(set) var pathBuildCount = 0
    private(set) var drawCount = 0
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
    private let formatter: DateFormatter = { let value = DateFormatter(); value.dateFormat = "HH:mm:ss"; return value }()
    private let colors: [NSColor] = [.systemMint, .systemBlue, .systemPurple, .systemOrange, .systemPink, .systemYellow, .systemTeal, .systemGreen]
    private struct RequestKey: Equatable {
        let id: Int, metrics: [ChartMetric], side: ControlSide
        let window: Double, offset: Double, refreshing: Bool, revision: Int
        let running: Bool, broadcast: Bool, budget: Int
    }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("运动曲线")
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func configure(model: StudioModel, display: ChartDisplay, metrics: [ChartMetric], range: ClosedRange<Double>?) {
        let appearanceChanged = self.metrics != metrics || fixedRange != range
        self.model = model; self.display = display; self.fixedRange = range
        if self.metrics != metrics {
            self.metrics = metrics
            legend = metrics.enumerated().map { i, metric in
                NSAttributedString(string: "● \(metric.rawValue) · \(metric.unit)", attributes: [.font: font, .foregroundColor: colors[i % colors.count]])
            }
        }
        if appearanceChanged { updateScale(); needsDisplay = true }
        startIfNeeded()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else { startIfNeeded() }
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }
    private func startIfNeeded() {
        guard window != nil, timer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        tick()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        generation += 1; inFlight?.cancel(); inFlight = nil
        previousKey = nil
    }
    var canRender: Bool {
        guard let window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor else { return false }
        return !visibleRect.isEmpty && bounds.width > 1 && bounds.height > 1
    }
    private var requestKey: RequestKey? {
        guard let model else { return nil }
        return RequestKey(id: model.selectedID, metrics: metrics, side: model.displaySide,
                          window: model.chartWindow, offset: model.chartOffset, refreshing: model.chartRefreshing,
                          revision: model.chartRevision, running: model.state == .running,
                          broadcast: model.broadcastControl, budget: max(32, Int(plot.width / 32) * 32))
    }
    private func tick() {
        guard canRender else { return }
        guard inFlight == nil, let key = requestKey, let model else { return }
        guard key != previousKey || (key.running && key.refreshing) else { return }
        let generation = generation
        queryCount += 1
        inFlight = Task { [weak self] in
            let next = await model.chartSnapshot(metrics: key.metrics, side: key.side, budget: key.budget)
            guard let self, self.generation == generation else { return }
            self.inFlight = nil
            guard !Task.isCancelled, key == self.requestKey, self.canRender else { return }
            guard key != self.previousKey || next.revision != self.lastRevision else { return }
            self.snapshot = next; self.side = key.side; self.lastRevision = next.revision
            self.previousKey = key; self.updateScale(); self.buildPaths(); self.updateCursor()
            self.needsDisplay = true
            let description = key.metrics.map(\.rawValue).joined(separator: "、") + "，\(next.samples.count) 个显示采样点"
            if description != self.accessibilityValue { self.accessibilityValue = description; self.setAccessibilityValue(description) }
        }
    }
    private var legendColumns: Int { max(1, Int(bounds.width / 150)) }
    private var plot: CGRect {
        let rows = max(1, (metrics.count + legendColumns - 1) / legendColumns)
        return CGRect(x: 54, y: 8, width: max(1, bounds.width - 66), height: max(60, bounds.height - 62 - CGFloat(rows * 13)))
    }
    private func updateScale() {
        if let fixedRange { shownRange = fixedRange }
        else {
            // Stable 1/2/5 tick boundaries prevent tiny numeric fluctuations from
            // relaying out axes every frame; contract when the data uses <40%.
            let target = snapshot.range, currentSpan = shownRange.upperBound - shownRange.lowerBound
            if target.lowerBound < shownRange.lowerBound || target.upperBound > shownRange.upperBound || target.upperBound - target.lowerBound < currentSpan * 0.4 {
                let desired = max(1e-9, (target.upperBound - target.lowerBound) / 4)
                let unit = pow(10, floor(log10(desired))), fraction = desired / unit
                let step = (fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 5 ? 5 : 10) * unit
                shownRange = (floor(target.lowerBound / step) * step)...(ceil(target.upperBound / step) * step)
            }
        }
        display?.range = shownRange
    }
    private func buildPaths() {
        paths = []; mappingDirty = true; pathBuildCount += 1
        dataStart = snapshot.samples.first?.time ?? .now
        dataDuration = max(0.001, (snapshot.samples.last?.time ?? dataStart.addingTimeInterval(1)).timeIntervalSince(dataStart))
        var path: CGMutablePath?, series = ""
        for point in snapshot.points where point.value.isFinite {
            let p = CGPoint(x: point.time.timeIntervalSince(dataStart) / dataDuration, y: point.value)
            if point.series != series {
                if let path { paths.append(path) }
                path = CGMutablePath(); path?.move(to: p); series = point.series
            } else { path?.addLine(to: p) }
        }
        if let path { paths.append(path) }
    }
    override func mouseDown(with event: NSEvent) { select(event) }
    override func mouseDragged(with event: NSEvent) { select(event) }
    private func select(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursorFraction = min(1, max(0, (point.x - plot.minX) / plot.width))
        updateCursor(); needsDisplay = true
    }
    private func updateCursor() {
        guard let fraction = cursorFraction, !snapshot.samples.isEmpty else { cursorText = nil; toolTip = nil; setAccessibilityHelp(nil); return }
        let time = dataStart.addingTimeInterval(dataDuration * fraction)
        var lo = 0, hi = snapshot.samples.count
        while lo < hi { let mid = (lo + hi) / 2; if snapshot.samples[mid].time < time { lo = mid + 1 } else { hi = mid } }
        let right = min(lo, snapshot.samples.count - 1), left = max(0, right - 1)
        let sample = abs(snapshot.samples[left].time.timeIntervalSince(time)) < abs(snapshot.samples[right].time.timeIntervalSince(time)) ? snapshot.samples[left] : snapshot.samples[right]
        let text = metrics.map { "\($0.rawValue) \(String(format: "%.4f", $0.value(sample, side: side))) \($0.unit)" }.joined(separator: " · ")
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        cursorText = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
        if toolTip != text { toolTip = text; setAccessibilityHelp(text) }
    }
    private func label(_ text: String, at point: CGPoint) {
        if labels[text] == nil {
            if labels.count > 100 { labels.removeAll(keepingCapacity: true) }
            labels[text] = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        }
        labels[text]?.draw(at: point)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawCount += 1
        let rect = plot, range = shownRange, span = max(1e-9, range.upperBound - range.lowerBound)
        if grid == nil || gridSize != rect {
            let path = CGMutablePath()
            for i in 0...4 { let y = rect.minY + rect.height * Double(i) / 4; path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y)) }
            grid = path; gridSize = rect
        }
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor); context.setLineWidth(0.5)
        if let grid { context.addPath(grid); context.strokePath() }
        for i in 0...4 {
            let fraction = Double(i) / 4, tick = range.upperBound - span * fraction
            label(String(format: "%.3g", abs(tick) < span * 1e-6 ? 0 : tick), at: CGPoint(x: 0, y: rect.minY + rect.height * fraction - 5))
            label(formatter.string(from: dataStart.addingTimeInterval(dataDuration * fraction)), at: CGPoint(x: rect.minX + rect.width * fraction - 23, y: rect.maxY + 6))
        }
        context.saveGState(); context.clip(to: rect)
        if mappingDirty || mappedRect != rect || mappedRange != range {
            var transform = CGAffineTransform(a: rect.width, b: 0, c: 0, d: -rect.height / span, tx: rect.minX, ty: rect.maxY + range.lowerBound * rect.height / span)
            mappedPaths = paths.compactMap { $0.copy(using: &transform) }
            mappedRect = rect; mappedRange = range; mappingDirty = false
        }
        for (i, path) in mappedPaths.enumerated() {
            context.addPath(path)
            context.setStrokeColor(colors[i % colors.count].cgColor); context.setLineWidth(1.5); context.strokePath()
        }
        if let fraction = cursorFraction {
            let x = rect.minX + rect.width * fraction
            context.setStrokeColor(NSColor.secondaryLabelColor.cgColor); context.setLineWidth(0.6)
            context.move(to: CGPoint(x: x, y: rect.minY)); context.addLine(to: CGPoint(x: x, y: rect.maxY)); context.strokePath()
        }
        context.restoreGState()
        for (i, label) in legend.enumerated() { label.draw(at: CGPoint(x: CGFloat(i % legendColumns) * 150, y: rect.maxY + 24 + CGFloat(i / legendColumns) * 13)) }
        if snapshot.points.isEmpty { label(model?.broadcastControl == true ? "广播只发送，不接收曲线反馈" : "选择曲线并开始通信", at: CGPoint(x: rect.midX - 85, y: rect.midY)) }
        cursorText?.draw(in: CGRect(x: 0, y: bounds.height - 14, width: bounds.width, height: 14))
    }
}
