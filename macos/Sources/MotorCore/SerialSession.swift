import Foundation

public struct LinkStatistics: Sendable {
    public var sent = 0
    public var received = 0
    public var timeouts = 0
    public var badCRC = 0
    public var wrongID = 0
    public init() {}
}

public struct StreamFeedback: Sendable {
    public let feedback: MotorFeedback
    public let command: MotorCommand
}
public struct StreamUpdate: Sendable {
    public let feedback: [StreamFeedback]
    public let expiredIDs: [Int]
}

/// Owns the descriptor; the actor serializes requests, stop commands and close.
public actor SerialSession {
    private var fd: Int32 = -1
    private var parser = FrameParser()
    private var maintenanceLease: UUID?
    private var pending: (id: Int, deadline: ContinuousClock.Instant)?
    private var streamIDs: Set<Int> = []
    private var streamPending: [(command: MotorCommand, deadline: ContinuousClock.Instant)] = []
    private var protectedFeedbackAt: [Int: ContinuousClock.Instant] = [:]
    private let now: @Sendable () -> ContinuousClock.Instant
    public private(set) var statistics = LinkStatistics()
    public var isConnected: Bool { fd >= 0 }
    public var baud: Int { connectedBaud }
    private let io: any SerialIO
    private var connectedPath = ""
    private var connectedBaud = ServoProtocol.baud
    public init() { io = NativeSerialIO(); now = { .now } }
    init(io: any SerialIO, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.io = io; self.now = now
    }
    deinit { io.close(fd) }

    public func connect(path: String, baud: Int = ServoProtocol.baud) throws {
        guard fd < 0 else { throw MotorError.serial("串口已连接") }
        guard path.hasPrefix("/dev/cu."), [4_000_000, 6_000_000].contains(baud) else {
            throw MotorError.invalid("请选择 /dev/cu.* 串口及电机当前波特率")
        }
        fd = try io.open(path, baud: baud)
        connectedPath = path; connectedBaud = baud
        statistics = LinkStatistics(); parser = FrameParser(); protectedFeedbackAt = [:]
    }

    public func exchange(_ command: MotorCommand, timeout: Duration = .milliseconds(40)) throws -> MotorFeedback {
        try exchange(command, timeout: timeout, cancellable: true)
    }

    private func exchange(_ command: MotorCommand, timeout: Duration, cancellable: Bool) throws -> MotorFeedback {
        guard maintenanceLease == nil else { throw MotorError.serial("设备维护中，串口由配置流程独占") }
        guard fd >= 0 else { throw MotorError.serial("串口未连接") }
        guard command.id != 15 else { throw MotorError.invalid("广播只发送，不等待单电机反馈") }
        guard pending == nil, streamIDs.isEmpty else { throw MotorError.serial("异步请求尚未完成") }
        let bytes = try command.encode()
        if command.mode == .foc { try requireFreshControl(id: command.id) }
        if cancellable { try Task.checkCancellation() }
        parser.clearPartialFrame()
        guard io.flush(fd) else { throw MotorError.serial("串口已断开") }
        let sent = io.write(fd, bytes: bytes, timeout: 40)
        guard sent == bytes.count else { throw MotorError.serial("控制帧发送失败") }
        statistics.sent += 1
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if cancellable { try Task.checkCancellation() }
            let bytes = try io.read(fd, capacity: 512, timeout: 2)
            if bytes.isEmpty { continue }
            let frames = parser.feed(bytes)
            statistics.badCRC = parser.badCRC
            for frame in frames {
                guard frame.id == command.id else { statistics.wrongID += 1; continue }
                statistics.received += 1
                recordProtectedFeedback(frame)
                return frame
            }
        }
        statistics.timeouts += 1
        throw MotorError.timeout
    }

    /// Runs atomically on this actor before any FOC command. Both frames are Stop/zero.
    /// A cleared latch is not permission to move: re-armed feedback must also be healthy.
    public func prepareForControl(ids: [Int], timeout: Duration = .milliseconds(40)) throws -> [MotorFeedback] {
        let ids = Set(ids).sorted()
        guard !ids.isEmpty, ids.allSatisfy({ (0...14).contains($0) }) else {
            throw MotorError.invalid("启动确认需要逐台 ID（0–14）；广播没有确认应答")
        }
        guard fd >= 0, maintenanceLease == nil, pending == nil, streamIDs.isEmpty else {
            throw MotorError.serial("启动确认要求已连接且没有进行中的通信或维护")
        }
        var confirmed: [MotorFeedback] = []
        protectedFeedbackAt = [:]
        var succeeded = false
        defer { if !succeeded { protectedFeedbackAt = [:] } }
        for id in ids {
            try Task.checkCancellation()
            let clear = MotorCommand(id: id, timeoutProtection: false)
            let protectedStop = MotorCommand(id: id, timeoutProtection: true)
            var clearFailure: Error?
            do {
                let reply = try exchange(clear, timeout: timeout, cancellable: true)
                try requireHealthyStop(reply, stage: "清除超时锁存")
            } catch { clearFailure = error }

            // Even a lost clear ACK or cancellation must not leave protection disabled.
            // This one bounded exchange deliberately ignores task cancellation.
            let armed: MotorFeedback
            do {
                armed = try exchange(protectedStop, timeout: timeout, cancellable: false)
                try requireHealthyStop(armed, stage: "重新开启超时保护")
            } catch {
                throw MotorError.serial("ID \(id) 启动确认失败：重新开启保护未确认。\(error.localizedDescription)")
            }
            try Task.checkCancellation()
            if let clearFailure {
                throw MotorError.serial("ID \(id) 启动确认失败：清除锁存未确认；已恢复保护并保持停止。\(clearFailure.localizedDescription)")
            }
            confirmed.append(armed)
            protectedFeedbackAt[id] = now()
        }
        // Earlier motors must still be inside the deadline after a slow multi-ID handshake.
        for id in ids { try requireFreshControl(id: id) }
        succeeded = true
        return confirmed
    }

    private func requireFreshControl(id: Int) throws {
        guard let last = protectedFeedbackAt[id], last.duration(to: now()) < .milliseconds(500) else {
            throw MotorError.serial("ID \(id) 保护确认已过期或尚未完成，停止后请重新启动；不自动恢复运动")
        }
    }
    private func recordProtectedFeedback(_ frame: MotorFeedback) {
        guard protectedFeedbackAt[frame.id] != nil else { return }
        if frame.error != 0 || frame.timedOut { protectedFeedbackAt[frame.id] = nil }
        else { protectedFeedbackAt[frame.id] = now() }
    }

    private func requireHealthyStop(_ reply: MotorFeedback, stage: String) throws {
        guard reply.mode == MotorMode.stop.rawValue, !reply.timedOut, reply.error == 0 else {
            throw MotorError.invalid("ID \(reply.id) \(stage)：模式 \(reply.mode)，超时\(reply.timedOut ? "已触发" : "正常")，错误码 \(reply.error)")
        }
    }

    /// Broadcast is send-only: no invented acknowledgement or receive count.
    public func broadcast(_ command: MotorCommand) throws {
        guard command.id == 15, fd >= 0, maintenanceLease == nil, pending == nil else {
            throw MotorError.serial("广播要求已连接、无维护或未完成的异步请求")
        }
        if command.mode == .foc {
            guard command.timeoutProtection, !streamIDs.isEmpty else {
                throw MotorError.invalid("广播控制需要逐台完成保护确认并持续监测反馈")
            }
            for id in streamIDs { try requireFreshControl(id: id) }
        }
        let bytes = try command.encode()
        let count = io.write(fd, bytes: bytes, timeout: 40)
        guard count == bytes.count else { throw MotorError.serial("广播发送失败") }
        statistics.sent += 1
    }

    /// Separate sending and receiving without blocking the actor on the response deadline.
    /// One in-flight frame is required on this half-duplex protocol (no transaction IDs).
    public func beginAsync(_ command: MotorCommand, timeout: Duration = .milliseconds(40)) throws {
        guard fd >= 0, maintenanceLease == nil, pending == nil, streamIDs.isEmpty, command.id != 15 else {
            throw MotorError.serial("异步通信状态无效")
        }
        let bytes = try command.encode()
        try Task.checkCancellation()
        if command.mode == .foc { try requireFreshControl(id: command.id) }
        parser.clearPartialFrame()
        guard io.flush(fd) else { throw MotorError.serial("串口已断开") }
        let count = io.write(fd, bytes: bytes, timeout: 40)
        guard count == bytes.count else { throw MotorError.serial("异步发送失败") }
        statistics.sent += 1; pending = (command.id, .now + timeout)
    }
    public func receiveAsync() throws -> MotorFeedback? {
        guard let request = pending else { throw MotorError.serial("没有待接收请求") }
        try Task.checkCancellation()
        let bytes: [UInt8]
        do { bytes = try io.read(fd, capacity: 512, timeout: 0) }
        catch { pending = nil; throw error }
        let frames = parser.feed(bytes)
        statistics.badCRC = parser.badCRC
        for frame in frames {
            guard frame.id == request.id else { statistics.wrongID += 1; continue }
            pending = nil; statistics.received += 1; recordProtectedFeedback(frame); return frame
        }
        if ContinuousClock.now >= request.deadline {
            pending = nil; statistics.timeouts += 1; throw MotorError.timeout
        }
        return nil
    }
    public func cancelAsync() { pending = nil; streamIDs = []; streamPending = []; parser.clearPartialFrame() }

    /// Streaming sends are paced independently of replies. Never flush between
    /// frames: delayed/fragmented responses must remain available to the receiver.
    public func startStream(ids: [Int]) throws {
        guard fd >= 0, maintenanceLease == nil, pending == nil, streamIDs.isEmpty,
              !ids.isEmpty, ids.allSatisfy({ (0...14).contains($0) }) else { throw MotorError.serial("异步流状态无效") }
        guard io.flush(fd) else { throw MotorError.serial("串口已断开") }
        parser.clearPartialFrame(); streamPending = []; streamIDs = Set(ids)
    }
    public func sendStream(_ command: MotorCommand, timeout: Duration = .milliseconds(40)) throws {
        guard fd >= 0, maintenanceLease == nil, streamIDs.contains(command.id), streamPending.count < 512 else {
            throw MotorError.serial("异步流已失效或待接收队列已满")
        }
        try Task.checkCancellation()
        guard command.timeoutProtection else { throw MotorError.invalid("异步控制必须开启超时保护") }
        if command.mode == .foc { try requireFreshControl(id: command.id) }
        let bytes = try command.encode()
        guard io.write(fd, bytes: bytes, timeout: 40) == bytes.count else { throw MotorError.serial("异步发送失败") }
        statistics.sent += 1
        streamPending.append((command, now() + timeout))
    }
    public func pollStream() throws -> StreamUpdate {
        guard fd >= 0, maintenanceLease == nil, !streamIDs.isEmpty else { throw MotorError.serial("异步流未开始") }
        try Task.checkCancellation()
        var replies: [StreamFeedback] = []
        // Expire before matching: an already overdue reply cannot refresh the
        // protection lease. Same-ID replies still lack transaction identifiers.
        let instant = now()
        let expired = streamPending.filter { $0.deadline <= instant }.map { $0.command.id }
        streamPending.removeAll { $0.deadline <= instant }
        let frames = parser.feed(try io.read(fd, capacity: 4096, timeout: 0))
        statistics.badCRC = parser.badCRC
        for frame in frames {
            guard let index = streamPending.firstIndex(where: { $0.command.id == frame.id }) else {
                statistics.wrongID += 1; continue
            }
            let request = streamPending.remove(at: index)
            statistics.received += 1; recordProtectedFeedback(frame)
            replies.append(StreamFeedback(feedback: frame, command: request.command))
        }
        statistics.timeouts += expired.count
        return StreamUpdate(feedback: replies, expiredIDs: expired)
    }

    /// Application-mode discovery does not reset devices or change their IDs.
    public func detectOnlineIDs() throws -> [Int] {
        try detectOnlineMotors().map(\.id)
    }
    public func detectOnlineMotors() throws -> [MotorFeedback] {
        guard fd >= 0, maintenanceLease == nil, pending == nil, streamIDs.isEmpty else {
            throw MotorError.serial("请连接串口并停止通信再检测电机")
        }
        protectedFeedbackAt = [:]
        var replies: [MotorFeedback] = []
        for id in 0...14 {
            try Task.checkCancellation()
            let badBefore = statistics.badCRC, wrongBefore = statistics.wrongID, noiseBefore = parser.discardedBytes
            do {
                replies.append(try exchange(MotorCommand(id: id), timeout: .milliseconds(10)))
            } catch MotorError.timeout {
                if statistics.badCRC != badBefore || statistics.wrongID != wrongBefore || parser.discardedBytes != noiseBefore || !parser.buffer.isEmpty {
                    throw MotorError.collision
                }
            }
            if statistics.badCRC != badBefore || statistics.wrongID != wrongBefore || parser.discardedBytes != noiseBefore || !parser.buffer.isEmpty {
                throw MotorError.collision
            }
        }
        return replies
    }

    public func stop(ids: [Int]) -> Bool {
        cancelAsync()
        protectedFeedbackAt = [:]
        // Original all-stop broadcasts first, then verifies known devices individually.
        var broadcastSent = true
        do { try broadcast(MotorCommand(id: 15)) } catch { broadcastSent = false }
        var allAcknowledged = broadcastSent && !ids.isEmpty
        for id in Set(ids).sorted() {
            var acknowledged = false
            for _ in 0..<2 {
                if let frame = try? exchange(MotorCommand(id: id)), frame.mode == 0 {
                    acknowledged = true; break
                }
            }
            allAcknowledged = allAcknowledged && acknowledged
        }
        return allAcknowledged
    }
    public func disconnect() {
        guard maintenanceLease == nil else { return }
        cancelAsync(); protectedFeedbackAt = [:]; io.close(fd); fd = -1
    }

    public func maintain(_ operation: MaintenanceOperation, id: Int,
                         progress: @escaping @Sendable (MaintenanceProgress) -> Void = { _ in }) async throws -> MaintenanceResult {
        guard fd >= 0, maintenanceLease == nil, pending == nil, streamIDs.isEmpty else { throw MotorError.serial("串口未连接或正在维护") }
        let lease = UUID()
        maintenanceLease = lease
        protectedFeedbackAt = [:]
        defer { maintenanceLease = nil; parser.clearPartialFrame() }
        // SDK client marker: F9 followed by three host-identification bytes. It is not a secret.
        let tag = (UInt32.random(in: 0...0x00ff_ffff) << 8) | 0xf9
        let controller = MaintenanceController(transport: LeasedTransport(session: self, lease: lease), clientTag: tag, progress: progress)
        do { return try await controller.run(operation, id: id) }
        catch {
            // A lost ACK does not mean a write/reset was rolled back. Do not reuse a
            // descriptor whose device ID, firmware state or baud may already have changed.
            if operation.changesDeviceState {
                pending = nil; io.close(fd); fd = -1
            }
            throw error
        }
    }

    fileprivate func maintenanceTransfer(_ bytes: [UInt8], responseLength: Int, timeout: Duration, lease: UUID) throws -> [UInt8] {
        guard fd >= 0, maintenanceLease == lease else { throw MotorError.serial("串口维护会话已失效") }
        try Task.checkCancellation()
        guard io.flush(fd) else { throw MotorError.serial("串口已断开") }
        let written = io.write(fd, bytes: bytes, timeout: 100)
        guard written == bytes.count else { throw MotorError.serial("维护报文发送失败") }
        statistics.sent += 1
        if responseLength == 0 { return [] }
        let deadline = ContinuousClock.now + timeout
        var collected: [UInt8] = []
        var sawBytes = false
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let incoming = try io.read(fd, capacity: 512, timeout: 2)
            if !incoming.isEmpty { sawBytes = true }
            collected += incoming
            while collected.count >= 2 {
                if collected[0] != 0xfc || collected[1] != 0xee { collected.removeFirst(); continue }
                guard collected.count >= responseLength else { break }
                let frame = Array(collected.prefix(responseLength))
                let valid = ServoProtocol.read32(frame, responseLength - 4) == (try ServoProtocol.crc(Array(frame[2..<(responseLength - 4)])))
                if !valid { statistics.badCRC += 1; collected.removeFirst(); continue }
                collected.removeFirst(responseLength)
                guard frame[2] & 15 == bytes[2] & 15 else { statistics.wrongID += 1; continue }
                statistics.received += 1
                return frame
            }
        }
        statistics.timeouts += 1
        if sawBytes { throw MotorError.collision }
        throw MotorError.timeout
    }

    fileprivate func rawIDs(_ request: [UInt8], timeout: Duration, lease: UUID) throws -> [UInt8] {
        guard fd >= 0, maintenanceLease == lease else { throw MotorError.serial("扫描会话失效") }
        try Task.checkCancellation()
        guard io.flush(fd) else { throw MotorError.serial("串口已断开") }
        let written = io.write(fd, bytes: request, timeout: 100)
        guard written == request.count else { throw MotorError.serial("扫描请求发送失败") }
        statistics.sent += 1
        var result: [UInt8] = []
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            result += try io.read(fd, capacity: 32, timeout: 2)
            guard result.count <= 31 else { throw MotorError.invalid("扫描数据超过原 SDK 的 31 字节上限") }
        }
        return result
    }

    fileprivate func reopenForScan(lease: UUID) throws {
        guard maintenanceLease == lease else { throw MotorError.serial("扫描会话失效") }
        io.close(fd); fd = -1
        fd = try io.open(connectedPath, baud: connectedBaud)
        parser.clearPartialFrame()
    }

    fileprivate func maintenanceBaud(_ baud: Int, lease: UUID) throws {
        guard fd >= 0, maintenanceLease == lease else { throw MotorError.serial("串口维护会话已失效") }
        guard io.setBaud(fd, baud: baud) else { throw MotorError.serial("主机切换到 \(baud) bps 失败；请确认设备当前速率后重新连接") }
        connectedBaud = baud
    }
}

private struct LeasedTransport: MaintenanceTransport {
    let session: SerialSession
    let lease: UUID
    func currentBaud() async -> Int { await session.baud }
    func transact(_ bytes: [UInt8], responseLength: Int, timeout: Duration) async throws -> [UInt8] {
        try await session.maintenanceTransfer(bytes, responseLength: responseLength, timeout: timeout, lease: lease)
    }
    func recoverLink() async throws { try await session.reopenForScan(lease: lease) }
    func collectIDs(_ request: [UInt8], timeout: Duration) async throws -> [UInt8] {
        try await session.rawIDs(request, timeout: timeout, lease: lease)
    }
    func setBaud(_ baud: Int) async throws { try await session.maintenanceBaud(baud, lease: lease) }
}
