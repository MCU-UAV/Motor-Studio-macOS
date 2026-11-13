import Foundation

/// 96-bit SN, transmitted as high/middle/low little-endian UInt32 words.
struct SerialNumber96: Comparable, Hashable, Sendable {
    let high: UInt32
    let low: UInt64
    static let zero = SerialNumber96(high: 0, low: 0)
    static let maximum = SerialNumber96(high: .max, low: .max)
    static func < (a: Self, b: Self) -> Bool { a.high == b.high ? a.low < b.low : a.high < b.high }
    var wire: [UInt8] {
        var b: [UInt8] = []
        ServoProtocol.append(high, to: &b); ServoProtocol.append(UInt32(low >> 32), to: &b)
        ServoProtocol.append(UInt32(truncatingIfNeeded: low), to: &b); return b
    }
    init(high: UInt32, low: UInt64) { self.high = high; self.low = low }
    init(wire b: [UInt8]) {
        high = ServoProtocol.read32(b, 0)
        low = UInt64(ServoProtocol.read32(b, 4)) << 32 | UInt64(ServoProtocol.read32(b, 8))
    }
    func successor() -> Self { .init(high: high &+ (low == .max ? 1 : 0), low: low &+ 1) }
    func midpoint(to end: Self) -> Self {
        let (difference, borrow) = end.low.subtractingReportingOverflow(low)
        let highDifference = end.high &- high &- (borrow ? 1 : 0)
        let halfLow = difference >> 1 | UInt64(highDifference & 1) << 63
        let (sum, carry) = low.addingReportingOverflow(halfLow)
        return .init(high: high &+ (highDifference >> 1) &+ (carry ? 1 : 0), low: sum)
    }
}

public struct DiscoveredMotor: Sendable, Equatable {
    public let serialNumber: String
    public let oldID: Int
    public let id: Int
}

extension MaintenanceController {
    /// Search_ID: broadcast Stop, broadcast reset, 80 ms, read config ID, raw bytes (no CRC).
    func scanIDs() async throws -> MaintenanceResult {
        for attempt in 0..<3 {
            do { return try await scanOnce() }
            catch MotorError.serial where attempt < 2 {
                progress(.init(0, "串口异常，准备重新连接并扫描"))
                try await sleep(.milliseconds(500))
                try await transport.recoverLink()
            }
        }
        throw MotorError.serial("扫描重试失败")
    }
    private func scanOnce() async throws -> MaintenanceResult {
        try await reset(15)
        let request = try BootRequest(id: 15, command: 0, address: 4).encode()
        var raw: [UInt8] = []
        for attempt in 0..<2 {
            if attempt > 0 { try await sleep(.milliseconds(80)) }
            raw = try await transport.collectIDs(request, timeout: .seconds(1))
            guard raw.count <= 31, raw.allSatisfy({ $0 < 15 }) else {
                throw MotorError.invalid("扫描收到无效 ID 字节，不能将干扰解释为设备")
            }
            if !raw.isEmpty { break }
        }
        let ids = Set(raw.map(Int.init)).sorted()
        var result = MaintenanceResult("发现 \(ids.count) 个 ID；设备已复位，可执行引导切换恢复应用。重复 ID 请使用总线修复。")
        result.discoveredIDs = ids
        return result
    }

    /// Reset_ID mode 1 preserves one device per original ID; mode 2 assigns 0...N-1.
    func repairIDs(_ scope: Int, sequential: Bool = false) async throws -> MaintenanceResult {
        try await reset(scope)
        let hold = try BootRequest(id: scope, command: 1, address: 15, payload: [1, 0, 0, 0, 0, 0, 0, 0])
        for _ in 0..<10 {
            _ = try await transport.transact(hold.encode(), responseLength: 0, timeout: .milliseconds(100))
            try await sleep(.milliseconds(10))
        }
        var ranges: [(SerialNumber96, SerialNumber96)] = [(.zero, .maximum)]
        var found: [SerialNumber96: Int] = [:]
        var queries = 0
        while let (lower, upper) = ranges.popLast() {
            try Task.checkCancellation(); queries += 1
            guard queries <= 3000 else { throw MotorError.invalid("序列号搜索超过上限，请检查总线噪声") }
            let request = try BootRequest(id: scope, lengthCode: 9, command: 7, payload: lower.wire + upper.wire + Array(repeating: 0, count: 8))
            progress(.init(min(0.5, Double(queries) / 3000), "序列号搜索 · 已找到 \(found.count) 台"))
            do {
                let b = try await transport.transact(request.encode(), responseLength: 50, timeout: .milliseconds(100))
                let payload: [UInt8]
                do { payload = try request.decode(b) } catch { throw MotorError.collision }
                let sn = SerialNumber96(wire: Array(payload.prefix(12)))
                let oldID = Int(ServoProtocol.read32(payload, 28))
                guard sn >= lower, sn <= upper, (0...14).contains(oldID), scope == 15 || oldID == scope else {
                    throw MotorError.invalid("序列号范围或电机 ID 回读不一致")
                }
                guard found[sn] == nil, found.count < 15 else { throw MotorError.invalid("序列号重复或电机数量超过 15，未改写 ID") }
                found[sn] = oldID
            } catch MotorError.timeout { continue }
            catch MotorError.collision {
                guard lower != upper else { throw MotorError.invalid("同一序列号仍有通信冲突，请检查总线") }
                let middle = lower.midpoint(to: upper)
                ranges.append((middle.successor(), upper)); ranges.append((lower, middle))
            }
        }
        guard !found.isEmpty else { throw MotorError.invalid("未发现电机") }
        let ordered = found.keys.sorted { found[$0]! == found[$1]! ? $0 < $1 : found[$0]! < found[$1]! }
        var free = (0...14).filter { !Set(found.values).contains($0) }
        var used = Set<Int>()
        var assignments: [(SerialNumber96, Int, Int)] = []
        for (index, sn) in ordered.enumerated() {
            let oldID = found[sn]!
            let newID: Int
            if sequential { newID = index }
            else if used.insert(oldID).inserted { newID = oldID }
            else {
                guard !free.isEmpty else { throw MotorError.invalid("没有足够空闲 ID，未执行改写") }
                newID = free.removeFirst()
            }
            assignments.append((sn, oldID, newID))
        }
        // All assignments precede saving; unique SN addressing remains valid even during ID swaps.
        for (index, item) in assignments.enumerated() {
            let (sn, _, newID) = item
            var action: [UInt8] = []
            ServoProtocol.append(UInt32(1), to: &action); ServoProtocol.append(UInt32(newID), to: &action)
            let payload = sn.wire + sn.wire + action
            let request = try BootRequest(id: scope, lengthCode: 9, command: 7, payload: payload)
            let reply = try request.decode(await transport.transact(request.encode(), responseLength: 50, timeout: .milliseconds(100)))
            guard reply == payload else { throw MotorError.invalid("序列号分配回读不一致，停止后续改写") }
            progress(.init(0.55 + 0.15 * Double(index + 1) / Double(assignments.count), "已按序列号分配 ID \(newID)"))
        }
        for (_, _, newID) in assignments {
            try await reset(newID); try await unlock(newID)
            let echo = try await boot(newID, command: 1, address: 4, payload: [UInt8(newID)] + Array(repeating: 0, count: 7))
            guard echo[0] == newID else { throw MotorError.invalid("ID 写入回读不一致") }
            try await save(newID)
            let read = try await boot(newID, command: 0, address: 4)
            guard read[0] == newID else { throw MotorError.invalid("ID 保存回读不一致") }
        }
        for (index, item) in assignments.enumerated() {
            let newID = item.2
            progress(.init(0.8 + 0.19 * Double(index) / Double(assignments.count), "保存完成，切换 ID \(newID) 引导"))
            try await reset(newID)
            let reply = try await boot(newID, command: 5, timeout: .seconds(1))
            guard Array(reply.prefix(6)) == Array("OK ATB".utf8) else { throw MotorError.invalid("ID \(newID) 引导切换未确认") }
        }
        var result = MaintenanceResult("已按序列号分配、保存并引导切换 \(assignments.count) 台电机")
        result.discoveredIDs = assignments.map { $0.2 }.sorted()
        result.devices = assignments.map { DiscoveredMotor(serialNumber: $0.0.wire.hex, oldID: $0.1, id: $0.2) }
        return result
    }
}
