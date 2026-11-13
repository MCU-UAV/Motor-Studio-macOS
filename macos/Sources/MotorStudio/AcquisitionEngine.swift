import Foundation
import MotorCore

struct AcquisitionConfiguration: Sendable {
    let runID: UUID
    let demo: Bool
    let ids: [Int]
    let commands: [Int: MotorCommand]
    let frequency: Double
    let asynchronous: Bool
    let broadcast: Bool
}
struct AcquisitionSnapshot: Sendable {
    let telemetry: [Int: Sample]
    let stats: LinkStatistics
    let lastTX: String
    let elapsed: Double
    let actualFrequency: Double
    let transmitFrequency: Double
    let records: RecordSummary
}
struct AcquisitionResult: Sendable {
    let snapshot: AcquisitionSnapshot
    let stopConfirmed: Bool
    let failure: String?
}

/// A per-run mailbox is prepared synchronously before the worker is launched.
/// This also accepts a command applied immediately after Start, before the actor runs.
final class CommandMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var runID: UUID?
    private var revision = 0
    private var commands: [Int: MotorCommand] = [:]
    func prepare(_ config: AcquisitionConfiguration) {
        lock.lock(); defer { lock.unlock() }
        runID = config.runID; revision = 0; commands = config.commands
    }
    func update(_ updated: [Int: MotorCommand], runID: UUID, revision: Int) {
        lock.lock(); defer { lock.unlock() }
        guard self.runID == runID, revision > self.revision else { return }
        commands = updated; self.revision = revision
    }
    func command(for id: Int, runID: UUID, fallback: MotorCommand) -> MotorCommand {
        lock.lock(); defer { lock.unlock() }
        guard self.runID == runID else { return fallback }
        return commands[id] ?? fallback
    }
}

/// Owns acquisition scheduling. No UI state or MainActor work occurs per sample.
actor AcquisitionEngine {
    let session: SerialSession
    let recordings = RecordingStore()
    private var currentRun: UUID?
    nonisolated let commandMailbox = CommandMailbox()
    private var telemetry: [Int: Sample] = [:]
    private var stats = LinkStatistics()
    private var lastTX = ""
    private var elapsed: Double = 0
    private var actualFrequency: Double = 0
    private var transmitFrequency: Double = 0
    init(session: SerialSession) { self.session = session }

    func reset(retention: Double) async {
        guard currentRun == nil else { return }
        telemetry = [:]; stats = LinkStatistics(); lastTX = ""; elapsed = 0; actualFrequency = 0; transmitFrequency = 0
        await recordings.clear(); await recordings.setRetention(retention)
    }
    func snapshot() async -> AcquisitionSnapshot {
        AcquisitionSnapshot(telemetry: telemetry, stats: stats, lastTX: lastTX, elapsed: elapsed,
                            actualFrequency: actualFrequency, transmitFrequency: transmitFrequency, records: await recordings.summary())
    }
    func run(_ config: AcquisitionConfiguration) async -> AcquisitionResult {
        guard currentRun == nil, !config.ids.isEmpty, config.frequency.isFinite,
              config.ids.allSatisfy({ config.broadcast ? $0 == 15 : (0...14).contains($0) }) else {
            return AcquisitionResult(snapshot: await snapshot(), stopConfirmed: false, failure: "采集配置无效或已有通信任务")
        }
        currentRun = config.runID
        telemetry = [:]; stats = LinkStatistics(); elapsed = 0; actualFrequency = 0; transmitFrequency = 0
        let started = ContinuousClock.now
        let frequency = (try? ControlFrequency.normalized(config.frequency)) ?? 0
        // SDK frequency 0 pauses transmission; it is not an unbounded send rate.
        let period = Duration.seconds(frequency > 0 ? 1 / frequency : 0.01)
        var ids = config.ids
        var failure: String?
        var terminalSample: Sample?
        let streaming = !config.demo && (config.asynchronous || config.broadcast)
        var streamStarted = false
        do {
            try Task.checkCancellation()
            for id in config.ids {
                let command = config.commands[id] ?? MotorCommand(id: id)
                guard command.id == id else { throw MotorError.invalid("控制 ID 不一致") }
                _ = try command.encode()
            }
            if !config.demo {
                if config.broadcast && frequency > 0 {
                    ids = try await session.detectOnlineIDs()
                    guard !ids.isEmpty else { throw MotorError.invalid("未检测到可确认的电机，未发送广播控制") }
                }
                if frequency > 0 {
                    // Frequency counts total control transmissions, as in the SDK.
                    guard config.broadcast || Double(ids.count) / frequency < 0.5 else {
                        throw MotorError.invalid("单台轮询间隔必须小于 0.5 秒；请提高频率或减少电机数量")
                    }
                    let feedback = try await session.prepareForControl(ids: ids)
                    for reply in feedback { telemetry[reply.id] = Sample(reply) }
                    if streaming { try await session.startStream(ids: ids); streamStarted = true }
                }
                stats = await session.statistics
            }
        } catch is CancellationError { }
        catch { failure = error.localizedDescription }
        var deadline = ContinuousClock.now
        var monitorDeadline = deadline
        var rateStarted = deadline
        var previousSent = stats.sent, previousReceived = stats.received
        var tick = 0, monitorTick = 0
        var misses: [Int: Int] = [:]
        let monitorPeriod = Duration.seconds(0.1 / Double(max(1, ids.count)))

        func command(_ id: Int) throws -> MotorCommand {
            var value = commandMailbox.command(for: id, runID: config.runID, fallback: config.commands[id] ?? MotorCommand(id: id))
            guard value.id == id else { throw MotorError.invalid("控制 ID 不一致") }
            value.timeoutProtection = true
            return try value.clamped()
        }
        func sampleFailure(_ sample: Sample, _ command: MotorCommand) -> String? {
            if sample.error != 0 || sample.timedOut { return "ID \(sample.motorID) 报告故障或超时保护，已请求停止" }
            if sample.mode != command.mode.rawValue { return "ID \(sample.motorID) 反馈模式与指令不一致，已请求停止" }
            return nil
        }
        while failure == nil && !Task.isCancelled {
            var received: [(MotorFeedback, MotorCommand)] = []
            var expiredIDs: [Int] = []
            do {
                try Task.checkCancellation()
                if streamStarted {
                    let update = try await session.pollStream()
                    received = update.feedback.map { ($0.feedback, $0.command) }
                    expiredIDs = update.expiredIDs
                }
                for (feedback, sentCommand) in received {
                    var sample = Sample(feedback)
                    sample.command = sentCommand.converted(to: .output); sample.commandFrequency = frequency
                    telemetry[sample.motorID] = sample
                    if let reason = sampleFailure(sample, sentCommand) { terminalSample = sample; throw MotorError.serial(reason) }
                    sample.raw = ""; await recordings.append(sample); misses[sample.motorID] = 0
                }
                for id in expiredIDs {
                    misses[id, default: 0] += 1
                    if misses[id, default: 0] >= 3 { throw MotorError.serial("ID \(id) 连续反馈超时，已请求停止") }
                }
                if config.broadcast && streamStarted && ContinuousClock.now >= monitorDeadline {
                    let id = ids[monitorTick % ids.count]
                    var check = try command(15); check.id = id
                    try await session.sendStream(check)
                    lastTX = try check.encode().hex
                    monitorTick += 1; monitorDeadline = .now + monitorPeriod
                }
                if frequency > 0 && ContinuousClock.now >= deadline {
                    let id = config.broadcast ? 15 : ids[tick % ids.count]
                    let value = try command(id)
                    if config.demo {
                        stats.sent += 1
                        if !config.broadcast {
                            var sample = Sample(demoID: id, time: .now, phase: seconds(started.duration(to: .now)) * 0.46 + Double(id))
                            sample.mode = value.mode.rawValue; sample.command = value.converted(to: .output); sample.commandFrequency = frequency
                            telemetry[id] = sample; stats.received += 1; await recordings.append(sample)
                        }
                    } else if config.broadcast {
                        try await session.broadcast(value)
                    } else if streaming {
                        try await session.sendStream(value)
                    } else {
                        do {
                            var sample = Sample(try await session.exchange(value))
                            sample.command = value.converted(to: .output); sample.commandFrequency = frequency
                            telemetry[id] = sample
                            if let reason = sampleFailure(sample, value) { terminalSample = sample; throw MotorError.serial(reason) }
                            sample.raw = ""; await recordings.append(sample); misses[id] = 0
                        } catch MotorError.timeout {
                            misses[id, default: 0] += 1
                            if misses[id, default: 0] >= 3 { throw MotorError.timeout }
                        }
                    }
                    lastTX = try value.encode().hex
                    tick += 1; deadline += period
                    if deadline <= .now { deadline = .now + period }
                }
                if !config.demo { stats = await session.statistics }
                elapsed = seconds(started.duration(to: .now))
                let duration = seconds(rateStarted.duration(to: .now))
                if duration >= 0.5 {
                    transmitFrequency = Double(stats.sent - previousSent) / duration
                    actualFrequency = Double(stats.received - previousReceived) / duration
                    previousSent = stats.sent; previousReceived = stats.received; rateStarted = .now
                }
                if streaming && frequency > 0 { try await Task.sleep(for: .microseconds(100)) }
                else { try await Task.sleep(until: frequency > 0 ? deadline : .now + .milliseconds(10), clock: .continuous) }
            } catch is CancellationError { break }
            catch { failure = error.localizedDescription; break }
        }
        let known = Array(Set(ids.filter { $0 < 15 }).union(telemetry.keys))
        let session = session
        let confirmed: Bool
        if config.demo { confirmed = true }
        else {
            confirmed = await Task.detached(priority: .userInitiated) { await session.stop(ids: known) }.value
            stats = await session.statistics
        }
        if var sample = terminalSample { sample.raw = ""; await recordings.append(sample) }
        elapsed = seconds(started.duration(to: .now))
        let result = AcquisitionResult(snapshot: await snapshot(), stopConfirmed: confirmed, failure: failure)
        currentRun = nil
        return result
    }

}
private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}
