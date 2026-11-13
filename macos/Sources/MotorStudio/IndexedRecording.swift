import Foundation
import MotorCore

/// Per-motor append index. Complete 32-sample blocks are combined into a min/max
/// pyramid. Queries inspect only the boundary samples and O(log n) summaries.
/// Raw samples remain available for CSV; display reduction never changes them.
struct IndexedRecording {
    private static let blockSize = 32
    private var samples: [Sample] = []
    private var head = 0
    private var base = 0
    private var levels: [[Int: Extrema]] = [[:]]
    private var prunedBlocks = 0
    private(set) var lastQueryInspections = 0
    var count: Int { samples.count - head }
    var first: Sample? { count > 0 ? samples[head] : nil }
    var last: Sample? { count > 0 ? samples.last : nil }
    var elements: [Sample] { Array(samples[head...]) }

    private struct Extrema {
        var minimum: [Int]
        var maximum: [Int]
    }
    private func sample(_ index: Int) -> Sample { samples[index - base] }
    private func merged(_ a: Extrema, _ b: Extrema) -> Extrema {
        var result = a
        for (i, metric) in ChartMetric.allCases.enumerated() {
            if metric.value(sample(b.minimum[i]), side: .output) < metric.value(sample(a.minimum[i]), side: .output) { result.minimum[i] = b.minimum[i] }
            if metric.value(sample(b.maximum[i]), side: .output) > metric.value(sample(a.maximum[i]), side: .output) { result.maximum[i] = b.maximum[i] }
        }
        return result
    }
    mutating func append(_ value: Sample) {
        let index = base + samples.count
        samples.append(value)
        let leaf = index / Self.blockSize
        let singleton = Extrema(minimum: Array(repeating: index, count: ChartMetric.allCases.count), maximum: Array(repeating: index, count: ChartMetric.allCases.count))
        levels[0][leaf] = levels[0][leaf].map { merged($0, singleton) } ?? singleton
        guard (index + 1) % Self.blockSize == 0 else { return }
        var child = leaf, level = 0
        while child % 2 == 1 {
            guard let left = levels[level][child - 1], let right = levels[level][child] else { break }
            let parent = merged(left, right)
            level += 1; child /= 2
            if levels.count <= level { levels.append([:]) }
            levels[level][child] = parent
        }
    }
    mutating func expire(before cutoff: Date) {
        while head < samples.count && samples[head].time < cutoff { head += 1 }
        // Discard complete expired blocks. Keep a boundary block intact until it
        // expires, since its summaries can reference an earlier sample in it.
        let firstBlock = (base + head) / Self.blockSize
        if firstBlock > prunedBlocks {
            for block in prunedBlocks..<firstBlock { levels[0][block] = nil }
            for level in 1..<levels.count {
                let stride = 1 << level
                let previous = (prunedBlocks + stride - 1) >> level, next = (firstBlock + stride - 1) >> level
                if next > previous { for key in previous..<next { levels[level][key] = nil } }
            }
            prunedBlocks = firstBlock
        }
        let removable = firstBlock * Self.blockSize - base
        if removable > 4096 && removable * 2 > samples.count {
            samples.removeFirst(removable); head -= removable; base += removable
        }
    }
    private func lowerBound(_ date: Date, inclusive: Bool) -> Int {
        var lo = head, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].time < date || (!inclusive && samples[mid].time == date) { lo = mid + 1 }
            else { hi = mid }
        }
        return base + lo
    }
    mutating func chart(_ request: ChartRequest, end: Date) -> ChartSnapshot {
        lastQueryInspections = 0
        let lo = lowerBound(end.addingTimeInterval(-request.window), inclusive: true)
        let hi = lowerBound(end, inclusive: false)
        guard hi > lo else { return ChartSnapshot() }
        // Direct reduction wins on short windows; the index pays off on long
        // histories. Avoid dictionary traversal for a few thousand samples.
        if hi - lo < 65536 {
            lastQueryInspections = hi - lo
            return RecordingStore.makeChart(Array(samples[(lo - base)..<(hi - base)]), request: request)
        }
        let budget = max(32, min(request.budget, 1600))
        let selected = request.metrics.map { ChartMetric.allCases.firstIndex(of: $0)! }
        var indices = Array(repeating: Set<Int>(), count: selected.count)
        if hi - lo <= budget {
            for i in indices.indices { indices[i] = Set(lo..<hi) }
        } else {
            let buckets = max(1, (budget - 2) / 2)
            for i in indices.indices { indices[i] = [lo, hi - 1] }
            for bucket in 0..<buckets {
                let start = lo + 1 + (hi - lo - 2) * bucket / buckets
                let finish = lo + 1 + (hi - lo - 2) * (bucket + 1) / buckets
                guard start < finish else { continue }
                var minima = Array(repeating: start, count: selected.count)
                var maxima = minima
                func include(_ low: [Int], _ high: [Int]) {
                    for j in selected.indices {
                        let metric = request.metrics[j]
                        if metric.value(sample(low[j]), side: .output) < metric.value(sample(minima[j]), side: .output) { minima[j] = low[j] }
                        if metric.value(sample(high[j]), side: .output) > metric.value(sample(maxima[j]), side: .output) { maxima[j] = high[j] }
                    }
                }
                var cursor = start
                while cursor < finish {
                    let block = cursor / Self.blockSize
                    if cursor % Self.blockSize == 0 && cursor + Self.blockSize <= finish {
                        var level = 0
                        while level + 1 < levels.count && block % (1 << (level + 1)) == 0 && cursor + Self.blockSize * (1 << (level + 1)) <= finish && levels[level + 1][block >> (level + 1)] != nil { level += 1 }
                        if let summary = levels[level][block >> level] {
                            include(selected.map { summary.minimum[$0] }, selected.map { summary.maximum[$0] })
                            cursor += Self.blockSize * (1 << level); lastQueryInspections += 1
                            continue
                        }
                    }
                    include(Array(repeating: cursor, count: selected.count), Array(repeating: cursor, count: selected.count))
                    cursor += 1; lastQueryInspections += 1
                }
                for j in selected.indices { indices[j].insert(minima[j]); indices[j].insert(maxima[j]) }
            }
        }
        var result = ChartSnapshot(), all = Set<Int>()
        var low = Double.infinity, high = -Double.infinity
        for (j, metric) in request.metrics.enumerated() {
            let series = "\(metric.rawValue) · \(metric.unit)"
            all.formUnion(indices[j])
            for index in indices[j].sorted() {
                let row = sample(index), value = metric.value(row, side: request.side)
                low = min(low, value); high = max(high, value)
                result.points.append(CurvePoint(id: "\(metric.rawValue)-\(row.id)", time: row.time, value: value, series: series))
            }
        }
        result.samples = all.sorted().map { sample($0) }
        if low.isFinite, high.isFinite {
            let padding = max((high - low) * 0.08, abs(high) * 0.01, 0.001)
            result.range = (low - padding)...(high + padding)
        }
        return result
    }
}
