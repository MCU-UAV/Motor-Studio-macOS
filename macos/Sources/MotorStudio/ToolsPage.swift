import SwiftUI
import MotorCore

struct ToolsPage: View {
    @Environment(StudioModel.self) private var model
    @State private var newID = 1
    @State private var newBaud = 4_000_000
    @State private var calibrationMode: Calibration.Mode = .precise
    @State private var position = 0.0
    @State private var travel = 1.5
    @State private var forward = true
    @State private var isolated = false
    @State private var pending: MaintenanceOperation?
    @State private var showingReview = false
    private var available: Bool { model.state == .ready && !model.demo }

    var body: some View {
        VStack(spacing: 20) {
            deviceHeader
            if model.state == .maintaining || model.maintenanceProgress > 0 || model.maintenanceFailed { progressPanel }
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 20) { firmwarePanel; calibrationPanel }
                VStack(spacing: 20) { configurationPanel; bootPanel }.frame(width: 310)
            }
            Text("J288 / S288 · 独立社区实现。维护期间独占总线。协议已与安装包 SDK 离线对照，实物验收状态见工程文档。")
                .font(.system(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showingReview) { reviewSheet }
    }

    private var deviceHeader: some View {
        Panel("设备维护", subtitle: "DEVICE CARE") {
            HStack(spacing: 20) {
                Image(systemName: "cpu").font(.system(size: 32, weight: .ultraLight))
                    .foregroundStyle(StudioTheme.mint).frame(width: 56, height: 56)
                    .background(StudioTheme.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 7) {
                    Text("J288 / S288").font(.system(size: 21, weight: .medium))
                    Text(model.firmwareVersion?.description ?? "查询版本以查看固件信息")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("目标 ID", selection: Binding(get: { model.selectedID }, set: { model.selectMotor($0) })) {
                    ForEach(0...14, id: \.self) { Text(String(format: "ID %02d", $0)).tag($0) }
                }.frame(width: 125).disabled(model.busy)
                Button("查询版本") { model.maintain(.version) }
                    .buttonStyle(ActionStyle()).disabled(!available)
            }
            if model.demo {
                Label("演示模式仅用于查看界面；维护操作需要连接实际设备。", systemImage: "play.rectangle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Toggle("总线上仅连接当前这一台电机，已停止运动并固定负载", isOn: $isolated)
                .toggleStyle(.checkbox).font(.system(size: 11)).disabled(model.state == .maintaining)
        }
    }
    private var firmwarePanel: some View {
        Panel("固件更新", subtitle: "FIRMWARE") {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "arrow.down.app").font(.system(size: 32, weight: .ultraLight)).foregroundStyle(StudioTheme.blue)
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.firmware?.filename ?? "选择原厂 APP 固件").font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                    if let firmware = model.firmware {
                        Text(String(format: "App %02X.%02X  ·  %.1f KiB  ·  CRC16 %04X", firmware.version >> 8, firmware.version & 255, Double(firmware.originalSize) / 1024, firmware.crc))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(StudioTheme.mint)
                    } else {
                        Text("保留 N1215-288_APP 开头的原始文件名。支持校验、分包写入、逐包回读与启动验证。")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.padding(18).frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
            HStack {
                Button("选择 .bin…") { model.chooseFirmware() }.buttonStyle(ActionStyle()).disabled(model.state == .maintaining)
                Spacer()
                Button { if let firmware = model.firmware { review(.firmware(firmware)) } } label: {
                    Label("更新固件", systemImage: "arrow.up.circle")
                }.buttonStyle(ActionStyle(prominent: true)).disabled(!available || !isolated || model.firmware == nil)
            }
            Text("更新会擦除现有应用区。保持电源和 USB 连接；中断后可在 Bootloader 中重新执行完整更新。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private var calibrationPanel: some View {
        Panel("上电位置", subtitle: "CALIBRATION") {
            Picker("标定模式", selection: $calibrationMode) {
                ForEach(Calibration.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).disabled(model.state == .maintaining)
            HStack(spacing: 24) {
                ZStack {
                    Circle().stroke(.white.opacity(0.07), lineWidth: 9)
                    Circle().trim(from: 0.08, to: calibrationMode == .limits ? 0.72 : 0.92)
                        .stroke(AngularGradient(colors: [StudioTheme.lavender, StudioTheme.mint], center: .center), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 5) {
                        Image(systemName: "scope").font(.system(size: 25, weight: .ultraLight))
                        Text("OUTPUT").font(.system(size: 8, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                    }
                }.frame(width: 110, height: 110).padding(10).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    Text(calibrationMode.rawValue).font(.system(size: 15, weight: .medium))
                    Text(calibrationDescription).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if calibrationMode == .limits {
                        HStack {
                            field("限位 A · rad", value: $position)
                            field("有符号行程 · rad", value: $travel)
                        }
                        Toggle("正向坐标", isOn: $forward).toggleStyle(.switch).controlSize(.mini).font(.system(size: 10))
                    }
                }.disabled(model.state == .maintaining)
            }
            HStack {
                Text("App ≥ 02.0A · 输出轴弧度").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                Spacer()
                Button("写入并验证") {
                    review(.calibrate(Calibration(mode: calibrationMode, position: position, travel: travel, forward: forward)))
                }.buttonStyle(ActionStyle(prominent: true)).disabled(!available || !isolated)
            }
        }
    }
    private var configurationPanel: some View {
        Panel("总线配置", subtitle: "BUS") {
            VStack(alignment: .leading, spacing: 12) {
                Text("电机 ID").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Picker("新 ID", selection: $newID) { ForEach(0...14, id: \.self) { Text("\($0)").tag($0) } }.labelsHidden()
                    Button("修改") { review(.changeID(newID)) }.buttonStyle(ActionStyle())
                        .disabled(!available || !isolated || newID == model.selectedID)
                }
                Text("保存前检查目标 ID，保存后向新 ID 回读确认。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Divider().opacity(0.3)
            VStack(alignment: .leading, spacing: 12) {
                Text("设备波特率").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("新波特率", selection: $newBaud) {
                    Text("4 Mbps").tag(4_000_000); Text("6 Mbps").tag(6_000_000)
                }.pickerStyle(.segmented)
                Button("保存并切换主机速率") { review(.changeBaud(newBaud)) }
                    .buttonStyle(ActionStyle()).disabled(!available || !isolated)
                Text("Boot ≥ 03.0A · App ≥ 02.15").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }.disabled(model.state == .maintaining)
    }
    private var bootPanel: some View {
        Panel("诊断与引导", subtitle: "RECOVERY") {
            toolButton("查询序列号", symbol: "barcode", operation: .serialNumber)
            toolButton("清除故障", symbol: "checkmark.shield", operation: .clearError)
            toolButton("复位电机", symbol: "arrow.clockwise", operation: .restart)
            Divider().opacity(0.3)
            toolButton("进入 Bootloader", symbol: "internaldrive", operation: .enterBootloader)
            toolButton("执行引导切换", symbol: "arrow.triangle.2.circlepath", operation: .switchBoot)
            HStack {
                Button("开启自动引导") { review(.automaticBoot(true)) }
                Button("关闭") { review(.automaticBoot(false)) }
            }.buttonStyle(ActionStyle()).disabled(!available || !isolated)
            Text("自动引导决定上电后的启动行为。设置保存后可执行引导切换，并查询版本确认应用已启动。")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            Divider().opacity(0.3)
            Button("修复整条总线重复 ID…") { review(.repairDuplicateIDs) }
                .buttonStyle(ActionStyle()).disabled(!available)
            Button("按顺序重排为 0…N−1…") { review(.reorderIDs) }
                .buttonStyle(ActionStyle()).disabled(!available)
            Button("扫描总线 ID") { model.scan() }.buttonStyle(ActionStyle()).disabled(!available)
            ForEach(model.discoveredDevices, id: \.serialNumber) { device in
                Text("ID \(device.oldID) → \(device.id) · SN \(device.serialNumber)")
                    .font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
            }
            Text("按序列号搜索全部电机，保留每个已有 ID 的第一台，其余分配空闲 ID。")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
    private var progressPanel: some View {
        Panel(model.maintenanceFailed ? "操作未完成" : "维护进度", subtitle: "OPERATION") {
            HStack {
                Text(model.maintenanceStage).font(.system(size: 12)).foregroundStyle(model.maintenanceFailed ? .orange : StudioTheme.mint)
                Spacer()
                Text("\(Int(model.maintenanceProgress * 100))%").font(.system(size: 20, weight: .light, design: .rounded)).monospacedDigit()
            }
            ProgressView(value: model.maintenanceProgress).tint(model.maintenanceFailed ? .orange : StudioTheme.mint)
            if model.state == .maintaining {
                HStack {
                    Text("正在独占设备连接，请保持供电。").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button("中止操作") { model.cancelMaintenance() }.buttonStyle(ActionStyle())
                }
            }
            if model.maintenanceFailed {
                Text("当前阶段已保留。升级中断后保留供电，重新选择固件并完整更新；改 ID 或速率中断后分别检查新旧值。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            DisclosureGroup("阶段记录") {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(model.maintenanceHistory.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private var reviewSheet: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(StudioTheme.mint)
            Text(pending?.title ?? "设备操作").font(.system(size: 24, weight: .medium))
            Text(pendingIsBusOperation ? "目标：J288 / S288 · 整条总线" : "目标：J288 / S288 · ID \(model.selectedID)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            Text(reviewDescription).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("取消") { showingReview = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("执行") {
                    showingReview = false
                    if let pending { model.maintain(pending) }
                }.buttonStyle(ActionStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }.padding(32).frame(width: 460).background(StudioBackground())
    }
    private var calibrationDescription: String {
        switch calibrationMode {
        case .factory: return "恢复出厂上电位置范围。应用会检查设备返回的模式确认。"
        case .precise: return "启用高精度上电位置模式，使用零行程配置并检查扩展模式标志。"
        case .limits: return "将输出轴置于限位 A，再填写 A 的坐标及到另一限位的有符号行程。范围均为 ±2π。"
        }
    }
    private var pendingIsBusOperation: Bool {
        guard let pending else { return false }
        switch pending { case .scanIDs, .repairDuplicateIDs, .reorderIDs: return true; default: return false }
    }
    private var reviewDescription: String {
        guard let pending else { return "" }
        switch pending {
        case .scanIDs: return "广播停止并复位总线，读取全部响应 ID。扫描不改写 ID。"
        case .repairDuplicateIDs: return "停止并复位整条总线，按唯一序列号搜索全部电机；保留已有唯一 ID，给重复项分配空闲 ID，保存后引导切换。"
        case .reorderIDs: return "停止并复位整条总线，按原 ID 和序列号排序，将全部电机重新编号为 0…N−1，保存后引导切换。"
        case .firmware(let f): return "将写入 \(f.filename)，擦除原应用区，更新后启用自动引导。保持电源与 USB 连接，完成逐包回读和版本验证后才显示成功。"
        case .changeID(let id): return "将 ID \(model.selectedID) 改为 \(id) 并保存。总线上应仅连接这一台电机。"
        case .changeBaud(let baud): return "将电机与本机串口切换到 \(baud) bps，并等待新速率下的反馈。"
        case .calibrate(let c): return c.mode == .limits ? String(format: "写入限位 A %.4f rad、行程 %.4f rad，%@坐标。请确认电机当前位于限位 A。", c.position, c.travel, c.forward ? "正向" : "反向") : "写入\(c.mode.rawValue)设置，并检查设备回读。"
        case .automaticBoot(let enabled): return enabled ? "保存自动引导开启设置，使电机上电后进入应用。" : "保存自动引导关闭设置，电机上电后可能停留在 Bootloader，普通控制暂不可用。"
        case .enterBootloader: return "复位设备并临时保持 Bootloader，用于更新或恢复固件。"
        case .switchBoot: return "执行原 SDK 的 Swmotor 引导切换指令，结果取决于设备当前引导配置。"
        case .restart: return "复位当前电机，随后验证停止模式反馈。"
        default: return "向当前电机执行操作并检查返回结果。"
        }
    }
    private func review(_ operation: MaintenanceOperation) { pending = operation; showingReview = true }
    private func toolButton(_ title: String, symbol: String, operation: MaintenanceOperation) -> some View {
        Button { review(operation) } label: {
            HStack { Image(systemName: symbol).frame(width: 20); Text(title); Spacer(); Image(systemName: "chevron.right").font(.system(size: 9)) }
        }.buttonStyle(ActionStyle()).disabled(!available || !isolated)
    }
    private func field(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            TextField(title, value: value, format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
        }
    }
}
