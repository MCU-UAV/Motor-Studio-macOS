import Foundation
import XCTest
@testable import MotorCore

/// Applies the device state before dropping an ACK: failure is not rollback.
private final class ChangedDeviceSerial: SerialIO, @unchecked Sendable {
    enum Failure { case idACK, feedbackAfterBaud }
    private let lock = NSLock()
    private var incoming: [UInt8] = []
    private(set) var deviceID = 0
    private(set) var hostBaud = 6_000_000
    let failure: Failure
    init(_ failure: Failure) { self.failure = failure }
    func open(_ path: String, baud: Int) throws -> Int32 { hostBaud = baud; return 42 }
    func close(_ fd: Int32) { }
    func flush(_ fd: Int32) -> Bool { lock.lock(); defer { lock.unlock() }; incoming = []; return true }
    func setBaud(_ fd: Int32, baud: Int) -> Bool { lock.lock(); defer { lock.unlock() }; hostBaud = baud; return true }
    func read(_ fd: Int32, capacity: Int, timeout: Int32) throws -> [UInt8] {
        lock.lock(); defer { lock.unlock() }; let b = incoming; incoming = []; return b
    }
    func write(_ fd: Int32, bytes b: [UInt8], timeout: Int32) -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = Int(b[2] & 15)
        guard id != 15, id == deviceID else { return b.count }
        if failure == .feedbackAfterBaud && hostBaud == 4_000_000 && b[2] >> 4 == 0 { return -1 }
        var reply: [UInt8]
        if b[2] >> 4 == 15 {
            var payload = Array(b[8..<(b.count - 4)])
            if b[5] & 15 == 0 {
                payload = Array(repeating: 0, count: payload.count)
                if b[6] == 14 { payload[0] = 60 }
            }
            if b[5] & 15 == 1 && b[6] == 4 {
                deviceID = Int(payload[0])
                if failure == .idACK { return b.count }
            }
            reply = [0xfc, 0xee, UInt8(id) | 128, b[5], b[6], b[7]] + payload + Array(repeating: 0, count: 8)
        } else {
            reply = [0xfc, 0xee, b[2] & 0x7f, 30, 35, 48] + Array(repeating: 0, count: 16)
            if b[4] == 0 && b[5] == 0xfe {
                reply[3] = 128; reply.replaceSubrange(10..<14, with: [0x26, 2, 0x0a, 3])
            }
        }
        ServoProtocol.append(try! ServoProtocol.crc(Array(reply[2...])), to: &reply)
        incoming = reply; return b.count
    }
}

final class MaintenanceStateTests: XCTestCase {
    func testIDMayAlreadyChangeWhenWriteACKIsLost() async throws {
        let io = ChangedDeviceSerial(.idACK)
        let link = SerialSession(io: io)
        try await link.connect(path: "/dev/cu.test")
        do { _ = try await link.maintain(.changeID(3), id: 0); XCTFail("ACK lost") } catch { }
        XCTAssertEqual(io.deviceID, 3)
        let connected = await link.isConnected; XCTAssertFalse(connected)
    }
    func testHostBaudRemainsDiscoverableAfterFinalFeedbackFails() async throws {
        let io = ChangedDeviceSerial(.feedbackAfterBaud)
        let session = SerialSession(io: io)
        try await session.connect(path: "/dev/cu.test")
        do { _ = try await session.maintain(.changeBaud(4_000_000), id: 0); XCTFail("Feedback fails after switch") } catch { }
        let connected = await session.isConnected, baud = await session.baud
        XCTAssertFalse(connected); XCTAssertEqual(baud, 4_000_000)
        XCTAssertEqual(io.hostBaud, 4_000_000)
    }
}
