import Foundation
import Observation
import MotorCore

@main struct NativeRuntimeTests {
    static func main() async throws {
        try await testReadout()
        let engine = AcquisitionEngine(session: SerialSession())
        await engine.reset(retention: 3600)
        let runID = UUID()
        let config = AcquisitionConfiguration(runID: runID, demo: true, ids: [0,1,2],
            commands: [0: MotorCommand(id: 0), 1: MotorCommand(id: 1), 2: MotorCommand(id: 2)],
            frequency: 100, asynchronous: false, broadcast: false)
        engine.commandMailbox.prepare(config)
        let loop = Task.detached { await engine.run(config) }
        try await Task.sleep(for: .milliseconds(100))
        let before = await engine.snapshot()
        // Intentionally block MainActor: acquisition must continue independently.
        await MainActor.run { Thread.sleep(forTimeInterval: 0.7) }
        let after = await engine.snapshot()
        precondition(after.stats.received - before.stats.received >= 55, "Acquisition stalled with MainActor")
        var newer = MotorCommand(id: 0, mode: .foc); newer.position = 0.8
        engine.commandMailbox.update([0:newer], runID: runID, revision: 2)
        engine.commandMailbox.update([0:MotorCommand(id:0)], runID: runID, revision: 1)
        try await Task.sleep(for: .milliseconds(60))
        let commandSnapshot = await engine.snapshot()
        precondition(commandSnapshot.telemetry[0]?.command.position == 0.8)
        let stoppedAt = ContinuousClock.now
        loop.cancel(); let result = await loop.value
        let stopDuration = stoppedAt.duration(to: .now)
        precondition(stopDuration < .milliseconds(150), "Demo stop delayed")
        precondition(result.stopConfirmed && result.failure == nil, result.failure ?? "stop unconfirmed")
        precondition(result.snapshot.records.count == result.snapshot.stats.received)
        let rowsBefore = result.snapshot.records.count
        try await Task.sleep(for: .milliseconds(80))
        let stopped = await engine.snapshot()
        precondition(stopped.records.count == rowsBefore, "Acquisition continued after stop")
        print("PASS off-main acquisition: \(after.stats.received - before.stats.received) frames during 700 ms main-thread stall; stop \(stopDuration)")

        let request = ChartRequest(motorID: 0, metrics: [.position, .speed], side: .output, window: 3600,
                                   offset: 0, end: nil, budget: 128, broadcast: false)
        let chart = await engine.recordings.chart(request)
        precondition(chart.points.count <= 256 && !chart.points.isEmpty)
        precondition(chart.samples.allSatisfy { $0.motorID == 0 })
        var synthetic = (0..<10000).map { i in Sample(demoID: 0, time: Date(timeIntervalSince1970: Double(i)), phase: 0) }
        synthetic[3781].position = 800; synthetic[8012].position = -900
        let envelope = RecordingStore.makeChart(synthetic, request: request)
        precondition(envelope.points.contains { $0.value == 800 } && envelope.points.contains { $0.value == -900 })
        precondition(envelope.points.count <= 256)
        let csvURL = FileManager.default.temporaryDirectory.appendingPathComponent("motor-runtime-\(UUID()).csv")
        let exported = try await engine.recordings.exportCSV(to: csvURL)
        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        precondition(exported == rowsBefore && csv.split(separator:"\n").count == exported + 1)
        try FileManager.default.removeItem(at: csvURL)
        print("PASS selected-metric chart budgets, peak preservation, CSV row count \(exported)")

        await engine.reset(retention: 30)
        let fast = AcquisitionConfiguration(runID: UUID(), demo: true, ids: [0], commands: [:],
                                             frequency: 1000, asynchronous: true, broadcast: false)
        let fastLoop = Task.detached { await engine.run(fast) }
        try await Task.sleep(for: .seconds(1))
        fastLoop.cancel(); let fastResult = await fastLoop.value
        print("1000 Hz observed frames: \(fastResult.snapshot.stats.received), elapsed: \(fastResult.snapshot.elapsed)")
        precondition(fastResult.snapshot.stats.received > 0 && fastResult.failure == nil)
        print("PASS 1000 Hz target: \(fastResult.snapshot.stats.received) frames in ~1 s")
        await engine.reset(retention: 30)
        let broadcast = AcquisitionConfiguration(runID: UUID(), demo: true, ids: [15], commands: [15:MotorCommand(id:15)],
                                                  frequency: 100, asynchronous: false, broadcast: true)
        let bus = Task.detached { await engine.run(broadcast) }
        try await Task.sleep(for: .milliseconds(150)); bus.cancel(); let broadcastResult = await bus.value
        precondition(broadcastResult.snapshot.stats.sent > 0 && broadcastResult.snapshot.stats.received == 0 && broadcastResult.snapshot.records.count == 0)
        print("PASS broadcast send-only")
        let failure = AcquisitionConfiguration(runID: UUID(), demo: true, ids: [0], commands: [0: MotorCommand(id: 99)],
                                                  frequency: 100, asynchronous: false, broadcast: false)
        let failed = await engine.run(failure)
        precondition(failed.failure != nil && failed.stopConfirmed)
        let restartID = UUID()
        let restart = AcquisitionConfiguration(runID: restartID, demo: true, ids: [2], commands: [:], frequency: 100, asynchronous: false, broadcast: false)
        engine.commandMailbox.prepare(restart)
        var immediate = MotorCommand(id: 2, mode: .foc); immediate.position = 0.4
        engine.commandMailbox.update([2: immediate], runID: restartID, revision: 1)
        engine.commandMailbox.update([2: MotorCommand(id: 2)], runID: runID, revision: 999)
        let restarted = Task.detached { await engine.run(restart) }
        try await Task.sleep(for: .milliseconds(100)); restarted.cancel()
        let restartedResult = await restarted.value
        precondition(restartedResult.failure == nil && restartedResult.stopConfirmed)
        precondition(Set(restartedResult.snapshot.telemetry.keys) == [2])
        precondition(restartedResult.snapshot.telemetry[2]?.command.position == 0.4)
        print("PASS fault cleanup, restart, immediate command update and stale-run rejection")
        try await testIndexedEquivalence()
        try await testLongRecording()
        try await testModel()
    }
    static func testIndexedEquivalence() async throws {
        var index = IndexedRecording()
        var reference: [Sample] = []
        for i in 0..<150000 {
            var row = Sample(demoID: 2, time: Date(timeIntervalSince1970: Double(i) / 100), phase: Double(i) * 0.013)
            row.position = i == 10003 ? 900 : i == 21999 ? -800 : row.position
            row.torque = Double(i % 91) - 45
            row.command.kp = Double(i % 17); row.command.kd = Double(i % 7)
            index.append(row); reference.append(row)
            if i == 18000 || i == 36000 { index.expire(before: Date(timeIntervalSince1970: Double(i) / 100 - 30)) }
        }
        reference.removeAll { $0.time < Date(timeIntervalSince1970: 330) }
        for side in ControlSide.allCases {
            for window in [0.01, 0.63, 3.2, 37.7, 120.0, 1200.0] {
                for budget in [32, 99, 600] {
                    let request = ChartRequest(motorID: 2, metrics: ChartMetric.allCases, side: side, window: window, offset: 0, end: nil, budget: budget, broadcast: false)
                    let end = Date(timeIntervalSince1970: 1493.21)
                    let values = reference.filter { $0.time >= end.addingTimeInterval(-window) && $0.time <= end }
                    let expected = RecordingStore.makeChart(values, request: request)
                    let actual = index.chart(request, end: end)
                    // Equal extrema can choose different equivalent samples; compare
                    // complete per-series extrema and first/last times, plus the budget.
                    precondition(actual.points.count <= budget * ChartMetric.allCases.count)
                    for metric in ChartMetric.allCases {
                        let series = "\(metric.rawValue) · \(metric.unit)"
                        let a = actual.points.filter { $0.series == series }, b = expected.points.filter { $0.series == series }
                        precondition(a.map(\.value).min() == b.map(\.value).min() && a.map(\.value).max() == b.map(\.value).max())
                        precondition(a.first?.time == b.first?.time && a.last?.time == b.last?.time)
                    }
                }
            }
        }
        let benchmarkRequest = ChartRequest(motorID: 2, metrics: [.position, .speed, .torque], side: .output, window: 3600, offset: 0, end: nil, budget: 600, broadcast: false)
        let benchmarkEnd = reference.last!.time
        let beganBaseline = ContinuousClock.now
        for _ in 0..<10 { precondition(!RecordingStore.makeChart(reference, request: benchmarkRequest).points.isEmpty) }
        let baseline = beganBaseline.duration(to: .now)
        let beganIndexed = ContinuousClock.now
        for _ in 0..<10 { precondition(!index.chart(benchmarkRequest, end: benchmarkEnd).points.isEmpty) }
        print("BENCH identical \(reference.count) rows, 3 metrics, 10 queries: baseline \(baseline), indexed \(beganIndexed.duration(to: .now)); inspected \(index.lastQueryInspections) summaries/boundary rows per query")
        let store = RecordingStore()
        for row in reference.suffix(100) { await store.append(row) }
        let request = ChartRequest(motorID: 2, metrics: [.position], side: .output, window: 20, offset: 0, end: nil, budget: 128, broadcast: false)
        _ = await store.chart(request); _ = await store.chart(request)
        let builds = await store.chartBuildCount; precondition(builds == 1)
        await store.clear(); let cleared = await store.chart(request); precondition(cleared.points.isEmpty)
        print("PASS indexed/reference extrema, 16 metrics, both units, boundary windows, compaction, cache invalidation")
    }
    static func testLongRecording() async throws {
        let store = RecordingStore()
        await store.setRetention(3600)
        // Synthetic timestamps exercise a full hour without an hour-long wall-clock wait.
        var longReference: [Sample] = []
        for i in 0...360000 {
            let sample = Sample(demoID: i % 3, time: Date(timeIntervalSince1970: Double(i) / 100), phase: Double(i) / 1000)
            await store.append(sample)
            if sample.motorID == 1 { longReference.append(sample) }
        }
        let summary = await store.summary()
        precondition(summary.count == 360001 && summary.span == 3600)
        let began = ContinuousClock.now
        let chart = await store.chart(ChartRequest(motorID: 1, metrics: [.position, .speed, .torque], side: .output, window: 3600, offset: 0, end: nil, budget: 600, broadcast: false))
        precondition(chart.points.count <= 1800 && !chart.points.isEmpty)
        precondition(chart.samples.allSatisfy { $0.motorID == 1 })
        print("PASS 360001-row hour retention, 3-metric chart: \(chart.points.count) points in \(began.duration(to: .now))")
        let longRequest = ChartRequest(motorID: 1, metrics: [.position, .speed, .torque], side: .output, window: 3600, offset: 0, end: nil, budget: 600, broadcast: false)
        let baselineBegan = ContinuousClock.now
        for _ in 0..<10 { precondition(!RecordingStore.makeChart(longReference, request: longRequest).points.isEmpty) }
        let baselineDuration = baselineBegan.duration(to: .now)
        let indexedBegan = ContinuousClock.now
        for i in 0..<10 {
            let request = ChartRequest(motorID: 1, metrics: [.position, .speed, .torque], side: .output, window: 3600, offset: 0, end: Date(timeIntervalSince1970: 3600 + Double(i) / 10000), budget: 600, broadcast: false)
            let snapshot = await store.chart(request); precondition(!snapshot.points.isEmpty)
        }
        print("BENCH hour / \(longReference.count) selected rows, 10 queries: baseline \(baselineDuration), indexed \(indexedBegan.duration(to: .now))")
        await store.setRetention(30)
        let trimmed = await store.summary()
        precondition(trimmed.count == 3001 && trimmed.span == 30)
    }
    @MainActor static func testModel() async throws {
        let model = StudioModel()
        let unrelatedInvalidated = LockedFlag()
        withObservationTracking { _ = model.page; _ = model.draft } onChange: { unrelatedInvalidated.set() }
        model.telemetry = [0:Sample(demoID:0,time:.now,phase:1)]
        precondition(!unrelatedInvalidated.value, "Telemetry invalidated navigation/controls")
        model.demo = true; model.connect()
        try await Task.sleep(for: .milliseconds(80)); precondition(model.state == .ready)
        model.scan(); model.start()
        try await Task.sleep(for: .milliseconds(800)); precondition(model.recordCount >= 50)
        model.chartRefreshing = false
        let first = await model.chartSnapshot(metrics:[.position],side:.output,budget:128)
        try await Task.sleep(for: .milliseconds(180))
        let second = await model.chartSnapshot(metrics:[.position],side:.output,budget:128)
        precondition(first.samples.last?.id == second.samples.last?.id)
        await model.refreshChartFromRecording()
        let refreshed = await model.chartSnapshot(metrics:[.position],side:.output,budget:128)
        precondition(refreshed.samples.last?.id != second.samples.last?.id)
        model.stop(disconnect:true)
        try await Task.sleep(for:.milliseconds(120)); precondition(model.state == .disconnected && model.stopConfirmed)
        precondition(model.recordCount == model.stats.received)
        precondition(model.draft.mode == .stop && model.draft.position == 0 && model.draft.kp == 0)
        precondition(model.commands.isEmpty)
        model.draft = MotorCommand(mode: .foc, position: 1, kp: 1)
        model.commands[3] = MotorCommand(id: 3, mode: .foc, position: 1, kp: 1)
        model.connect()
        try await Task.sleep(for: .milliseconds(80))
        precondition(model.draft.mode == .stop && model.commands.isEmpty)
        model.stop(disconnect: true)
        try await Task.sleep(for: .milliseconds(80))
        print("PASS Observation isolation, model connect/scan/pause/manual-refresh/stop/disconnect")
    }
    @MainActor static func testReadout() async throws {
        let model = StudioModel()
        let view = ReadoutView(frame: .zero)
        let outerInvalidated = LockedFlag()
        withObservationTracking {
            view.configure(size: 10, alignment: .left, secondary: false) { model.statisticsText }
        } onChange: { outerInvalidated.set() }
        try await Task.sleep(for: .milliseconds(30))
        for text in ["first update", "second update", "third update"] {
            model.statisticsText = text
            try await Task.sleep(for: .milliseconds(30))
            precondition(view.accessibilityValue() as? String == text, "Native observation failed to rearm")
        }
        precondition(!outerInvalidated.value, "Readout registered telemetry with its parent graph")
        view.configure(size: 10, alignment: .left, secondary: false) { model.lastTX }
        model.lastTX = "new source"
        model.statisticsText = "obsolete source"
        try await Task.sleep(for: .milliseconds(30))
        precondition(view.accessibilityValue() as? String == "new source")
        view.stop()
        model.lastTX = "after teardown"
        try await Task.sleep(for: .milliseconds(30))
        precondition(view.accessibilityValue() as? String == "new source", "Readout updated after teardown")
        print("PASS native readout isolation, repeated updates, source replacement and teardown")
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); defer { lock.unlock() }; flag = true }
}
