import SwiftUI
import Charts
import MotorCore

struct StudioView: View {
    @Environment(StudioModel.self) private var model
    var body: some View {
        GeometryReader { _ in
        ZStack {
            StudioBackground()
            HStack(spacing: 0) {
                sidebar.frame(width: 220)
                Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
                VStack(spacing: 0) {
                    header.padding(.horizontal, 30).padding(.top, 25).padding(.bottom, 20)
                    ScrollView {
                        VStack(spacing: 20) {
                            ConnectionBar()
                            if model.demo {
                                HStack(spacing: 8) {
                                    Image(systemName: "sparkles")
                                    Text("演示模式 · 模拟设备与曲线，不会向串口发送数据")
                                    Spacer()
                                }.font(.system(size: 11)).foregroundStyle(StudioTheme.lavender)
                            }
                            switch model.page {
                            case .overview: OverviewPage()
                            case .motors: MotorsPage()
                            case .recordings: RecordingsPage()
                            case .tools: ToolsPage()
                            }
                        }.padding(.horizontal, 30).padding(.bottom, 28)
                    }
                    footer
                }
            }
        }
        }
        .frame(minWidth: 1180, minHeight: 780)
        .tint(StudioTheme.mint)
        .alert("Motor Studio", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("知道了", role: .cancel) { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13).fill(StudioTheme.mint.opacity(0.14)).frame(width: 42, height: 42)
                    Image(systemName: "rotate.3d").font(.system(size: 22, weight: .medium)).foregroundStyle(StudioTheme.mint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Motor Studio").font(.system(size: 17, weight: .semibold))
                    Text("PRECISION IN MOTION").font(.system(size: 7, weight: .medium)).tracking(1.8).foregroundStyle(.secondary)
                }
            }.padding(.top, 53).padding(.bottom, 42)
            Text("工作空间").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary).padding(.bottom, 13).padding(.leading, 13)
            ForEach(StudioPage.allCases) { page in
                Button { model.page = page } label: {
                    HStack(spacing: 12) {
                        Image(systemName: page.symbol).font(.system(size: 15)).frame(width: 19)
                        Text(page.rawValue).font(.system(size: 12, weight: model.page == page ? .semibold : .regular))
                        Spacer()
                        if model.page == page { Circle().fill(StudioTheme.mint).frame(width: 4, height: 4) }
                    }.foregroundStyle(model.page == page ? StudioTheme.mint : .white.opacity(0.52))
                        .padding(.horizontal, 13).padding(.vertical, 13)
                        .background(model.page == page ? .white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).padding(.bottom, 5)
            }
            Spacer(minLength: 35)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "cpu").foregroundStyle(StudioTheme.mint)
                    Text("J288 / S288").font(.system(size: 12, weight: .semibold))
                }
                Text("无刷关节舵机").font(.system(size: 11)).foregroundStyle(.secondary)
                Divider().opacity(0.4)
                HStack {
                    Text("减速比").foregroundStyle(.secondary)
                    Spacer()
                    Text("288.35 : 1").monospacedDigit()
                }.font(.system(size: 10))
                Text("原生 macOS · 社区实现").font(.system(size: 9)).foregroundStyle(.tertiary)
            }.padding(16).studioGlass(radius: 16)
            HStack {
                Text("MOTOR STUDIO").tracking(1.6)
                Spacer()
                Text("0.1")
            }.font(.system(size: 8, weight: .medium)).foregroundStyle(.tertiary).padding(.top, 22).padding(.bottom, 22)
        }.padding(.horizontal, 18).background(.black.opacity(0.12))
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text("WORKSPACE / \(model.page == .overview ? "OVERVIEW" : model.page == .motors ? "MOTORS" : model.page == .recordings ? "RECORDINGS" : "TOOLS")")
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(.tertiary)
                Text(model.page.rawValue).font(.system(size: 28, weight: .medium))
            }
            Spacer()
            StatusPill(title: model.stateLabel, color: model.state == .running ? StudioTheme.mint : model.stopConfirmed ? .gray : .orange)
            Button { model.stop() } label: { Label("停止", systemImage: "stop.fill") }
                .buttonStyle(ActionStyle(destructive: true)).disabled(!model.connected || model.state == .stopping || model.state == .maintaining)
                .help("广播停止总线电机，并逐个验证已知 ID（⌘.）")
        }
    }
    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(model.state == .running ? StudioTheme.mint : .gray).frame(width: 4, height: 4)
            Text(model.logs.last?.message ?? "就绪").lineLimit(1)
            Spacer()
            Text("J288 / S288").foregroundStyle(.tertiary)
            Text("·").foregroundStyle(.tertiary)
            Text(model.demo ? "DEMO" : "TTL · 8N1").monospaced()
        }.font(.system(size: 9)).foregroundStyle(.secondary)
            .padding(.horizontal, 30).padding(.vertical, 11).background(.black.opacity(0.12))
    }
}

struct ConnectionBar: View {
    @Environment(StudioModel.self) private var model
    var body: some View {
        @Bindable var model = model
        HStack(spacing: 18) {
            Image(systemName: "cable.connector").font(.system(size: 21, weight: .light)).foregroundStyle(StudioTheme.mint)
            VStack(alignment: .leading, spacing: 5) {
                Text("连接设备").font(.system(size: 10)).foregroundStyle(.secondary)
                Picker("串口", selection: $model.port) {
                    if model.ports.isEmpty { Text("未发现串口").tag("") }
                    ForEach(model.ports, id: \.self) { Text($0.replacingOccurrences(of: "/dev/", with: "")).tag($0) }
                }.labelsHidden().frame(minWidth: 180, maxWidth: 270).disabled(model.state != .disconnected || model.demo)
            }
            Button { model.refreshPorts() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.state != .disconnected).help("刷新串口")
            Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text("当前波特率").font(.system(size: 10)).foregroundStyle(.secondary)
                Picker("波特率", selection: $model.baud) {
                    Text("6 Mbps").tag(6_000_000); Text("4 Mbps").tag(4_000_000)
                }.labelsHidden().frame(width: 100).disabled(model.state != .disconnected || model.demo)
            }
            Spacer(minLength: 0)
            Toggle("演示", isOn: $model.demo).toggleStyle(.switch).controlSize(.mini)
                .font(.system(size: 11)).disabled(model.state != .disconnected)
            Button(model.connected ? "断开" : "连接") {
                if model.connected { model.stop(disconnect: true) } else { model.connect() }
            }.buttonStyle(ActionStyle(prominent: !model.connected))
                .disabled(model.state == .connecting || model.state == .stopping || model.state == .maintaining)
        }.padding(.horizontal, 20).padding(.vertical, 16).studioGlass(radius: 18, interactive: true)
    }
}

struct OverviewPage: View {
    var body: some View {
        VStack(spacing: 20) {
            IsolatedLiveView { TelemetryMetrics() }.frame(height: 156)
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 20) {
                    TelemetryChart()
                    IsolatedLiveView { FeedbackPanel() }.frame(height: 252)
                }.frame(maxWidth: .infinity)
                ControlPanel().frame(width: 300)
            }
        }
    }
}

struct MetricCard: View {
    let title: String; let value: () -> Double?; let unit: String; let symbol: String; let color: Color
    init(_ title: String, value: @escaping () -> Double?, unit: String, symbol: String, color: Color) {
        self.title = title; self.value = value; self.unit = unit; self.symbol = symbol; self.color = color
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(); Image(systemName: symbol).font(.system(size: 18, weight: .light)).foregroundStyle(color)
            }
            HStack(alignment: .center, spacing: 7) {
                LiveReadout(size: 34) { value().map { String(format: "%.3f", $0) } ?? "—" }.frame(height: 42)
                Text(unit).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 5) {
                Capsule().fill(color.opacity(0.7)).frame(width: 16, height: 2)
                LiveReadout(size: 8, secondary: true) { value() == nil ? "等待设备反馈" : "IDLE / LIVE FEEDBACK" }.frame(height: 12)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).studioGlass()
    }
}

struct FeedbackPanel: View {
    @Environment(StudioModel.self) private var model
    var body: some View {
        Panel("设备状态", subtitle: "MOTOR HEALTH") {
            HStack(spacing: 0) {
                health("thermometer.medium", "驱动温度", model.health[model.selectedID].map { "\($0.temperature)°" } ?? "—")
                Spacer(); health("thermometer.sun", "绕组温度", model.health[model.selectedID].map { "\($0.winding)°" } ?? "—")
                Spacer(); health("bolt", "输入电压", model.health[model.selectedID].map { String(format: "%.1f V", Double($0.millivolts) / 1000) } ?? "—")
            }
            Divider().opacity(0.25)
            HStack {
                Text("故障 / 警告").foregroundStyle(.secondary)
                Spacer()
                Text(model.health[model.selectedID].map { String(format: "0x%08X / %d", $0.error, $0.warning) } ?? "无反馈")
                    .monospaced().foregroundStyle(model.health[model.selectedID]?.error == 0 ? StudioTheme.mint : .secondary)
            }.font(.system(size: 10))
            EncoderFeedback()
            HStack {
                Text("模式 / 超时状态").foregroundStyle(.secondary)
                Spacer()
                Text(model.health[model.selectedID].map { "\($0.mode == 0 ? "Stop" : $0.mode == 1 ? "FOC" : String($0.mode)) / \($0.timedOut ? "已触发" : "正常")" } ?? "无反馈")
            }.font(.system(size: 10))
        }
    }
    private func health(_ symbol: String, _ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: symbol).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .light, design: .rounded)).monospacedDigit()
        }
    }
}

private struct EncoderFeedback: View {
    @Environment(StudioModel.self) private var model
    var body: some View {
        HStack {
            Text("输出编码器").foregroundStyle(.secondary)
            Spacer()
            LiveReadout(alignment: .right) { model.current.map { String(format: "%.4f rad", $0.encoderPosition) } ?? "—" }.frame(width: 150, height: 14)
        }.font(.system(size: 10))
    }
}

struct ControlPanel: View {
    @Environment(StudioModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Panel("控制参数", subtitle: "CONTROL") {
            HStack {
                Text("目标电机").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Picker("目标电机", selection: Binding(get: { model.selectedID }, set: { model.selectMotor($0) })) {
                    ForEach(0...14, id: \.self) { Text(String(format: "ID %02d", $0)).tag($0) }
                }.labelsHidden().frame(width: 94).disabled(model.busy)
            }
            Toggle("广播控制全部电机", isOn: $model.broadcastControl)
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11)).disabled(model.busy)
            if model.broadcastControl {
                Text("ID 15 · 全总线统一参数。启动前检测并确认保护；额外逐台监测约 10 Hz，发送统计包含监测帧。运行时请勿增接电机。")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
            Picker("控制单位", selection: Binding(get: { model.displaySide }, set: { model.setControlSide($0) })) {
                ForEach(ControlSide.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Toggle("加入本次通信", isOn: Binding(get: { model.selectedIDs.contains(model.selectedID) }, set: {
                if $0 { model.selectedIDs.insert(model.selectedID) } else { model.selectedIDs.remove(model.selectedID) }
            })).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11)).disabled(model.busy)
            VStack(alignment: .leading, spacing: 8) {
                Text("运行模式").font(.system(size: 10)).foregroundStyle(.secondary)
                Picker("运行模式", selection: Binding(get: { model.draft.mode }, set: { mode in
                    if mode == .stop {
                        model.draft = MotorCommand(id: model.selectedID, timeoutProtection: model.draft.timeoutProtection, side: model.displaySide)
                    } else { model.draft.mode = mode }
                    if model.realtimeInput { _ = model.applyDraft(quiet: true) }
                })) {
                    Text("停止").tag(MotorMode.stop); Text("闭环控制").tag(MotorMode.foc)
                }.pickerStyle(.segmented)
            }
            Divider().opacity(0.25)
            VStack(spacing: 14) {
                parameter("目标位置", unit: "rad", value: $model.draft.position)
                parameter("目标速度", unit: "rad/s", value: $model.draft.speed)
                parameter("前馈扭矩", unit: "N·m", value: $model.draft.torque)
                HStack(spacing: 12) {
                    gain("位置增益", short: "Kp", value: $model.draft.kp)
                    gain("速度增益", short: "Kd", value: $model.draft.kd)
                }
            }.disabled(model.draft.mode == .stop)
            VStack(spacing: 9) {
                HStack {
                    Text("总线目标频率").foregroundStyle(.secondary)
                    Spacer()
                    ControlNumberField(title: "通信频率", value: $model.frequency, appliesControl: false)
                        .frame(width: 75).textFieldStyle(.roundedBorder).disabled(model.busy)
                    Text("Hz")
                }.font(.system(size: 10))
                Slider(value: $model.frequency, in: 0...10000, step: 1).controlSize(.mini).disabled(model.busy)
            }
            Text("0 Hz 暂停发送 · 频率为总线发送目标").font(.system(size: 9)).foregroundStyle(.secondary)
            Label("控制期间保持超时保护", systemImage: "checkmark.shield")
                .font(.system(size: 10)).foregroundStyle(StudioTheme.mint)
            Picker("输入方式", selection: $model.realtimeInput) {
                Text("回车 / 应用").tag(false); Text("实时输入").tag(true)
            }.pickerStyle(.segmented)
            Picker("通信方式", selection: $model.asynchronous) {
                Text("同步").tag(false); Text("异步").tag(true)
            }.pickerStyle(.segmented).disabled(model.busy)
            Text("当前使用\(model.displaySide.rawValue)单位；切换时换算现有参数。实际频率取决于设备响应。")
                .font(.system(size: 9)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("应用") { _ = model.applyDraft() }.buttonStyle(ActionStyle())
                    .disabled(model.state != .ready && model.state != .running)
                Button { if model.state == .running { model.stop() } else { model.start() } } label: {
                    Label(model.state == .running ? "停止通信" : "开始通信", systemImage: model.state == .running ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(ActionStyle(prominent: true)).disabled(model.state != .ready && model.state != .running)
            }
        }
    }
    private func parameter(_ title: String, unit: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            HStack {
                ControlNumberField(title: title, value: value)
                    .textFieldStyle(.plain).font(.system(size: 17, weight: .light, design: .monospaced))
                Text(unit).font(.system(size: 9)).foregroundStyle(.tertiary)
            }.padding(11).background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.065), lineWidth: 0.7))
        }
    }
    private func gain(_ title: String, short: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(title) · \(short)").font(.system(size: 9)).foregroundStyle(.secondary)
            ControlNumberField(title: title, value: value)
                .textFieldStyle(.plain).monospacedDigit().padding(11)
                .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// String editing is intentional: numeric-format TextField commits only on return on macOS.
private struct ControlNumberField: View {
    @Environment(StudioModel.self) private var model
    let title: String
    @Binding var value: Double
    var appliesControl = true
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField(title, text: $text)
            .focused($focused)
            .onAppear { text = String(value); model.invalidControlFields.remove(title) }
            .onChange(of: value) { _, new in if Double(text) != new { text = String(new) } }
            .onChange(of: text) { _, new in
                guard focused else { return }
                guard let number = Double(new), number.isFinite else {
                    model.invalidControlFields.insert(title); return
                }
                model.invalidControlFields.remove(title)
                value = number
                if model.realtimeInput && appliesControl { _ = model.applyDraft(quiet: true) }
            }
            .onSubmit {
                guard let number = Double(text), number.isFinite else { model.notice = "请输入有效数字"; return }
                model.invalidControlFields.remove(title)
                if appliesControl { value = number; _ = model.applyDraft() }
                else { value = (try? ControlFrequency.normalized(number)) ?? value }
            }
            .overlay(alignment: .trailing) {
                if model.invalidControlFields.contains(title) { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
            }
            .onChange(of: focused) { _, active in
                if !active, let number = Double(text), number.isFinite { value = number }
            }
    }
}

private struct TelemetryMetrics: View {
    @Environment(StudioModel.self) private var model
    var body: some View {
            HStack(spacing: 14) {
                MetricCard("\(model.displaySide.rawValue)位置", value: { model.current.map { model.displaySide.position($0.position) } }, unit: "rad", symbol: "location.north.circle", color: StudioTheme.mint)
                MetricCard("\(model.displaySide.rawValue)速度", value: { model.current.map { model.displaySide.position($0.speed) } }, unit: "rad/s", symbol: "speedometer", color: StudioTheme.blue)
                MetricCard("\(model.displaySide.rawValue)扭矩", value: { model.current.map { model.displaySide.torque($0.torque) } }, unit: "N·m", symbol: "rotate.right", color: StudioTheme.lavender)
            }
    }
}
