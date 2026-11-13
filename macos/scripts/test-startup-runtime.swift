import Foundation
@testable import MotorCore

/// Hardware-free driver shared with the latch unit tests (compiled by the runner).
@main struct StartupRuntime {
    static func main() async throws {
        for asynchronous in [false, true] {
            let io = LatchedSerial()
            let session = SerialSession(io: io)
            try await session.connect(path: "/dev/cu.simulated")
            let engine = AcquisitionEngine(session: session)
            let config = AcquisitionConfiguration(runID: UUID(), demo: false, ids: [0, 3],
                commands: [0: MotorCommand(id: 0, mode: .foc, position: 0.1, kp: 1),
                           3: MotorCommand(id: 3, mode: .foc, position: 0.2, kp: 1)],
                frequency: 100, asynchronous: asynchronous, broadcast: false)
            engine.commandMailbox.prepare(config)
            let task = Task { await engine.run(config) }
            try await Task.sleep(for: .milliseconds(80))
            // A stale/client command cannot turn off protection during control.
            engine.commandMailbox.update([0: MotorCommand(id: 0, mode: .foc, position: 0.3, kp: 1, timeoutProtection: false)], runID: config.runID, revision: 1)
            try await Task.sleep(for: .milliseconds(40))
            task.cancel(); let result = await task.value
            precondition(result.failure == nil && result.stopConfirmed)
            let frames = io.packets()
            precondition(Array(frames.prefix(4)).map { $0[2] } == [0, 128, 3, 131])
            precondition(frames.prefix(4).allSatisfy { $0[4..<16].allSatisfy { $0 == 0 } })
            let motion = frames.filter { $0[2] & 0x70 == 0x10 }
            precondition(!motion.isEmpty && motion.allSatisfy { $0[2] & 128 != 0 })
            // Latch again between sessions; the second run must repeat both Stop steps.
            io.relatch()
            let before = frames.count
            let restart = Task { await engine.run(config) }
            try await Task.sleep(for: .milliseconds(50)); restart.cancel()
            let restarted = await restart.value
            precondition(restarted.failure == nil)
            precondition(Array(io.packets().dropFirst(before).prefix(4)).map { $0[2] } == [0, 128, 3, 131])
            print("PASS \(asynchronous ? "async" : "sync"): all-ID handshake before FOC, protection maintained, restart handshake")
        }
        for failure: LatchedSerial.Failure in [.stuck, .clearMissing, .armMissing, .fault, .wrongMode, .wrongID, .badCRC] {
            let io = LatchedSerial(failure)
            let session = SerialSession(io: io)
            try await session.connect(path: "/dev/cu.simulated")
            let engine = AcquisitionEngine(session: session)
            let config = AcquisitionConfiguration(runID: UUID(), demo: false, ids: [0], commands: [0: MotorCommand(mode: .foc, kp: 1)], frequency: 100, asynchronous: false, broadcast: false)
            let result = await engine.run(config)
            precondition(result.failure != nil && io.packets().allSatisfy { $0[2] & 0x70 == 0 })
            precondition(io.packets().first?[2] == 0 && io.packets().dropFirst().first?[2] == 128)
        }
        for asynchronous in [false, true] {
          for fault: LatchedSerial.Failure in [.motionMode, .motionFault, .motionTimeout] {
            let io = LatchedSerial(fault)
            let session = SerialSession(io: io)
            try await session.connect(path: "/dev/cu.simulated")
            let engine = AcquisitionEngine(session: session)
            let config = AcquisitionConfiguration(runID: UUID(), demo: false, ids: [0], commands: [0: MotorCommand(mode: .foc)], frequency: 100, asynchronous: asynchronous, broadcast: false)
            let result = await engine.run(config)
            precondition(result.failure != nil)
            precondition(result.snapshot.records.count == 1, "Triggering feedback must be recorded")
            let chart = await engine.recordings.chart(ChartRequest(motorID:0, metrics:[.mode,.timeout], side:.output, window:30, offset:0, end:nil, budget:32, broadcast:false))
            precondition(chart.samples.count == 1)
            let sample = chart.samples[0]
            precondition(fault == .motionMode ? sample.mode == 0 : fault == .motionFault ? sample.error != 0 : sample.timedOut)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("fault-record-\(UUID()).csv")
            let exported = try await engine.recordings.exportCSV(to:url)
            precondition(exported == 1)
            try FileManager.default.removeItem(at:url)
            precondition(io.packets().filter { $0[2] & 0x70 == 0x10 }.count == 1)
            precondition(io.packets().last![2] & 0x70 == 0)
        }
        }
        for (ids, frequency) in [([0], 1.0), ([0, 3], 2.0), (Array(0...14), 20.0)] {
            let io = LatchedSerial()
            let link = SerialSession(io: io)
            try await link.connect(path: "/dev/cu.simulated")
            let engine = AcquisitionEngine(session: link)
            let config = AcquisitionConfiguration(runID: UUID(), demo: false, ids: ids, commands: [:], frequency: frequency, asynchronous: false, broadcast: false)
            let result = await engine.run(config)
            precondition(result.failure?.contains("轮询间隔") == true)
            precondition(io.packets().allSatisfy { $0[2] & 0x70 == 0 && $0[2] & 128 != 0 })
        }
        print("PASS mismatched feedback mode stops immediately; unsafe per-ID polling rates rejected")
        // A new timeout during motion remains a fault; never auto-clear and resume.
        do {
            let io = LatchedSerial()
            let link = SerialSession(io: io)
            try await link.connect(path: "/dev/cu.simulated")
            let engine = AcquisitionEngine(session: link)
            let config = AcquisitionConfiguration(runID: UUID(), demo: false, ids: [0], commands: [0: MotorCommand(mode: .foc)], frequency: 100, asynchronous: false, broadcast: false)
            let task = Task { await engine.run(config) }
            try await Task.sleep(for: .milliseconds(60)); io.relatch()
            let result = await task.value
            precondition(result.failure != nil)
            precondition(io.packets().filter { $0[2] & 128 == 0 }.count == 1)
            precondition(io.packets().last![2] & 0x70 == 0)
            print("PASS timeout during motion still stops; no automatic clear/resume")
        }
        let io = LatchedSerial()
        io.afterClear = { withUnsafeCurrentTask { $0?.cancel() } }
        let session = SerialSession(io: io)
        try await session.connect(path: "/dev/cu.simulated")
        let engine = AcquisitionEngine(session: session)
        let config = AcquisitionConfiguration(runID: UUID(), demo: false, ids: [0], commands: [0: MotorCommand(mode: .foc)], frequency: 100, asynchronous: true, broadcast: false)
        let cancelled = Task { await engine.run(config) }
        _ = await cancelled.value
        precondition(io.packets().prefix(2).map { $0[2] } == [0, 128])
        precondition(io.packets().allSatisfy { $0[2] & 0x70 == 0 })
        print("PASS lost/corrupt ACK, latch/fault and cancellation: no FOC")
        let store = RecordingStore()
        for i in 0...1000 {
            await store.append(Sample(demoID:0,time:Date(timeIntervalSince1970:Double(i)/1000),phase:0))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("csv-precision-\(UUID()).csv")
        let exported = try await store.exportCSV(to:url)
        let csv = try String(contentsOf:url,encoding:.utf8)
        let timestamps = csv.split(separator:"\n").dropFirst().map{String($0.split(separator:",")[0])}
        precondition(exported == 1001 && Set(timestamps).count == 1001, "CSV must preserve 1 ms sample times")
        try FileManager.default.removeItem(at:url)
        print("PASS all six triggering fault frames retained in chart/CSV; 1000 Hz CSV timestamps distinct")
    }
}
