import Foundation
import CSerial

/// Narrow driver boundary: lets protocol tests exercise real session state without opening a port.
protocol SerialIO: Sendable {
    func open(_ path: String, baud: Int) throws -> Int32
    func close(_ fd: Int32)
    func flush(_ fd: Int32) -> Bool
    func write(_ fd: Int32, bytes: [UInt8], timeout: Int32) -> Int
    func read(_ fd: Int32, capacity: Int, timeout: Int32) throws -> [UInt8]
    func setBaud(_ fd: Int32, baud: Int) -> Bool
}
struct NativeSerialIO: SerialIO {
    func open(_ path: String, baud: Int) throws -> Int32 {
        var message = [CChar](repeating: 0, count: 512)
        let fd = motor_serial_open(path, Int32(baud), &message, message.count)
        guard fd >= 0 else { throw MotorError.serial("无法打开串口：" + String(cString: message)) }
        return fd
    }
    func close(_ fd: Int32) { motor_serial_close(fd) }
    func flush(_ fd: Int32) -> Bool { motor_serial_flush_input(fd) == 0 }
    func write(_ fd: Int32, bytes: [UInt8], timeout: Int32) -> Int {
        Int(bytes.withUnsafeBufferPointer { motor_serial_write(fd, $0.baseAddress, $0.count, timeout) })
    }
    func read(_ fd: Int32, capacity: Int, timeout: Int32) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: capacity)
        let count = motor_serial_read(fd, &bytes, bytes.count, timeout)
        guard count >= 0 else { throw MotorError.serial("串口读取失败，设备可能已拔出") }
        return Array(bytes.prefix(Int(count)))
    }
    func setBaud(_ fd: Int32, baud: Int) -> Bool { motor_serial_set_baud(fd, Int32(baud)) == 0 }
}
