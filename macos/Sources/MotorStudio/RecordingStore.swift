import Foundation
import MotorCore

struct RecordSummary: Sendable {
    let count: Int
    let span: Double
    let lastTime: Date?
}
struct ChartRequest: Sendable, Equatable {
    let motorID: Int
    let metrics: [ChartMetric]
    let side: ControlSide
    let window: Double
    let offset: Double
    let end: Date?
    let budget: Int
    let broadcast: Bool
}
struct CurvePoint: Identifiable, Sendable {
    let id: String
    let time: Date
    let value: Double
    let series: String
}
struct ChartSnapshot: Sendable {
    var revision = 0
    var points: [CurvePoint] = []
    var samples: [Sample] = []
    var range: ClosedRange<Double> = -1...1
}

actor RecordingStore {
    private var motors: [Int: IndexedRecording] = [:]
    private var retention: Double = 300
    private var revision = 0
    private var lastTime: Date?
    private var cache: (request: ChartRequest, revision: Int, snapshot: ChartSnapshot)?
    private(set) var chartBuildCount = 0
    private(set) var lastQueryInspections = 0
    func append(_ sample: Sample) {
        motors[sample.motorID, default: IndexedRecording()].append(sample)
        lastTime = max(lastTime ?? sample.time, sample.time)
        // At most 15 small per-motor indexes; expiry only advances their heads.
        expire(); revision &+= 1
    }
    private func expire() {
        guard let lastTime else { return }
        let cutoff = lastTime.addingTimeInterval(-retention)
        for id in Array(motors.keys) { motors[id]?.expire(before: cutoff) }
    }
    func clear() { motors = [:]; lastTime = nil; cache = nil; revision &+= 1 }
    func setRetention(_ seconds: Double) {
        retention = max(1, seconds); expire(); cache = nil; revision &+= 1
    }
    func summary() -> RecordSummary {
        let first = motors.values.compactMap { $0.first?.time }.min()
        let last = motors.values.compactMap { $0.last?.time }.max()
        return RecordSummary(count: motors.values.reduce(0) { $0 + $1.count },
                             span: first.flatMap { a in last.map { $0.timeIntervalSince(a) } } ?? 0, lastTime: last)
    }
    func chart(_ request: ChartRequest) -> ChartSnapshot {
        guard !request.broadcast, !request.metrics.isEmpty else { return ChartSnapshot() }
        if let cache, cache.request == request, cache.revision == revision { return cache.snapshot }
        let end = (request.end ?? lastTime ?? .now).addingTimeInterval(-request.offset)
        var result = motors[request.motorID]?.chart(request, end: end) ?? ChartSnapshot()
        result.revision = revision
        lastQueryInspections = motors[request.motorID]?.lastQueryInspections ?? 0
        chartBuildCount += 1
        cache = (request, revision, result)
        return result
    }
    nonisolated static func makeChart(_ values: [Sample], request: ChartRequest) -> ChartSnapshot {
        var result = ChartSnapshot()
        var retained = Set<Int>()
        var low = Double.infinity, high = -Double.infinity
        let budget = max(32, min(request.budget, 1600))
        for metric in request.metrics {
            let indices = envelopeIndices(count: values.count, budget: budget) { metric.value(values[$0], side: request.side) }
            retained.formUnion(indices)
            for i in indices {
                let sample = values[i], value = metric.value(sample, side: request.side)
                low = min(low, value); high = max(high, value)
                result.points.append(CurvePoint(id: "\(metric.rawValue)-\(sample.id)", time: sample.time,
                    value: value, series: "\(metric.rawValue) · \(metric.unit)"))
            }
        }
        result.samples = retained.sorted().map { values[$0] }
        if low.isFinite, high.isFinite {
            let padding = max((high - low) * 0.08, abs(high) * 0.01, 0.001)
            result.range = (low - padding)...(high + padding)
        }
        return result
    }
    func exportCSV(to url: URL) async throws -> Int {
        let snapshot = motors.values.flatMap { $0.elements }
        return try await Task.detached(priority: .utility) {
            let header = "timestamp,motor_id,position_rad,speed_rad_s,torque_Nm,voltage_V,shell_C,winding_C,error,warning,timed_out,mode,demo,encoder_rad,target_position_rad,target_speed_rad_s,target_torque_Nm,kp_Nm_rad,kd_Nm_per_rad_s,target_bus_Hz"
            let lines = snapshot.sorted { $0.time < $1.time }.map { s in
                [s.time.formatted(.iso8601), String(s.motorID), String(s.position), String(s.speed), String(s.torque),
                 String(s.voltage), String(s.temperature), String(s.windingTemperature), String(s.error),
                 String(s.warning), String(s.timedOut), String(s.mode), String(s.demo), String(s.encoderPosition),
                 String(s.command.position), String(s.command.speed), String(s.command.torque), String(s.command.kp),
                 String(s.command.kd), String(s.commandFrequency)].joined(separator: ",")
            }
            try (header + "\n" + lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return snapshot.count
        }.value
    }
}
