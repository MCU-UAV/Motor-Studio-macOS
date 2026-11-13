import Foundation
@testable import MotorCore

/// No descriptor is opened. Replies queue across writes and arrive after a delay.
private final class DelayedBus: SerialIO, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [(ContinuousClock.Instant, [UInt8])] = []
    private var sent: [[UInt8]] = []
    private var latched: Set<Int>
    private var armed: Set<Int> = []
    private var motionCount: [Int: Int] = [:]
    private(set) var broadcastBeforeAllArmed = false
    private(set) var maxInFlight = 0
    private(set) var delivered = 0
    private(set) var deliveredMotion = 0
    let ids: Set<Int>
    let motionDelay: Duration
    let failure: String
    init(ids: Set<Int> = [0, 3], delay: Duration = .milliseconds(12), failure: String = "") {
        self.ids = ids; latched = ids; motionDelay = delay; self.failure = failure
    }
    func open(_ path: String, baud: Int) throws -> Int32 { 99 }
    func close(_ fd: Int32) { }
    func setBaud(_ fd: Int32, baud: Int) -> Bool { true }
    func flush(_ fd: Int32) -> Bool { lock.lock(); defer { lock.unlock() }; queued = []; return true }
    func packets() -> [[UInt8]] { lock.lock(); defer { lock.unlock() }; return sent }
    func write(_ fd: Int32, bytes: [UInt8], timeout: Int32) -> Int {
        lock.lock(); defer { lock.unlock() }
        sent.append(bytes)
        let id = Int(bytes[2] & 15), mode = Int(bytes[2] >> 4 & 7), protection = bytes[2] & 128 != 0
        precondition(mode == 0 || protection, "No FOC may disable timeout protection")
        if id == 15 {
            if mode == 1 && !ids.isSubset(of: armed) { broadcastBeforeAllArmed = true }
            return bytes.count // Real broadcasts have no acknowledgement.
        }
        guard ids.contains(id) else { return bytes.count }
        if mode == 0 && !protection { latched.remove(id) }
        if mode == 0 && protection && !latched.contains(id) { armed.insert(id) }
        if failure == "arm" && id == 3 && armed.contains(id) && mode == 0 { return bytes.count }
        if mode == 1 {
            motionCount[id, default: 0] += 1
            if failure == "drop" && id == 3 { return bytes.count }
        }
        var fault: UInt32 = 0
        var timedOut = latched.contains(id)
        var replyMode = mode
        if id == 3 && mode == 1 && motionCount[id, default: 0] >= 2 {
            if failure == "fault" { fault = 0x80000001 }
            if failure == "timeout" { timedOut = true; latched.insert(id) }
            if failure == "mode" { replyMode = 0 }
        }
        var reply: [UInt8] = [0xfc, 0xee, UInt8(id | replyMode << 4 | (timedOut ? 128 : 0)), 251, 200, 48]
        reply += Array(bytes[4..<12])
        ServoProtocol.append(fault, to: &reply)
        ServoProtocol.append(UInt16(5 << 13 | 4096), to: &reply)
        reply += [0, 0]
        ServoProtocol.append(try! ServoProtocol.crc(Array(reply[2...])), to: &reply)
        queued.append((.now + (mode == 1 ? motionDelay : .zero), reply))
        maxInFlight = max(maxInFlight, queued.count)
        return bytes.count
    }
    func read(_ fd: Int32, capacity: Int, timeout: Int32) throws -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        guard let index = queued.firstIndex(where: { $0.0 <= .now }) else { return [] }
        let reply = queued.remove(at: index).1
        delivered += 1
        if reply[2] & 0x70 == 0x10 { deliveredMotion += 1 }
        return reply
    }
}

@main struct StreamingRuntime {
    static func config(broadcast: Bool, async: Bool = true, hz: Double = 200) -> AcquisitionConfiguration {
        AcquisitionConfiguration(runID: UUID(), demo: false, ids: broadcast ? [15] : [0, 3],
            commands: broadcast ? [15: MotorCommand(id: 15, mode: .foc, position: 0.01, kp: 0.1)] :
                [0: MotorCommand(id: 0, mode: .foc), 3: MotorCommand(id: 3, mode: .foc)],
            frequency: hz, asynchronous: async, broadcast: broadcast)
    }
    private static func run(_ io: DelayedBus, _ config: AcquisitionConfiguration, duration: Duration = .milliseconds(600)) async throws -> (AcquisitionResult, AcquisitionEngine) {
        let session = SerialSession(io: io)
        try await session.connect(path: "/dev/cu.simulated")
        let engine = AcquisitionEngine(session: session)
        engine.commandMailbox.prepare(config)
        let task = Task { await engine.run(config) }
        try await Task.sleep(for: duration)
        task.cancel()
        return (await task.value, engine)
    }
    static func main() async throws {
        var counts: [Int] = []
        for asynchronous in [false, true] {
            let io = DelayedBus()
            let (result, _) = try await run(io, config(broadcast: false, async: asynchronous))
            precondition(result.failure == nil && result.stopConfirmed)
            let motion = io.packets().filter { $0[2] & 0x70 == 0x10 }.count
            counts.append(motion)
            precondition(result.snapshot.records.count == io.deliveredMotion)
            precondition(result.snapshot.stats.received == io.delivered)
            if asynchronous { precondition(io.maxInFlight > 1) }
            else { precondition(io.maxInFlight == 1) }
            print("PASS \(asynchronous ? "async" : "sync") delayed replies: \(motion) sends, max pending \(io.maxInFlight), TX \(result.snapshot.transmitFrequency), RX \(result.snapshot.actualFrequency)")
        }
        precondition(counts[1] > counts[0], "Async sends must continue before previous replies arrive")
        for failure in ["", "arm", "fault", "timeout", "mode", "drop", "empty"] {
            let io = DelayedBus(ids: failure == "empty" ? [] : [0, 3], failure: failure)
            let (result, engine) = try await run(io, config(broadcast: true))
            let frames = io.packets()
            let broadcasts = frames.filter { $0[2] == 0x9f }
            precondition(!io.broadcastBeforeAllArmed)
            precondition(result.snapshot.stats.received == io.delivered, "Broadcast must not invent feedback counts")
            if failure == "empty" || failure == "arm" {
                precondition(broadcasts.isEmpty && result.failure != nil)
            } else {
                precondition(!broadcasts.isEmpty)
                let first = frames.firstIndex { $0[2] == 0x9f }!
                for id in [0, 3] {
                    let clear = frames[..<first].firstIndex { $0[2] == UInt8(id) }!
                    precondition(frames[clear + 1][2] == UInt8(id | 128))
                    precondition(frames[clear][4..<16].allSatisfy { $0 == 0 })
                }
                precondition(result.snapshot.telemetry.count == 2)
                if failure.isEmpty {
                    precondition(result.failure == nil && result.stopConfirmed && result.snapshot.records.count > 0)
                } else {
                    precondition(result.failure != nil)
                    if failure != "drop" {
                        let chart = await engine.recordings.chart(ChartRequest(motorID: 3, metrics: [.timeout, .mode], side: .output, window: 30, offset: 0, end: nil, budget: 100, broadcast: false))
                        precondition(chart.samples.contains { failure == "fault" ? $0.error != 0 : failure == "timeout" ? $0.timedOut : $0.mode == 0 })
                    }
                    let stop = frames.lastIndex { $0[2] == 0x8f }!
                    precondition(frames[stop...].allSatisfy { $0[2] & 0x70 == 0 })
                }
            }
            print("PASS broadcast \(failure.isEmpty ? "healthy" : failure): \(broadcasts.count) broadcast frames, actual RX \(io.delivered)")
        }
        for broadcast in [false, true] {
            let io = DelayedBus()
            let (result, _) = try await run(io, config(broadcast: broadcast, hz: 0), duration: .milliseconds(80))
            precondition(result.failure == nil && result.snapshot.records.count == 0)
            precondition(io.packets().allSatisfy { $0[2] & 0xf0 == 0x80 }, "Zero Hz must not clear latches or move")
        }
        print("PASS zero frequency pauses, cancellation only sends protected Stop")
        // Every UI row is exercised, with independent expected display values.
        var sample = Sample(demoID: 3, time: .now, phase: 0)
        sample.demo = false; sample.position = 0.2; sample.speed = -0.3; sample.torque = 0.4
        sample.temperature = -5; sample.windingTemperature = 200; sample.voltage = 24
        sample.encoderPosition = .pi; sample.mode = 1; sample.error = 0x80000001; sample.warning = 5; sample.timedOut = true
        let command = MotorCommand(id: 3, mode: .foc, torque: 0.1, speed: 0.2, position: 0.3, kp: -1, kd: 2)
        let expected = ["FOC", "开启", "0.1000", "0.2000", "0.3000", "-1.0000", "2.0000", "异常", "3", "FOC", "已触发", "0.4000", "-0.3000", "0.2000", "3.1416", "-5", "200", "24.0000", "0x80000001", "5"]
        precondition(MotorTableRow.allCases.map { $0.value(sample: sample, command: command, side: .output, running: true) } == expected)
        func value(_ row: MotorTableRow) -> String { row.value(sample: sample, command: command, side: .rotor, running: true) }
        precondition(value(.targetSpeed) == String(format: "%.4f", 0.2 * ServoProtocol.ratio))
        precondition(value(.kp) == String(format: "%.4f", -1 / pow(ServoProtocol.ratio, 2)))
        precondition(value(.torque) == String(format: "%.4f", 0.4 / ServoProtocol.ratio))
        precondition(value(.encoder) == "3.1416", "Output encoder is not scaled to rotor")
        sample.timedOut = false; sample.error = 0; sample.time = .now.addingTimeInterval(-1)
        precondition(MotorTableRow.communication.value(sample: sample, command: nil, side: .output, running: true) == "反馈过期")
        precondition(MotorTableRow.communication.value(sample: nil, command: nil, side: .output, running: true) == "无反馈")
        print("PASS complete 20-row table, signed/unsigned values, rotor conversion, stale/missing feedback")
    }
}
