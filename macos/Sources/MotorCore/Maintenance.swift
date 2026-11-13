import Foundation

public protocol MaintenanceTransport: Sendable {
    func transact(_ bytes: [UInt8], responseLength: Int, timeout: Duration) async throws -> [UInt8]
    func setBaud(_ baud: Int) async throws
    func collectIDs(_ request: [UInt8], timeout: Duration) async throws -> [UInt8]
    func recoverLink() async throws
    func currentBaud() async -> Int
}
public extension MaintenanceTransport {
    func currentBaud() async -> Int { ServoProtocol.baud }
    func recoverLink() async throws { throw MotorError.serial("无法恢复串口连接") }
    func collectIDs(_ request: [UInt8], timeout: Duration) async throws -> [UInt8] {
        throw MotorError.invalid("当前传输未提供原始 ID 扫描")
    }
}

public enum MaintenanceOperation: Sendable {
    case scanIDs, reorderIDs, version, serialNumber, clearError, restart, enterBootloader, temporaryBoot, switchBoot, repairDuplicateIDs
    case changeID(Int), automaticBoot(Bool), changeBaud(Int), calibrate(Calibration), firmware(FirmwareImage)
    var changesDeviceState: Bool {
        switch self { case .version, .serialNumber: return false; default: return true }
    }
    public var title: String {
        switch self {
        case .scanIDs: return "扫描总线 ID"
        case .reorderIDs: return "总线 ID 顺序重排"
        case .version: return "查询版本"
        case .serialNumber: return "查询序列号"
        case .repairDuplicateIDs: return "修复重复 ID"
        case .clearError: return "清除故障"
        case .restart: return "复位电机"
        case .enterBootloader: return "进入 Bootloader"
        case .temporaryBoot: return "临时关闭引导"
        case .switchBoot: return "执行引导切换"
        case .changeID: return "修改 ID"
        case .automaticBoot: return "设置自动引导"
        case .changeBaud: return "修改波特率"
        case .calibrate: return "上电位置标定"
        case .firmware: return "更新固件"
        }
    }
}

public struct MaintenanceProgress: Sendable {
    public let fraction: Double
    public let stage: String
    public init(_ fraction: Double, _ stage: String) { self.fraction = fraction; self.stage = stage }
}

public struct MaintenanceResult: Sendable {
    public var message: String
    public var version: FirmwareVersion?
    public var newID: Int?
    public var newBaud: Int?
    public var discoveredIDs: [Int]?
    public var devices: [DiscoveredMotor]?
    public init(_ message: String, version: FirmwareVersion? = nil, newID: Int? = nil, newBaud: Int? = nil) {
        self.message = message; self.version = version; self.newID = newID; self.newBaud = newBaud
    }
}

/// SerialSession holds an exclusive lease for the complete operation, including sleeps.
/// Retries are limited to reads; writes/erase/save are never blindly replayed.
public struct MaintenanceController: Sendable {
    let transport: any MaintenanceTransport
    let clientTag: UInt32
    let timestamp: @Sendable () -> UInt32
    let sleep: @Sendable (Duration) async throws -> Void
    let now: @Sendable () -> ContinuousClock.Instant
    let progress: @Sendable (MaintenanceProgress) -> Void
    public init(transport: any MaintenanceTransport, clientTag: UInt32,
                timestamp: @escaping @Sendable () -> UInt32 = { UInt32(Date().timeIntervalSince1970) },
                sleep: (@Sendable (Duration) async throws -> Void)? = nil,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
                progress: @escaping @Sendable (MaintenanceProgress) -> Void = { _ in }) {
        self.transport = transport; self.clientTag = clientTag; self.timestamp = timestamp
        // Keep the async closure in this module. A public default-argument
        // closure can emit mismatched context layouts in library/client objects
        // with Apple Swift 6.3.3 (swiftlang/swift#92017).
        self.sleep = sleep ?? { try await Task.sleep(for: $0) }
        self.now = now; self.progress = progress
    }
    public func run(_ operation: MaintenanceOperation, id: Int) async throws -> MaintenanceResult {
        guard (0...14).contains(id) else { throw MotorError.invalid("设备 ID 必须为 0–14") }
        try Task.checkCancellation()
        progress(.init(0, operation.title))
        let result: MaintenanceResult
        switch operation {
        case .scanIDs:
            result = try await scanIDs()
        case .repairDuplicateIDs:
            result = try await repairIDs(15)
        case .reorderIDs:
            result = try await repairIDs(15, sequential: true)
        case .version:
            let v = try await version(id); result = .init(v.description, version: v)
        case .serialNumber:
            var number: [UInt8]?
            do {
                let reply = try await control(id, argument: -1536)
                let f = try MotorFeedback.decode(reply)
                if f.id == id, reply[3] == 130 { number = Array(reply[6..<18]) }
            } catch MotorError.timeout { }
            if number == nil {
                let first = try await boot(id, code: 7, command: 0, address: 32)
                let last = try await boot(id, code: 3, command: 0, address: 40)
                number = Array(first.prefix(8)) + Array(last.prefix(4))
            }
            result = .init("SN · \(number!.map { String(format: "%02X", $0) }.joined())")
        case .clearError:
            let b = try await control(id, argument: -256)
            let feedback = try MotorFeedback.decode(b)
            guard feedback.id == id, feedback.mode == 6,
                  Int16(bitPattern: ServoProtocol.read16(b, 6)) == -256, feedback.error == 0 else {
                throw MotorError.invalid("清故障应答不匹配或设备仍报告故障")
            }
            _ = try await stopFeedback(id)
            result = .init("故障已清除并回读确认")
        case .restart:
            try await restart(id)
            result = .init("复位完成，已确认设备离线后恢复停止反馈")
        case .enterBootloader:
            try await reset(id)
            try await holdBoot(id)
            try await unlock(id, hold: true)
            result = .init("已进入 Bootloader；可更新固件或执行引导切换")
        case .temporaryBoot:
            return try await temporaryBoot()
        case .switchBoot:
            try await reset(id)
            let reply = try await boot(id, command: 5, timeout: .seconds(1))
            let text = String(decoding: reply.prefix(while: { $0 != 0 }), as: UTF8.self)
            guard text.hasPrefix("OK ATB") else { throw MotorError.invalid("引导切换未确认：\(reply.hex)") }
            result = .init("引导切换应答：\(text)")
        case .changeID(let newID):
            guard (0...14).contains(newID), newID != id else { throw MotorError.invalid("请选择与当前不同的 ID（0–14）") }
            // Detect a live target before writing. Physical isolation is required for duplicate IDs.
            do {
                _ = try await stopFeedback(newID, attempts: 1)
                throw MotorError.invalid("目标 ID 已有设备响应，不能覆盖")
            } catch MotorError.timeout { }
            do {
                _ = try await boot(newID, command: 0, address: 4)
                throw MotorError.invalid("目标 ID 的 Bootloader 已有设备响应，不能覆盖")
            } catch MotorError.timeout { }
            try await reset(id); try await unlock(id)
            let reply = try await boot(id, command: 1, address: 4, payload: [UInt8(newID)] + zeros(7))
            guard reply[0] == newID else { throw MotorError.invalid("新 ID 回读不一致；请检查原 ID 和目标 ID") }
            progress(.init(0.7, "向新 ID 保存配置"))
            try await save(newID)
            let read = try await boot(newID, command: 0, address: 4)
            guard read[0] == newID else { throw MotorError.invalid("保存后 ID 回读不一致") }
            result = .init("ID 已保存为 \(newID)，Bootloader 回读确认", newID: newID)
        case .automaticBoot(let enabled):
            try await reset(id); try await unlock(id)
            let value: UInt8 = enabled ? 1 : 0
            let reply = try await boot(id, command: 1, address: 5, payload: [value] + zeros(7))
            guard reply[0] == value else { throw MotorError.invalid("自动引导回读不一致") }
            try await save(id)
            let read = try await boot(id, command: 0, address: 5)
            guard read[0] == value else { throw MotorError.invalid("自动引导保存后校验失败") }
            result = .init(enabled ? "自动引导已开启并保存" : "自动引导已关闭并保存")
        case .changeBaud(let baud):
            guard [4_000_000, 6_000_000].contains(baud) else { throw MotorError.invalid("仅支持 4 / 6 Mbps") }
            let v = try await prepareBaudChange(id)
            guard v.supportsBaudChange else { throw MotorError.invalid("修改波特率需要 Boot ≥03.0A、App ≥02.15（按 SDK 版本检查）") }
            // prepareBaudChange already stopped the bus, as in Change_Motor_BaudRate.
            try await sendReset(id); try await sleep(.milliseconds(80)); try await unlock(id)
            let value = UInt8(baud / 100_000)
            let old = try await boot(id, command: 0, address: 14)
            if old[0] != value {
                let reply = try await boot(id, command: 1, address: 14, payload: [value] + zeros(7))
                guard reply[0] == value else { throw MotorError.invalid("设备波特率回读不一致") }
                try await save(id)
            }
            _ = try await boot(id, command: 4)
            try await transport.setBaud(baud)
            try await sleep(.milliseconds(100))
            _ = try await stopFeedback(id, attempts: 20)
            result = .init("设备和主机已切换到 \(baud) bps，反馈确认", newBaud: baud)
        case .calibrate(let calibration):
            _ = try calibration.encode(id: id, clientTag: clientTag, timestamp: timestamp())
            _ = try await stopFeedback(id)
            let v = try await version(id)
            guard v.supportsCalibration else { throw MotorError.invalid("标定需要 App ≥02.0A（按 SDK 版本检查）") }
            progress(.init(0.4, "写入标定并等待设备回读"))
            let tx = try calibration.encode(id: id, clientTag: clientTag, timestamp: timestamp())
            let reply = try await transport.transact(tx, responseLength: 26, timeout: .seconds(3))
            _ = try calibration.validate(reply, id: id)
            result = .init("\(calibration.mode.rawValue)已写入，模式与位置回读通过")
        case .firmware(let firmware):
            result = try await update(firmware, id: id)
        }
        progress(.init(1, result.message))
        return result
    }

    private func zeros(_ n: Int) -> [UInt8] { [UInt8](repeating: 0, count: n) }
    private func control(_ id: Int, mode: Int = 6, argument: Int16 = 0, timeout: Duration = .milliseconds(100)) async throws -> [UInt8] {
        try await transport.transact(MaintenanceProtocol.command(id: id, mode: mode, argument: argument), responseLength: 26, timeout: timeout)
    }
    private func version(_ id: Int) async throws -> FirmwareVersion {
        for attempt in 0..<3 {
            do { return try FirmwareVersion.decode(await control(id, argument: -512), id: id) }
            catch MotorError.timeout where attempt < 2 { try await sleep(.milliseconds(100)) }
        }
        throw MotorError.timeout
    }
    private func stopFeedback(_ id: Int, attempts: Int = 3, timeout: Duration = .milliseconds(100)) async throws -> MotorFeedback {
        for attempt in 0..<attempts {
            do {
                let f = try MotorFeedback.decode(await control(id, mode: 0, timeout: timeout))
                guard f.id == id, f.mode == 0, f.error == 0, !f.timedOut else {
                    throw MotorError.invalid("停止反馈 ID、模式、故障或超时状态异常")
                }
                return f
            } catch MotorError.timeout where attempt + 1 < attempts { try await sleep(.milliseconds(50)) }
        }
        throw MotorError.timeout
    }
    func reset(_ id: Int) async throws {
        try await stopBus()
        try await sleep(.milliseconds(1))
        try await sendReset(id)
        try await sleep(.milliseconds(80))
    }
    private func stopBus() async throws {
        _ = try await transport.transact(MaintenanceProtocol.command(id: 15, mode: 0), responseLength: 0, timeout: .milliseconds(100))
    }
    private func sendReset(_ id: Int) async throws {
        _ = try await transport.transact(MaintenanceProtocol.command(id: id, mode: 7), responseLength: 0, timeout: .milliseconds(100))
    }
    private func restart(_ id: Int) async throws {
        try await stopBus()
        try await sleep(.milliseconds(1))
        try await sendReset(id)
        let deadline = now() + .seconds(3)
        var offline = false
        // Poll immediately: an unconditional 80 ms delay can miss the reset window.
        while now() < deadline {
            try Task.checkCancellation()
            do { _ = try await stopFeedback(id, attempts: 1, timeout: .milliseconds(10)) }
            catch MotorError.timeout { offline = true; break }
            try await sleep(.milliseconds(1))
        }
        guard offline else { throw MotorError.invalid("复位未确认：设备始终响应，未观察到离线阶段") }
        try await sleep(.milliseconds(50))
        while now() < deadline {
            try Task.checkCancellation()
            do {
                _ = try await stopFeedback(id, attempts: 1, timeout: .milliseconds(50))
                return
            } catch MotorError.timeout { try await sleep(.milliseconds(10)) }
        }
        throw MotorError.invalid("复位未完成：设备离线后未恢复正常停止反馈")
    }

    private func prepareBaudChange(_ id: Int) async throws -> FirmwareVersion {
        let current = await transport.currentBaud()
        let rates = [current] + [4_000_000, 6_000_000].filter { $0 != current }
        for (index, rate) in rates.enumerated() {
            try Task.checkCancellation()
            if index > 0 { try await transport.setBaud(rate) }
            progress(.init(0.02, "在 \(rate) bps 恢复应用通信"))
            do {
                try await stopBus()
                // The SDK resets Boot before asking the APP version. An APP-only
                // device may ignore this Boot request, so still probe Stop on timeout.
                do { try await boot(id, command: 4) } catch MotorError.timeout { }
                try await sleep(.milliseconds(50))
                _ = try await stopFeedback(id, attempts: 10, timeout: .milliseconds(50))
                return try await version(id)
            } catch MotorError.timeout where index + 1 < rates.count { continue }
        }
        throw MotorError.timeout
    }

    private func temporaryBoot() async throws -> MaintenanceResult {
        do {
            try await reset(15)
            let request = try BootRequest(id: 15, command: 1, address: 15, payload: [1] + zeros(7)).encode()
            progress(.init(0, "持续发送临时关闭引导指令；请重新给电机上电，完成后点击退出"))
            var needsRecovery = false
            while true {
                try Task.checkCancellation()
                do {
                    if needsRecovery {
                        try await sleep(.milliseconds(500))
                        try await transport.recoverLink()
                        needsRecovery = false
                        progress(.init(0, "连接已恢复，继续发送临时关闭引导指令"))
                    }
                    // Original temporary worker broadcasts; there is no device ACK.
                    _ = try await transport.transact(request, responseLength: 0, timeout: .milliseconds(100))
                } catch MotorError.serial {
                    if !needsRecovery { progress(.init(0, "连接中断，等待恢复；可随时退出临时引导")) }
                    needsRecovery = true
                }
                try await sleep(.microseconds(500))
            }
        } catch is CancellationError {
            // Ending the worker does not save ATB or start the application.
            return .init("已退出临时引导发送；设备状态未确认，可执行引导切换或重新连接")
        }
    }
    @discardableResult func boot(_ id: Int, code: Int = 0, command: Int, address: Int = 0,
                                        sector: Int = 0, payload: [UInt8]? = nil, timeout: Duration = .milliseconds(100)) async throws -> [UInt8] {
        let request = try BootRequest(id: id, lengthCode: code, command: command, address: address, sector: sector, payload: payload)
        let reply = try await transport.transact(request.encode(), responseLength: request.responseLength, timeout: timeout)
        return try request.decode(reply)
    }
    private func holdBoot(_ id: Int) async throws {
        for _ in 0..<10 {
            do { try await boot(id, command: 1, address: 15, payload: [1] + zeros(7)) }
            catch MotorError.timeout { } // SDK probes the short reset/auto-boot window ten times.
            try await sleep(.milliseconds(10))
        }
    }
    func unlock(_ id: Int, hold: Bool = false) async throws {
        progress(.init(0.08, "校验 Bootloader 解锁握手"))
        let challenge = try await boot(id, code: 8, command: 0, address: 32)
        let payload = hold ? [1] + Array(challenge.prefix(12)) + zeros(3) : challenge
        try await boot(id, code: 8, command: 1, address: hold ? 15 : 16, payload: payload)
    }
    func save(_ id: Int, command: Int = 2, sector: Int = 0) async throws {
        try await boot(id, command: command, sector: sector,
                       payload: MaintenanceProtocol.savePayload(clientTag: clientTag, timestamp: timestamp()), timeout: .seconds(3))
    }
    private func update(_ firmware: FirmwareImage, id: Int) async throws -> MaintenanceResult {
        try await reset(id); try await holdBoot(id); try await unlock(id, hold: true)
        // Probe the larger transfer size before erasing any application bytes.
        try await boot(id, code: 9, command: 0, sector: 1, payload: zeros(32))
        progress(.init(0.12, "擦除应用区"))
        try await save(id, command: 3, sector: 1)
        var offset = 0
        while offset < firmware.bytes.count {
            try Task.checkCancellation()
            let count = offset + 32 <= firmware.bytes.count ? 32 : 8
            let chunk = Array(firmware.bytes[offset..<(offset + count)])
            let reply = try await boot(id, code: count == 32 ? 9 : 7, command: 1,
                                       address: offset / 8, sector: 1, payload: chunk, timeout: .seconds(1))
            guard reply == chunk else { throw MotorError.invalid("固件在偏移 \(offset) 的回读不一致，未保存或启动") }
            offset += count
            progress(.init(0.15 + 0.75 * Double(offset) / Double(firmware.bytes.count), "写入并回读 \(offset) / \(firmware.bytes.count) 字节"))
        }
        progress(.init(0.92, "写入固件 CRC 与自动引导配置"))
        var config: [UInt8] = [UInt8(id), 1]
        ServoProtocol.append(firmware.crc, to: &config); config += zeros(4)
        let reply = try await boot(id, code: 3, command: 1, address: 4, payload: config)
        guard Array(reply.prefix(4)) == Array(config.prefix(4)) else { throw MotorError.invalid("固件 CRC 配置回读不一致") }
        try await save(id)
        progress(.init(0.96, "启动新固件并核对版本"))
        try await reset(id)
        let started = try await boot(id, command: 5, timeout: .seconds(1))
        guard Array(started.prefix(7)) == Array("OK ATB1".utf8) else { throw MotorError.invalid("固件启动确认失败：\(started.hex)") }
        try await sleep(.milliseconds(150))
        let v = try await version(id)
        guard v.app == firmware.version else { throw MotorError.invalid("启动版本与文件名不一致：\(v.description)") }
        return .init("固件写入、回读和启动版本校验完成", version: v)
    }
}
