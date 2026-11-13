import Foundation

/// Time-based retention with amortized constant-time expiry. No 30,000-frame cutoff.
public struct TimeSeries<Element> {
    private var storage: [(Date, Element)] = []
    private var head = 0
    public var retention: TimeInterval
    public init(retention: TimeInterval = 3600) { self.retention = retention }
    public var count: Int { storage.count - head }
    public var firstTime: Date? { count > 0 ? storage[head].0 : nil }
    public var lastTime: Date? { count > 0 ? storage.last?.0 : nil }
    public var elements: [Element] { storage[head...].map(\.1) }
    public mutating func append(_ value: Element, at time: Date) {
        storage.append((time, value)); expire(at: time)
    }
    public mutating func expire(at time: Date) {
        let cutoff = time.addingTimeInterval(-retention)
        while head < storage.count && storage[head].0 < cutoff { head += 1 }
        if head > 4096 && head * 2 > storage.count { storage.removeFirst(head); head = 0 }
    }
    public func values(from start: Date, through end: Date, matching predicate: (Element) -> Bool) -> [Element] {
        var low = head, high = storage.count
        while low < high {
            let middle = (low + high) / 2
            if storage[middle].0 < start { low = middle + 1 } else { high = middle }
        }
        var result: [Element] = []
        while low < storage.count && storage[low].0 <= end {
            if predicate(storage[low].1) { result.append(storage[low].1) }; low += 1
        }
        return result
    }
    public mutating func removeAll() { storage = []; head = 0 }
}

/// Preserve endpoints and min/max peaks in each time-order bucket.
public func envelopeIndices(count: Int, budget: Int, value: (Int) -> Double) -> [Int] {
    guard count > budget, budget >= 4 else { return Array(0..<count) }
    let buckets = max(1, (budget - 2) / 2)
    var indices = Set([0, count - 1])
    for bucket in 0..<buckets {
        let start = 1 + (count - 2) * bucket / buckets
        let end = 1 + (count - 2) * (bucket + 1) / buckets
        guard start < end else { continue }
        var minimum = start, maximum = start
        for i in start..<end {
            if value(i) < value(minimum) { minimum = i }
            if value(i) > value(maximum) { maximum = i }
        }
        indices.insert(minimum); indices.insert(maximum)
    }
    return indices.sorted()
}
