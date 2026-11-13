import Foundation

public enum ServoProtocol {
    public static let ratio = 70070.0 / 243.0
    public static let baud = 6_000_000
    public static let feedbackLength = 26

    /// STM32 CRC: little-endian words, MSB-first polynomial, no final XOR.
    /// Matches CRC32_MPEG2 in the distributed UnitreeMotorSDK.dll.
    public static func crc(_ bytes: [UInt8]) throws -> UInt32 {
        guard bytes.count.isMultiple(of: 4) else { throw MotorError.invalid("CRC 数据必须按 4 字节对齐") }
        var crc: UInt32 = 0xffff_ffff
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            crc ^= read32(bytes, offset)
            for _ in 0..<32 {
                crc = (crc &<< 1) ^ (crc & 0x8000_0000 != 0 ? 0x04c1_1db7 : 0)
            }
        }
        return crc
    }

    static func read16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    static func read32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    static func append<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, to: T.bitWidth, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}

public enum MotorError: Error, LocalizedError, Sendable {
    case invalid(String), serial(String), timeout, cancelled, collision
    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .serial(let message): return message
        case .timeout: return "未收到有效反馈，请检查电源、ID、波特率和接线"
        case .cancelled: return "操作已停止"
        case .collision: return "收到冲突或损坏的应答"
        }
    }
}

public enum MotorMode: Int, Codable, Sendable {
    case stop = 0, foc = 1
}

public enum ControlSide: String, CaseIterable, Sendable {
    case output = "输出端", rotor = "转子端"
    public func position(_ output: Double) -> Double { self == .rotor ? output * ServoProtocol.ratio : output }
    public func torque(_ output: Double) -> Double { self == .rotor ? output / ServoProtocol.ratio : output }
}

public struct MotorCommand: Sendable, Equatable {
    public var id: Int
    public var mode: MotorMode
    public var torque: Double
    public var speed: Double
    public var position: Double
    public var kp: Double
    public var kd: Double
    public var timeoutProtection: Bool
    public var side: ControlSide

    public init(id: Int = 0, mode: MotorMode = .stop, torque: Double = 0,
                speed: Double = 0, position: Double = 0, kp: Double = 0,
                kd: Double = 0, timeoutProtection: Bool = true, side: ControlSide = .output) {
        self.id = id; self.mode = mode; self.torque = torque; self.speed = speed
        self.position = position; self.kp = kp; self.kd = kd
        self.timeoutProtection = timeoutProtection; self.side = side
    }

    public func converted(to target: ControlSide) -> Self {
        guard side != target else { return self }
        let r = target == .rotor ? ServoProtocol.ratio : 1 / ServoProtocol.ratio
        var result = self
        result.position *= r; result.speed *= r; result.torque /= r
        result.kp /= r * r; result.kd /= r * r; result.side = target
        return result
    }

    public func encode() throws -> [UInt8] {
        guard (0...15).contains(id) else { throw MotorError.invalid("ID 必须为 0–15；15 为广播") }
        let r = side == .output ? ServoProtocol.ratio : 1.0
        let output = converted(to: .output)
        let values = [output.torque, output.speed, output.position, output.kp, output.kd]
        let limits: [(Double, Double)] = [(-36.9093, 36.908174), (-278.90143, 278.90143),
            (-1428.018898, 1428.018898), (0, 2128.523254), (0, 21.285233)]
        for (value, limit) in zip(values, limits) {
            guard value.isFinite && value >= limit.0 && value <= limit.1 else {
                throw MotorError.invalid("控制参数超出协议范围或不是有限数字")
            }
        }
        guard mode != .stop || values.allSatisfy({ $0 == 0 }) else {
            throw MotorError.invalid("停止模式的控制参数必须为零")
        }
        // Truncate toward zero, verified against the packaged SDK; do not round.
        let raw = [torque * 256000 / r, speed * (2.56 / (2 * .pi)) * r,
                   position * (32768 / (2 * .pi)) * r,
                   kp * 1280000 / r / r, kd * 128000000 / r / r]
        var bytes: [UInt8] = [0xfe, 0xee, UInt8(id | mode.rawValue << 4 | (timeoutProtection ? 128 : 0)), 0]
        for (index, value) in raw.enumerated() {
            if index == 2 { ServoProtocol.append(Int32(clamping: Int64(value)), to: &bytes) }
            else { ServoProtocol.append(Int16(clamping: Int64(value)), to: &bytes) }
        }
        ServoProtocol.append(try ServoProtocol.crc(bytes), to: &bytes)
        return bytes
    }
}

public struct MotorFeedback: Sendable, Equatable {
    public let id: Int
    public let mode: Int
    public let timedOut: Bool
    public let temperature: Int
    public let windingTemperature: Int
    public let voltage: Double
    public let torque: Double
    public let speed: Double
    public let position: Double
    public let error: UInt32
    public let warning: Int
    public let encoderPosition: Double
    public let raw: [UInt8]

    public static func decode(_ b: [UInt8]) throws -> MotorFeedback {
        guard b.count == 26, b[0] == 0xfc, b[1] == 0xee else { throw MotorError.invalid("反馈帧格式错误") }
        guard ServoProtocol.read32(b, 22) == (try ServoProtocol.crc(Array(b[2..<22]))) else {
            throw MotorError.invalid("反馈 CRC 校验失败")
        }
        let ratio = ServoProtocol.ratio
        let flags = ServoProtocol.read16(b, 18)
        return MotorFeedback(id: Int(b[2] & 15), mode: Int(b[2] >> 4 & 7), timedOut: b[2] & 128 != 0,
            temperature: Int(Int8(bitPattern: b[3])), windingTemperature: Int(b[4]), voltage: Double(b[5]) / 2,
            torque: Double(Int16(bitPattern: ServoProtocol.read16(b, 6))) / 256000 * ratio,
            speed: Double(Int16(bitPattern: ServoProtocol.read16(b, 8))) / 2.56 * 2 * .pi / ratio,
            position: Double(Int32(bitPattern: ServoProtocol.read32(b, 10))) * 2 * .pi / 32768 / ratio,
            error: ServoProtocol.read32(b, 14), warning: Int(flags >> 13),
            encoderPosition: Double(flags & 8191) * 2 * .pi / 8192, raw: b)
    }
}

public struct FrameParser: Sendable {
    public private(set) var buffer: [UInt8] = []
    public private(set) var badCRC = 0
    public private(set) var discardedBytes = 0
    public init() {}
    public mutating func clearPartialFrame() { buffer.removeAll(keepingCapacity: true) }
    public mutating func feed(_ bytes: [UInt8]) -> [MotorFeedback] {
        buffer += bytes
        var result: [MotorFeedback] = []
        while buffer.count >= 2 {
            if buffer[0] != 0xfc || buffer[1] != 0xee {
                buffer.removeFirst(); discardedBytes += 1; continue
            }
            guard buffer.count >= 26 else { break }
            do {
                result.append(try MotorFeedback.decode(Array(buffer.prefix(26))))
                buffer.removeFirst(26)
            } catch { badCRC += 1; discardedBytes += 1; buffer.removeFirst() }
        }
        return result
    }
}

public extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
