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
    init(session: SerialSession) { self.session = session }

    func reset(retention: Double) async {
        guard currentRun == nil else { return }
        telemetry = [:]; stats = LinkStatistics(); lastTX = ""; elapsed = 0; actualFrequency = 0
        await recordings.clear(); await recordings.setRetention(retention)
    }
    func snapshot() async -> AcquisitionSnapshot {
        AcquisitionSnapshot(telemetry: telemetry, stats: stats, lastTX: lastTX, elapsed: elapsed,
                            actualFrequency: actualFrequency, records: await recordings.summary())
    }
    func run(_ config: AcquisitionConfiguration) async -> AcquisitionResult {
        guard currentRun == nil, !config.ids.isEmpty, config.frequency.isFinite,
              (1...1000).contains(config.frequency), config.ids.allSatisfy({ config.broadcast ? $0 == 15 : (0...14).contains($0) }) else {
            return AcquisitionResult(snapshot: await snapshot(), stopConfirmed: false, failure: "采集配置无效或已有通信任务")
        }
        currentRun = config.runID
        telemetry = [:]; elapsed = 0; actualFrequency = 0
        let started = ContinuousClock.now
        let period = Duration.seconds(1 / config.frequency)
        var deadline = started
        var rateStarted = started
        var rateFrames = 0
        var tick = 0
        var misses: [Int: Int] = [:]
        var failure: String?
        // UI refresh cadence is unrelated to this serial startup handshake.
        // Broadcast has no ACK and cannot establish that every recipient is ready.
        do {
            try Task.checkCancellation()
            for id in config.ids {
                let command = config.commands[id] ?? MotorCommand(id: id)
                guard command.id == id else { throw MotorError.invalid("控制 ID 与本次通信配置不一致") }
                _ = try command.encode()
            }
            if !config.demo {
                guard !config.broadcast else {
                    throw MotorError.invalid("广播无法逐台确认超时锁存已清除及保护已恢复；请使用勾选 ID 的统一控制")
                }
                // Total bus frequency is shared by all IDs. Leave margin below the 1 s watchdog.
                guard Double(Set(config.ids).count) / config.frequency < 0.5 else {
                    throw MotorError.invalid("单台轮询间隔必须小于 0.5 秒；请提高总线频率或减少电机数量")
                }
                let feedback = try await session.prepareForControl(ids: config.ids)
                for reply in feedback { telemetry[reply.id] = Sample(reply) }
                stats = await session.statistics
                lastTX = try MotorCommand(id: feedback.last!.id).encode().hex
            }
        } catch is CancellationError { }
        catch { failure = error.localizedDescription }
        // Start the communication schedule after the handshake, not at the UI click.
        deadline = .now; rateStarted = deadline
        while failure == nil && !Task.isCancelled {
            let id = config.ids[tick % config.ids.count]
            var command = commandMailbox.command(for: id, runID: config.runID, fallback: config.commands[id] ?? MotorCommand(id: id))
            command.timeoutProtection = true
            do {
                try Task.checkCancellation()
                guard command.id == id else { throw MotorError.invalid("控制 ID 与本次通信配置不一致") }
                let encoded = try command.encode()
                if config.broadcast {
                    if config.demo { stats.sent += 1 }
                    else { try await session.broadcast(command); stats = await session.statistics }
                } else {
                    var sample: Sample
                    if config.demo {
                        sample = Sample(demoID: id, time: .now, phase: seconds(started.duration(to: .now)) * 0.46 + Double(id))
                        sample.mode = command.mode.rawValue
                        stats.sent += 1; stats.received += 1
                    } else if config.asynchronous {
                        try await session.beginAsync(command)
                        var feedback: MotorFeedback?
                        while feedback == nil {
                            try Task.checkCancellation()
                            feedback = try await session.receiveAsync()
                            if feedback == nil { try await Task.sleep(for: .microseconds(200)) }
                        }
                        sample = Sample(feedback!); stats = await session.statistics
                    } else {
                        sample = Sample(try await session.exchange(command)); stats = await session.statistics
                    }
                    sample.command = command.converted(to: .output); sample.commandFrequency = config.frequency
                    telemetry[id] = sample
                    if sample.error != 0 || sample.timedOut {
                        throw MotorError.serial("ID \(id) 报告\(sample.error != 0 ? "故障" : "超时保护")，已请求停止")
                    }
                    guard sample.mode == command.mode.rawValue else {
                        throw MotorError.serial("ID \(id) 反馈模式 \(sample.mode) 与指令 \(command.mode.rawValue) 不一致，已请求停止")
                    }
                    sample.raw = ""
                    await recordings.append(sample)
                    misses[id] = 0
                }
                lastTX = encoded.hex
                rateFrames += 1
            } catch is CancellationError { break }
            catch {
                if !config.demo { stats = await session.statistics }
                if case MotorError.timeout = error, misses[id, default: 0] < 2 { misses[id, default: 0] += 1 }
                else { failure = error.localizedDescription; break }
            }
            let now = ContinuousClock.now
            elapsed = seconds(started.duration(to: now))
            let rateWindow = seconds(rateStarted.duration(to: now))
            if rateWindow >= 0.5 {
                actualFrequency = Double(rateFrames) / rateWindow; rateFrames = 0; rateStarted = now
            }
            tick += 1
            deadline += period
            // Skip missed deadlines instead of producing a burst of catch-up commands.
            if deadline <= now { deadline = now + period }
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { break }
        }
        // Cancellation of acquisition must never cancel the Stop exchange itself.
        let known = Array(Set(config.ids.filter { $0 < 15 }).union(telemetry.keys))
        let session = session
        let confirmed: Bool
        if config.demo { confirmed = true }
        else {
            confirmed = await Task.detached(priority: .userInitiated) {
                await session.cancelAsync()
                return await session.stop(ids: known)
            }.value
            stats = await session.statistics
        }
        elapsed = seconds(started.duration(to: .now))
        let result = AcquisitionResult(snapshot: await snapshot(), stopConfirmed: confirmed, failure: failure)
        currentRun = nil
        return result
    }
}
private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}
