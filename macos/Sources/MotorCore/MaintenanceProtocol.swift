import Foundation

/// Private J288/S288 protocol, recovered from the distributed UnitreeMotorSDK.dll.
public enum MaintenanceProtocol {
    public static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var value: UInt16 = 0
        for byte in bytes {
            value ^= UInt16(byte)
            for _ in 0..<8 { value = (value >> 1) ^ (value & 1 != 0 ? 0x8408 : 0) }
        }
        return value
    }

    public static func command(id: Int, mode: Int = 6, argument: Int16 = 0,
                               speed: Int16 = 0, position: UInt32 = 0, extra: UInt32 = 0) throws -> [UInt8] {
        guard (0...15).contains(id), [0, 6, 7].contains(mode) else { throw MotorError.invalid("配置指令无效") }
        var b: [UInt8] = [0xfe, 0xee, UInt8(id | mode << 4), 0]
        ServoProtocol.append(argument, to: &b); ServoProtocol.append(speed, to: &b)
        ServoProtocol.append(position, to: &b); ServoProtocol.append(extra, to: &b)
        ServoProtocol.append(try ServoProtocol.crc(b), to: &b)
        return b
    }

    public static func savePayload(clientTag: UInt32, timestamp: UInt32) -> [UInt8] {
        var b: [UInt8] = []
        ServoProtocol.append(clientTag, to: &b); ServoProtocol.append(timestamp, to: &b)
        return b
    }
}

public struct BootRequest: Sendable, Equatable {
    public let id: Int
    public let lengthCode: Int
    public let command: Int
    public let address: Int
    public let sector: Int
    public let payload: [UInt8]
    public var responseLength: Int { payload.count + 18 }

    public init(id: Int, lengthCode: Int = 0, command: Int, address: Int = 0,
                sector: Int = 0, payload: [UInt8]? = nil) throws {
        guard (0...15).contains(id), (id != 15 || command == 7 || (command == 0 && address == 4) || (command == 1 && address == 15)), (0...12).contains(lengthCode), [0, 1, 2, 3, 4, 5, 7].contains(command),
              (0...0x3fff).contains(address), (0...3).contains(sector) else {
            throw MotorError.invalid("Bootloader 参数超出范围")
        }
        let count = lengthCode <= 7 ? 8 : 1 << (lengthCode - 4)
        let bytes = payload ?? [UInt8](repeating: 0xaa, count: count)
        guard bytes.count == count else { throw MotorError.invalid("Bootloader 数据长度不匹配") }
        self.id = id; self.lengthCode = lengthCode; self.command = command
        self.address = address; self.sector = sector; self.payload = bytes
    }

    public func encode() throws -> [UInt8] {
        var b: [UInt8] = [0xfe, 0xee, UInt8(0xf0 | id), 0]
        let control = UInt32(0xf0 | id) | UInt32(command) << 8 | UInt32(lengthCode) << 12
            | UInt32(address) << 16 | UInt32(sector) << 30
        ServoProtocol.append(control, to: &b); b += payload
        ServoProtocol.append(try ServoProtocol.crc(b), to: &b)
        return b
    }

    public func decode(_ b: [UInt8]) throws -> [UInt8] {
        guard b.count == responseLength, b[0] == 0xfc, b[1] == 0xee else {
            throw MotorError.invalid("Bootloader 应答长度或帧头错误")
        }
        guard ServoProtocol.read32(b, b.count - 4) == (try ServoProtocol.crc(Array(b[2..<(b.count - 4)]))) else {
            throw MotorError.invalid("Bootloader 应答 CRC 错误")
        }
        let location = Int(ServoProtocol.read16(b, 4))
        guard Int(b[2] & 15) == id, Int(b[3] >> 4) == lengthCode,
              Int(b[3] & 15) == command, location & 0x3fff == address, location >> 14 == sector else {
            throw MotorError.invalid("Bootloader 应答的 ID、指令或地址与请求不一致")
        }
        guard b[2] & 128 != 0 else { throw MotorError.invalid("Bootloader 拒绝操作（成功标志未置位）") }
        return Array(b[6..<(6 + payload.count)])
    }
}

public struct FirmwareVersion: Sendable, Equatable, CustomStringConvertible {
    public let raw: UInt32
    public var app: UInt16 { UInt16(truncatingIfNeeded: raw) }
    public var boot: UInt16 { UInt16(truncatingIfNeeded: raw >> 16) }
    public var description: String { String(format: "Boot %02X.%02X · App %02X.%02X", raw >> 24, raw >> 16 & 255, raw >> 8 & 255, raw & 255) }
    public init(raw: UInt32) { self.raw = raw }
    public static func decode(_ b: [UInt8], id: Int) throws -> FirmwareVersion {
        let feedback = try MotorFeedback.decode(b)
        guard feedback.id == id, b[3] == 128 else { throw MotorError.invalid("设备未返回版本应答") }
        return FirmwareVersion(raw: ServoProtocol.read32(b, 10))
    }
    // Keep the SDK's component-wise feature checks, including its minor-version requirements.
    public var supportsCalibration: Bool { raw >> 8 & 255 >= 2 && raw & 255 >= 10 }
    public var supportsBaudChange: Bool { raw >> 24 >= 3 && raw >> 16 & 255 >= 10 && raw >> 8 & 255 >= 2 && raw & 255 >= 21 }
}

public struct Calibration: Sendable {
    public enum Mode: String, CaseIterable, Sendable { case factory = "出厂范围", precise = "高精度", limits = "限位与行程" }
    public var mode: Mode
    public var position: Double
    public var travel: Double
    public var forward: Bool
    public init(mode: Mode, position: Double = 0, travel: Double = 0, forward: Bool = true) {
        self.mode = mode; self.position = position; self.travel = travel; self.forward = forward
    }
    private func quantized() throws -> (Int16, Int16) {
        let a = mode == .limits ? position : 0
        let b = mode == .limits ? travel : 0
        guard a.isFinite, b.isFinite, abs(a) <= 2 * .pi, abs(b) <= 2 * .pi,
              mode != .limits || b != 0 else { throw MotorError.invalid("限位 A 和行程需在 ±2π rad 内，行程不能为零") }
        // SDK uses Float inputs and Float intermediate multiplication before division by Double π.
        func raw(_ x: Double) -> Int16 {
            let f = Float(forward ? x : -x) * 32768 * 0.5
            return Int16(clamping: Int64(Double(f) / .pi))
        }
        let travel = raw(b)
        guard mode != .limits || travel != 0 else {
            throw MotorError.invalid("行程小于协议分辨率，量化后为零，会变成高精度模式；请增大行程")
        }
        return (raw(a), travel)
    }
    public func encode(id: Int, clientTag: UInt32, timestamp: UInt32) throws -> [UInt8] {
        let (p, t) = try quantized()
        return try MaintenanceProtocol.command(id: id, argument: mode == .factory ? -1024 : -1023,
            speed: t, position: UInt32(UInt16(bitPattern: p)) | (clientTag & 0xffff) << 16, extra: timestamp)
    }
    public func validate(_ b: [UInt8], id: Int) throws -> MotorFeedback {
        let feedback = try MotorFeedback.decode(b)
        let (_, t) = try quantized()
        let expected: Int16 = mode == .factory ? -1024 : -1023
        let status = ServoProtocol.read16(b, 8)
        guard feedback.id == id, feedback.mode == 6, Int16(bitPattern: ServoProtocol.read16(b, 6)) == expected,
              feedback.error == 0, status & 3 == (t == 0 ? 0 : 2), mode == .factory || status & 128 != 0 else {
            throw MotorError.invalid("标定未通过设备回读校验")
        }
        if mode == .limits {
            let delta = feedback.position - (forward ? position : -position)
            guard [delta, delta - 2 * .pi, delta + 2 * .pi].contains(where: { abs($0) <= 0.02 * .pi }) else {
                throw MotorError.invalid("标定后位置与限位 A 不一致")
            }
        }
        return feedback
    }
}

public struct FirmwareImage: Sendable {
    public let filename: String
    public let version: UInt16
    public let originalSize: Int
    public let bytes: [UInt8]
    public var crc: UInt16 { MaintenanceProtocol.crc16(bytes) }
    public init(filename: String, data: Data) throws {
        guard filename.hasSuffix(".bin") else { throw MotorError.invalid("请选择原厂 .bin 固件") }
        let parts = String(filename.dropLast(4)).split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        guard (parts.count == 4 || parts.count == 5), parts[0] == "N1215-288", parts[1] == "APP",
              parts[2].count == 4, parts[3].count == 4,
              let version = UInt16(parts[2], radix: 16), let checksum = UInt16(parts[3], radix: 16) else {
            throw MotorError.invalid("固件名称应为 N1215-288_APP_版本_校验码[_备注].bin")
        }
        let stem = parts.prefix(3).joined(separator: "_")
        guard MaintenanceProtocol.crc16(Array(stem.utf8)) == checksum else { throw MotorError.invalid("固件文件名校验失败，请保留原厂文件名") }
        guard (8...131072).contains(data.count) else { throw MotorError.invalid("固件大小必须为 8 字节至 128 KiB") }
        var bytes = Array(data)
        bytes += [UInt8](repeating: 0xff, count: (8 - bytes.count % 8) % 8)
        self.filename = filename; self.version = version; self.originalSize = data.count; self.bytes = bytes
    }
}
