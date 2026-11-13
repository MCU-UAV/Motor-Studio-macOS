import SwiftUI
import AppKit
import MotorCore
import Observation

struct TelemetryChart: View {
    @Environment(StudioModel.self) private var model
    @State private var metrics: Set<ChartMetric> = [.position]
    @State private var autoScale = true
    @State private var horizontalZoom = true
    @State private var verticalZoom = true
    @State private var lowerY = -1.0
    @State private var upperY = 1.0
    private var selected: [ChartMetric] { ChartMetric.allCases.filter { metrics.contains($0) } }
    @State private var display = ChartDisplay()
    private var yRange: ClosedRange<Double> {
        if !autoScale, lowerY.isFinite, upperY.isFinite, lowerY < upperY { return lowerY...upperY }
        return display.range
    }
    var body: some View {
        @Bindable var model = model
        Panel("运动曲线", subtitle: "\(model.displaySide.rawValue) · ID \(model.selectedID)") {
            HStack {
                Menu {
                    ForEach(ChartMetric.allCases) { metric in
                        Toggle("\(metric.rawValue) · \(metric.unit)", isOn: Binding(get: { metrics.contains(metric) }, set: {
                            if $0 { metrics.insert(metric) } else { metrics.remove(metric) }
                        }))
                    }
                } label: { Label("曲线 · \(metrics.count)", systemImage: "waveform.path") }
                Spacer()
                Picker("记录量", selection: $model.recordingDuration) {
                    Text("30 秒").tag(30.0); Text("1 分钟").tag(60.0); Text("5 分钟").tag(300.0)
                    Text("10 分钟").tag(600.0); Text("30 分钟").tag(1800.0); Text("1 小时").tag(3600.0)
                }.frame(width: 150)
            }
            HStack(spacing: 12) {
                Toggle("自动刷新", isOn: $model.chartRefreshing)
                Toggle("自动缩放", isOn: $autoScale)
                Toggle("水平缩放", isOn: $horizontalZoom)
                Toggle("垂直缩放", isOn: $verticalZoom)
            }.toggleStyle(.checkbox).font(.system(size: 10))
            LiveTelemetryPlot(model: model, display: display, metrics: selected, autoScale: autoScale, lowerY: lowerY, upperY: upperY)
                .frame(height: 260)
            HStack {
                Text("时间窗 \(Int(model.chartWindow)) 秒").frame(width: 100, alignment: .leading)
                Button("−") { model.chartWindow = min(model.recordingDuration, model.chartWindow * 2) }
                Slider(value: $model.chartWindow, in: 1...max(1, model.recordingDuration))
                Button("＋") { model.chartWindow = max(1, model.chartWindow / 2) }
            }.font(.system(size: 10)).disabled(!horizontalZoom)
            ChartHistoryControls()
            if verticalZoom {
                HStack {
                    Text("纵轴")
                    TextField("最小值", value: $lowerY, format: .number)
                    Text("至")
                    TextField("最大值", value: $upperY, format: .number)
                    Button("放大") { zoomY(0.5) }; Button("缩小") { zoomY(2) }
                }.textFieldStyle(.roundedBorder).font(.system(size: 10))
                    .onSubmit { if lowerY < upperY { autoScale = false } }
            }
            HStack {
                IsolatedLiveView { LinkStatisticsLabel() }.frame(height: 14)
                Spacer()
                Button("刷新") { Task { await model.refreshChartFromRecording() } }
                Button("清空") { model.clearRecording() }
                SaveRecordingButton()
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .onChange(of: model.recordingDuration) { _, _ in model.chartWindow = min(model.chartWindow, model.recordingDuration); model.setRetention() }
        .onChange(of: model.chartWindow) { _, _ in model.refreshChart() }
        .onChange(of: model.chartOffset) { _, _ in model.refreshChart() }
        .onChange(of: model.chartRefreshing) { _, _ in model.refreshChart() }
    }
    private func zoomY(_ factor: Double) {
        let range = yRange, middle = (range.lowerBound + range.upperBound) / 2
        let half = (range.upperBound - range.lowerBound) * factor / 2
        lowerY = middle - half; upperY = middle + half; autoScale = false
    }
}

private struct LinkStatisticsLabel: View {
    @Environment(StudioModel.self) private var model
    var body: some View {
        LiveReadout(secondary: true) { model.statisticsText }.frame(height: 14)
    }
}

@MainActor final class ChartDisplay {
    var range: ClosedRange<Double> = -1...1
}
private struct ChartHistoryControls: View {
    @Environment(StudioModel.self) private var model
    var body: some View {
        @Bindable var model = model
            HStack {
                Text("历史偏移 \(Int(model.chartOffset)) 秒").frame(width: 100, alignment: .leading)
                Slider(value: $model.chartOffset, in: 0...max(1, model.historySpan - model.chartWindow))
                Button("最新") { model.chartOffset = 0; Task { await model.refreshChartFromRecording() } }
            }.font(.system(size: 10))
    }
}
private struct SaveRecordingButton: View {
    @Environment(StudioModel.self) private var model
    var body: some View {
        Button("保存 CSV") { model.exportCSV() }.disabled(!model.hasRecording || model.exporting)
    }
}
