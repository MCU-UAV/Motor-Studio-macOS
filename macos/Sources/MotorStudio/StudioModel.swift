import AppKit
import Observation
import Foundation
import MotorCore
import UniformTypeIdentifiers

enum StudioPage: String, CaseIterable, Identifiable {
    case overview = "电机工作台", motors = "多电机", recordings = "数据记录", tools = "设备工具"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .motors: return "square.stack.3d.up"
        case .recordings: return "waveform.path"
        case .tools: return "slider.horizontal.3"
        }
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let time = Date()
    let message: String
    var failure = false
}

struct MotorHealthDisplay: Equatable {
    let temperature: Int, winding: Int, millivolts: Int, error: UInt32, warning: Int, mode: Int, timedOut: Bool
    init(_ sample: Sample) {
        temperature = sample.temperature; winding = sample.windingTemperature
        millivolts = Int((sample.voltage * 1000).rounded()); error = sample.error
        warning = sample.warning; mode = sample.mode; timedOut = sample.timedOut
    }
}

@MainActor @Observable final class StudioModel {
    enum State: Equatable { case disconnected, connecting, ready, running, stopping, scanning, maintaining }
    var page: StudioPage = .overview
    var state: State = .disconnected
    var ports: [String] = []
    var port = ""
    var baud = ServoProtocol.baud
    var demo = false
    var selectedID = 0
    var selectedIDs: Set<Int> = [0]
    var unifiedControl = false
    var commands: [Int: MotorCommand] = [:]
    var draft = MotorCommand(mode: .foc)
    var frequency: Double = 100
    var broadcastControl = false
    var asynchronous = false
    var realtimeInput = false
    var invalidControlFields: Set<String> = []
    var displaySide: ControlSide = .output
    var discoveredDevices: [DiscoveredMotor] = []
    var telemetry: [Int: Sample] = [:]
    var health: [Int: MotorHealthDisplay] = [:]
    var statisticsText = "发送 0 · 接收 0 · 实测 0 Hz · 超时 0.0%"
    @ObservationIgnored private var lastStatisticsDisplay = ContinuousClock.now
    var recordCount = 0 { didSet { hasRecording = recordCount > 0 } }
    var hasRecording = false
    var recordingDuration: Double = 300
    var chartRefreshing = true
    var chartOffset: Double = 0
    var chartRevision = 0
    var historySpan: Double = 0
    var actualFrequency: Double = 0
    var exporting = false
    var logs: [LogEntry] = []
    var stats = LinkStatistics()
    var elapsed: Double = 0
    var notice: String?
    var rotorDisplay = false
    var lastTX = ""
    var stopConfirmed = true
    var chartWindow: Double = 10
    var firmware: FirmwareImage?
    var firmwareVersion: FirmwareVersion?
    var maintenanceProgress: Double = 0
    var maintenanceStage = "选择设备操作"
    var maintenanceFailed = false
    var temporaryBootActive = false
    var maintenanceHistory: [String] = []
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var maintenanceRunID = UUID()
    @ObservationIgnored private let session: SerialSession
    @ObservationIgnored let acquisition: AcquisitionEngine
    @ObservationIgnored private var loop: Task<AcquisitionResult, Never>?
    @ObservationIgnored private var displayTask: Task<Void, Never>?
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var commandRevision = 0
    @ObservationIgnored private var activeIDs: [Int] = []
    @ObservationIgnored private var frozenChartEnd: Date?
    @ObservationIgnored private var latestRecordTime: Date?

    var connected: Bool { state != .disconnected && state != .connecting }
    var busy: Bool { state == .running || state == .stopping || state == .scanning || state == .connecting || state == .maintaining }
    var current: Sample? { telemetry[selectedID] }
    func refreshChart() { chartRevision += 1 }
    func refreshChartNow() { frozenChartEnd = latestRecordTime; refreshChart() }
    // Manual refresh reads the record actor, independent of the slow number panel.
    func refreshChartFromRecording() async {
        frozenChartEnd = await acquisition.recordings.summary().lastTime; refreshChart()
    }
    func setRetention() {
        let retention = recordingDuration
        chartOffset = min(chartOffset, retention)
        Task { await acquisition.recordings.setRetention(retention); refreshChart() }
    }
    func chartSnapshot(metrics: [ChartMetric], side: ControlSide, budget: Int) async -> ChartSnapshot {
        let request = ChartRequest(motorID: selectedID, metrics: metrics, side: side,
                                   window: chartWindow, offset: chartOffset,
                                   end: chartRefreshing ? nil : frozenChartEnd,
                                   budget: budget, broadcast: broadcastControl && demo)
        return await acquisition.recordings.chart(request)
    }
    private func apply(_ snapshot: AcquisitionSnapshot, force: Bool = true) {
        telemetry = snapshot.telemetry; stats = snapshot.stats; lastTX = snapshot.lastTX
        if broadcastControl && !demo && !snapshot.telemetry.isEmpty {
            selectedIDs = Set(snapshot.telemetry.keys)
            if !selectedIDs.contains(selectedID), let first = selectedIDs.min() { selectMotor(first) }
        }
        health = snapshot.telemetry.mapValues(MotorHealthDisplay.init)
        elapsed = snapshot.elapsed; actualFrequency = snapshot.actualFrequency
        if force || lastStatisticsDisplay.duration(to: .now) >= .milliseconds(50) {
            statisticsText = "发送 \(String(format: "%.0f", snapshot.transmitFrequency)) Hz · 接收 \(String(format: "%.0f", actualFrequency)) Hz · 累计 \(stats.sent)/\(stats.received) · 超时 \(String(format: "%.1f", lossPercent))%"
            lastStatisticsDisplay = .now
        }
        recordCount = snapshot.records.count; historySpan = floor(snapshot.records.span)
        latestRecordTime = snapshot.records.lastTime
        if chartRefreshing { frozenChartEnd = latestRecordTime }
    }
    func setControlSide(_ side: ControlSide) {
        draft = draft.converted(to: side); displaySide = side
    }
    var stateLabel: String {
        switch state {
        case .disconnected: return "未连接"
        case .connecting: return "连接中"
        case .ready: return stopConfirmed ? "已连接 · 待机" : "停止未确认"
        case .running: return demo ? "演示运行中" : "实时通信中"
        case .stopping: return "正在停止"
        case .scanning: return "正在扫描"
        case .maintaining: return "设备维护中"
        }
    }
    var lossPercent: Double { stats.sent > 0 ? Double(stats.timeouts) / Double(stats.sent) * 100 : 0 }

    init() {
        let session = SerialSession()
        self.session = session; acquisition = AcquisitionEngine(session: session)
        refreshPorts(); log("欢迎使用 Motor Studio · J288 / S288")
    }

    func log(_ message: String, failure: Bool = false) {
        logs.append(LogEntry(message: message, failure: failure))
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }
    func report(_ error: Error) { notice = error.localizedDescription; log(error.localizedDescription, failure: true) }
    func refreshPorts() {
        ports = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.") && !$0.localizedCaseInsensitiveContains("Bluetooth") }
            .map { "/dev/" + $0 }.sorted()
        if !ports.contains(port) { port = ports.first ?? "" }
    }
    func selectMotor(_ id: Int) {
        if selectedID != id { firmwareVersion = nil }
        selectedID = id
        invalidControlFields = []
        draft = (commands[broadcastControl ? 15 : id] ?? MotorCommand(id: id, mode: .foc)).converted(to: displaySide)
        refreshChart()
    }
    private func resetControlInputs() {
        commands = [:]; invalidControlFields = []
        draft = MotorCommand(id: selectedID, side: displaySide)
    }
    func connect() {
        guard state == .disconnected else { return }
        guard demo || !port.isEmpty else { notice = "请先连接 USB 转 TTL 设备并刷新串口"; return }
        state = .connecting
        resetControlInputs()
        firmwareVersion = nil
        discoveredDevices = []; activeIDs = []
        telemetry = [:]; health = [:]; statisticsText = "发送 0 · 接收 0 · 实测 0 Hz · 超时 0.0%"; recordCount = 0; historySpan = 0; frozenChartEnd = nil; latestRecordTime = nil; chartOffset = 0; chartRevision += 1; stats = LinkStatistics(); elapsed = 0; actualFrequency = 0
        stopConfirmed = true
        Task {
            do {
                await acquisition.reset(retention: recordingDuration)
                if !demo { try await session.connect(path: port, baud: baud) }
                state = .ready
                log(demo ? "演示设备已连接；所有数据均为模拟" : "串口已打开：\(port) · \(baud) bps；尚未发送指令")
            } catch { state = .disconnected; report(error) }
        }
    }
    func applyDraft(quiet: Bool = false) -> Bool {
        guard state == .ready || state == .running else { return false }
        guard invalidControlFields.isEmpty else {
            if !quiet { notice = "请修正无效输入：" + invalidControlFields.sorted().joined(separator: "、") }
            return false
        }
        do {
            var command = try draft.clamped()
            if command != draft { draft = command; log("参数已按协议范围限幅，显示值为生效目标") }
            command.id = broadcastControl ? 15 : selectedID
            command.timeoutProtection = true
            _ = try command.encode()
            let ids = broadcastControl ? [15] : unifiedControl ? selectedIDs.sorted() : [selectedID]
            for id in ids { var copy = command; copy.id = id; commands[id] = copy }
            if state == .running {
                commandRevision += 1
                let revision = commandRevision, id = runID, updated = commands
                acquisition.commandMailbox.update(updated, runID: id, revision: revision)
            }
            if !quiet { log("参数已应用至 ID \(ids.map(String.init).joined(separator: ", "))") }
            return true
        } catch { report(error); return false }
    }
    func start() {
        guard state == .ready, broadcastControl || !selectedIDs.isEmpty else { return }
        guard broadcastControl || selectedIDs.contains(selectedID) else { notice = "请勾选当前电机 ID 后再开始"; return }
        do { frequency = try ControlFrequency.normalized(frequency) }
        catch { report(error); return }
        guard applyDraft() else { return }
        activeIDs = broadcastControl ? [15] : selectedIDs.sorted()
        for id in activeIDs where commands[id] == nil { commands[id] = MotorCommand(id: id) }
        let id = UUID(); runID = id; commandRevision = 0
        let configuration = AcquisitionConfiguration(runID: id, demo: demo, ids: activeIDs,
            commands: commands, frequency: frequency, asynchronous: asynchronous, broadcast: broadcastControl)
        let engine = acquisition
        engine.commandMailbox.prepare(configuration)
        // Detached task never inherits MainActor; stop/fault handling completes in the engine.
        let task = Task.detached(priority: .userInitiated) { await engine.run(configuration) }
        loop = task; state = .running
        log("\(demo ? "开始演示" : "启动前清除超时锁存并确认保护；通过后进入控制") · \(activeIDs.count) 个电机 · 总线目标 \(Int(frequency)) Hz")
        displayTask?.cancel()
        displayTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.runID == id, self.state == .running else { return }
                let snapshot = await engine.snapshot()
                guard !Task.isCancelled, self.runID == id, self.state == .running else { return }
                // No SwiftUI invalidations while the app is hidden/minimized.
                // Standalone runtime tests have no application window.
                let windows = NSApp?.windows ?? []
                if windows.isEmpty || windows.contains(where: { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }) {
                    self.apply(snapshot, force: false)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        Task { [weak self] in
            let result = await task.value
            guard let self, self.runID == id, self.state == .running else { return }
            self.displayTask?.cancel(); self.loop = nil
            self.apply(result.snapshot); self.stopConfirmed = result.stopConfirmed
            self.resetControlInputs()
            self.state = .ready; self.refreshChart()
            if let failure = result.failure { self.notice = failure; self.log(failure, failure: true) }
            if !result.stopConfirmed { self.reportStopFailure() }
        }
    }
    private func reportStopFailure() {
        let message = "停止未确认。请检查电机状态；必要时切断驱动电源。"
        notice = notice.map { $0 + "\n" + message } ?? message
        log("已发送停止指令，但未收到全部停止确认；请检查电机状态", failure: true)
    }
    func stop(disconnect: Bool = false, completion: (() -> Void)? = nil) {
        guard state != .disconnected else { completion?(); return }
        guard state != .stopping && state != .connecting && state != .maintaining else { return }
        let detection = state == .scanning ? maintenanceTask : nil
        detection?.cancel()
        let oldLoop = loop; oldLoop?.cancel(); loop = nil
        displayTask?.cancel(); displayTask = nil; state = .stopping
        Task {
            if let detection { await detection.value }
            if let oldLoop {
                let result = await oldLoop.value
                apply(result.snapshot); stopConfirmed = result.stopConfirmed
                if let failure = result.failure { notice = failure; log(failure, failure: true) }
            } else {
                stopConfirmed = demo ? true : await session.stop(ids: Array(Set(activeIDs.filter { $0 < 15 }).union(telemetry.keys)))
            }
            resetControlInputs()
            refreshChartNow()
            if stopConfirmed { log("通信已停止") } else { reportStopFailure() }
            if disconnect { await session.disconnect(); state = .disconnected; log("连接已关闭") }
            else { state = .ready }
            completion?()
        }
    }
    func scan() {
        guard state == .ready else { return }
        if demo {
            selectedIDs = [0, 1, 2]; selectMotor(0)
            log("演示扫描：ID 0、1、2；未发送设备命令")
        } else { maintain(.scanIDs) }
    }
    func detectMotors() {
        if state == .running {
            stop { [weak self] in
                guard let self, self.stopConfirmed else { return }
                self.detectMotors()
            }
            return
        }
        guard state == .ready else { return }
        if demo { scan(); resetControlInputs(); return }
        state = .scanning; resetControlInputs()
        selectedIDs = []; activeIDs = []; telemetry = [:]; health = [:]; discoveredDevices = []
        log("自动检测：逐台发送停止探测，完成后保持停止")
        maintenanceTask = Task {
            do {
                let replies = try await session.detectOnlineMotors()
                let ids = replies.map(\.id)
                selectedIDs = Set(ids); activeIDs = ids
                telemetry = Dictionary(uniqueKeysWithValues: replies.map { ($0.id, Sample($0)) })
                health = telemetry.mapValues(MotorHealthDisplay.init)
                if let first = ids.first { selectMotor(first) }
                resetControlInputs()
                log(ids.isEmpty ? "未检测到应用模式电机；可在设备工具中扫描或切换引导" : "自动检测完成：ID \(ids.map(String.init).joined(separator: ", "))")
                let abnormal = replies.filter { $0.error != 0 || $0.timedOut || $0.mode != 0 }.map(\.id)
                if !abnormal.isEmpty { log("检测到异常反馈：ID \(abnormal.map(String.init).joined(separator: ", "))；请查看反馈表", failure: true) }
            } catch { report(error) }
            stats = await session.statistics
            if state == .scanning { state = .ready }
            maintenanceTask = nil
        }
    }
    func clearRecording() {
        Task {
            await acquisition.recordings.clear()
            recordCount = 0; historySpan = 0; frozenChartEnd = nil; latestRecordTime = nil
            chartOffset = 0; refreshChart(); log("记录已清空")
        }
    }
    func chooseFirmware() {
        guard state != .maintaining else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "选择 J288 / S288 原厂 APP 固件，保留原始文件名"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard (8...131072).contains(size) else { throw MotorError.invalid("固件大小必须为 8 字节至 128 KiB") }
            firmware = try FirmwareImage(filename: url.lastPathComponent, data: Data(contentsOf: url))
            log("固件已校验：\(url.lastPathComponent)")
        } catch { firmware = nil; report(error) }
    }
    func maintain(_ operation: MaintenanceOperation) {
        guard state == .ready, !demo else { return }
        state = .maintaining
        if case .temporaryBoot = operation { temporaryBootActive = true }
        resetControlInputs(); firmwareVersion = nil
        maintenanceProgress = 0; maintenanceFailed = false; maintenanceHistory = []
        maintenanceStage = operation.title
        let id = selectedID
        let runID = UUID(); maintenanceRunID = runID
        log("ID \(id) · \(operation.title)")
        maintenanceTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await session.maintain(operation, id: id) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.maintenanceRunID == runID, self.state == .maintaining else { return }
                        self.maintenanceProgress = progress.fraction
                        self.maintenanceStage = progress.stage
                        if self.maintenanceHistory.last != progress.stage {
                            self.maintenanceHistory.append(progress.stage)
                            if self.maintenanceHistory.count > 100 { self.maintenanceHistory.removeFirst() }
                        }
                    }
                }
                maintenanceRunID = UUID()
                if let version = result.version { firmwareVersion = version }
                if let newID = result.newID {
                    selectedIDs.remove(id); selectedIDs.insert(newID)
                    activeIDs = activeIDs.map { $0 == id ? newID : $0 }
                    commands[id] = nil; telemetry[id] = nil; health[id] = nil; selectMotor(newID)
                }
                if let newBaud = result.newBaud { baud = newBaud }
                if let devices = result.devices { discoveredDevices = devices }
                if let ids = result.discoveredIDs {
                    selectedIDs = Set(ids); activeIDs = ids; telemetry = [:]; commands = [:]
                    discoveredDevices = result.devices ?? []
                    if let first = ids.first { selectMotor(first) }
                }
                maintenanceStage = result.message; maintenanceProgress = 1
                maintenanceHistory.append(result.message)
                log(result.message)
            } catch {
                maintenanceRunID = UUID()
                maintenanceFailed = true
                let stage = maintenanceStage
                maintenanceStage = "\(error is CancellationError ? "已中止" : "未完成") · \(stage)"
                maintenanceHistory.append(maintenanceStage)
                report(MotorError.serial("\(maintenanceStage)。\(error is CancellationError ? "" : error.localizedDescription) 可保留供电与连接，重新执行升级或引导切换；改 ID / 波特率中断时请分别检查新旧值。"))
            }
            resetControlInputs()
            if temporaryBootActive { stopConfirmed = false }
            temporaryBootActive = false
            stats = await session.statistics
            baud = await session.baud
            if await session.isConnected { state = .ready }
            else {
                state = .disconnected; stopConfirmed = false
                activeIDs = []; telemetry = [:]; health = [:]; discoveredDevices = []
                log("维护后设备状态不确定，连接已关闭；请确认当前 ID / 波特率后重新连接。", failure: true)
            }
            maintenanceTask = nil
        }
    }
    func cancelMaintenance() {
        guard state == .maintaining || state == .scanning else { return }
        maintenanceTask?.cancel()
    }
    func exportCSV() {
        guard !exporting else { return }
        guard recordCount > 0 else { notice = "暂无数据可导出"; return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "motor-\(demo ? "demo-" : "")\(Date.now.formatted(.iso8601).replacingOccurrences(of: ":", with: "-" )).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        Task {
            do {
                let count = try await acquisition.recordings.exportCSV(to: url)
                log("已导出 \(count) 条记录")
            } catch { report(error) }
            exporting = false
        }
    }
}
