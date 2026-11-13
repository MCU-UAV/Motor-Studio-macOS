import SwiftUI
import MotorCore

struct MotorsPage: View {
    @Environment(StudioModel.self) private var model
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 20) {
            Panel("总线上的电机", subtitle: "MULTI-MOTOR BUS") {
                HStack(spacing: 14) {
                    Text("已选择 \(model.selectedIDs.count) / 15").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("统一应用参数", isOn: $model.unifiedControl)
                        .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11)).disabled(model.busy)
                    Button("自动检测") { model.detectMotors() }.buttonStyle(ActionStyle()).disabled(model.state != .ready && model.state != .running)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                    ForEach(0...14, id: \.self) { id in motorTile(id) }
                }
                Text("自动检测先停止通信，再逐台检测应用模式电机。引导扫描与重复 ID 修复位于设备工具。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            HStack(alignment: .top, spacing: 20) {
                Panel("实时反馈", subtitle: model.displaySide.rawValue) {
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 12) {
                            GridRow {
                                Text("参数 / 反馈").frame(width: 145, alignment: .leading)
                                ForEach(model.selectedIDs.sorted(), id: \.self) { id in
                                    Text("ID \(id)").frame(width: 110, alignment: .trailing)
                                }
                            }.foregroundStyle(StudioTheme.mint)
                            ForEach(MotorTableRow.allCases) { row in
                                GridRow {
                                    Text(row.rawValue).foregroundStyle(.secondary)
                                    ForEach(model.selectedIDs.sorted(), id: \.self) { id in
                                        Text(row.value(sample: model.telemetry[id], command: model.commands[model.broadcastControl ? 15 : id], side: model.displaySide, running: model.state == .running))
                                            .frame(width: 110, alignment: .trailing).textSelection(.enabled)
                                    }
                                }
                            }
                        }.font(.system(size: 11, design: .monospaced)).monospacedDigit()
                    }
                    if model.selectedIDs.isEmpty { Text("选择上方 ID，或扫描在线电机").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                ControlPanel().frame(width: 300)
            }
        }
    }
    private func motorTile(_ id: Int) -> some View {
        let selected = model.selectedIDs.contains(id)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(String(format: "ID %02d", id)).font(.system(size: 12, weight: .medium, design: .monospaced))
                Spacer()
                Toggle("选择 ID \(id)", isOn: Binding(get: { selected }, set: {
                    if $0 { model.selectedIDs.insert(id) } else { model.selectedIDs.remove(id) }
                })).labelsHidden().toggleStyle(.checkbox).disabled(model.busy)
            }
            HStack {
                Text(status(id)).font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Button { model.selectMotor(id) } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.plain).foregroundStyle(StudioTheme.mint).disabled(model.busy).help("编辑 ID \(id) 参数")
            }
        }.padding(14).background(selected ? StudioTheme.mint.opacity(0.07) : .black.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(selected ? StudioTheme.mint.opacity(0.3) : .white.opacity(0.07), lineWidth: 0.8))
    }
    private func status(_ id: Int) -> String {
        MotorTableRow.communication.value(sample: model.telemetry[id], command: nil,
            side: model.displaySide, running: model.state == .running)
    }
}

struct RecordingsPage: View {
    @Environment(StudioModel.self) private var model
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 20) {
            Panel("当前会话", subtitle: "SESSION RECORDING") {
                HStack(spacing: 30) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(model.recordCount)").font(.system(size: 38, weight: .light, design: .rounded)).monospacedDigit()
                        Text("记录按时间保留 · 当前 \(Int(model.recordingDuration)) 秒 · 最长 1 小时").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("清空") { model.clearRecording() }.buttonStyle(ActionStyle()).disabled(model.recordCount == 0)
                    Button { model.exportCSV() } label: { Label("导出 CSV", systemImage: "square.and.arrow.up") }
                        .buttonStyle(ActionStyle(prominent: true)).disabled(model.recordCount == 0)
                }
            }
            TelemetryChart()
            Panel("通信报文", subtitle: "WIRE DATA") {
                HStack(alignment: .top, spacing: 20) {
                    rawBlock("TX · 发送", model.demo ? "演示模式，无实际发送" : model.lastTX)
                    rawBlock("RX · 接收", model.current?.raw ?? "")
                }
                HStack {
                    Text("CRC 错误 \(model.stats.badCRC)")
                    Text("其他 ID 反馈 \(model.stats.wrongID)")
                    Spacer()
                    Toggle("转子端参考值", isOn: $model.rotorDisplay).toggleStyle(.switch).controlSize(.mini)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                if model.rotorDisplay, let sample = model.current {
                    Text(String(format: "转子位置 %.4f rad   ·   转子速度 %.4f rad/s   ·   转子扭矩 %.6f N·m",
                        sample.position * ServoProtocol.ratio, sample.speed * ServoProtocol.ratio, sample.torque / ServoProtocol.ratio))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioTheme.mint)
                    Text("控制输入可切换输出端 / 转子端；CSV 使用明确标注的输出端单位。")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Panel("运行日志", subtitle: "EVENT LOG") {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.logs.reversed()) { entry in
                        HStack(alignment: .top, spacing: 18) {
                            Text(entry.time, format: .dateTime.hour().minute().second())
                                .foregroundStyle(.tertiary).frame(width: 72, alignment: .leading)
                            Text(entry.message).foregroundStyle(entry.failure ? .orange : .secondary)
                        }.font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
        }
    }
    private func rawBlock(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value.isEmpty ? "等待报文" : value).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary).textSelection(.enabled).lineSpacing(5)
                .frame(maxWidth: .infinity, minHeight: 45, alignment: .topLeading)
        }
    }
}
