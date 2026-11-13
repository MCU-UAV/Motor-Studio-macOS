import Foundation
import XCTest
@testable import MotorCore

/// Models the firmware latch: timeout=1 does not clear it; only timeout=0 can.
private final class LatchedSerial: SerialIO, @unchecked Sendable {
    enum Failure { case none, stuck, clearMissing, armMissing, fault, wrongMode, wrongID, badCRC, motionMode }
    private let lock = NSLock()
    private var latch: [Int: Bool] = [:]
    private var incoming: [UInt8] = []
    private var sent: [[UInt8]] = []
    let failure: Failure
    let failureID: Int
    var afterClear: (@Sendable () -> Void)?
    init(_ failure: Failure = .none, id: Int = 0) { self.failure = failure; failureID = id }
    func open(_ path: String, baud: Int) throws -> Int32 { 42 }
    func close(_ fd: Int32) { }
    func flush(_ fd: Int32) -> Bool { lock.lock(); defer { lock.unlock() }; incoming = []; return true }
    func setBaud(_ fd: Int32, baud: Int) -> Bool { true }
    func write(_ fd: Int32, bytes: [UInt8], timeout: Int32) -> Int {
        lock.lock(); defer { lock.unlock() }
        sent.append(bytes)
        let id = Int(bytes[2] & 15), enabled = bytes[2] & 128 != 0
        let fail = id == failureID ? failure : .none
        if !enabled && fail != .stuck { latch[id] = false }
        if !enabled { afterClear?() }
        if id == 15 || (!enabled && fail == .clearMissing) || (enabled && fail == .armMissing) { return bytes.count }
        let replyID = fail == .wrongID ? (id + 1) % 15 : id
        var mode = bytes[2] & 0x70
        if fail == .wrongMode { mode = 0x10 }
        if fail == .motionMode && mode == 0x10 { mode = 0 }
        var frame: [UInt8] = [0xfc, 0xee, UInt8(replyID) | mode | (latch[id, default: true] ? 128 : 0), 30, 35, 48]
        frame += Array(repeating: 0, count: 16)
        if fail == .fault { frame[14] = 4 }
        ServoProtocol.append(try! ServoProtocol.crc(Array(frame[2...])), to: &frame)
        if fail == .badCRC { frame[22] ^= 1 }
        incoming = frame
        return bytes.count
    }
    func read(_ fd: Int32, capacity: Int, timeout: Int32) throws -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        let result = Array(incoming.prefix(capacity)); incoming.removeFirst(result.count); return result
    }
    func packets() -> [[UInt8]] { lock.lock(); defer { lock.unlock() }; return sent }
    func relatch() { lock.lock(); defer { lock.unlock() }; latch = [:] }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ duration: Duration) { lock.lock(); defer { lock.unlock() }; time += duration }
}

final class StartupTests: XCTestCase {
    func testProtectedStopAloneCannotClearFirmwareLatch() async throws {
        let io = LatchedSerial()
        let link = SerialSession(io: io)
        try await link.connect(path: "/dev/cu.test")
        let initial = try await link.exchange(MotorCommand())
        XCTAssertTrue(initial.timedOut)
        let ready = try await link.prepareForControl(ids: [0])
        XCTAssertEqual(ready.count, 1); XCTAssertFalse(ready[0].timedOut); XCTAssertEqual(ready[0].mode, 0)
        let packets = io.packets()
        XCTAssertEqual(packets.map { $0[2] }, [0x80, 0x00, 0x80])
        XCTAssertTrue(packets.allSatisfy { Array($0[4..<16]) == Array(repeating: 0, count: 12) })
        // The clear and re-arm frames are the original SDK fixture bytes.
        XCTAssertEqual(packets[1].hex, "FE EE 00 00 00 00 00 00 00 00 00 00 00 00 00 00 80 46 20 79")
        XCTAssertEqual(packets[2].hex, "FE EE 80 00 00 00 00 00 00 00 00 00 00 00 00 00 1D 99 FB 6E")
    }
    func testEveryIDAndEveryRestartMustBePrepared() async throws {
        let io = LatchedSerial()
        let session = SerialSession(io: io)
        try await session.connect(path: "/dev/cu.test")
        _ = try await session.prepareForControl(ids: [3, 0, 3])
        XCTAssertEqual(io.packets().map { $0[2] }, [0, 128, 3, 131])
        io.relatch()
        let again = try await session.prepareForControl(ids: [0, 3])
        XCTAssertTrue(again.allSatisfy { !$0.timedOut })
        XCTAssertEqual(io.packets().count, 8)
    }
    func testFailedClearAlwaysRearmsAndNeverReturnsReady() async throws {
        for failure: LatchedSerial.Failure in [.stuck, .clearMissing, .fault, .wrongMode, .wrongID, .badCRC] {
            let io = LatchedSerial(failure)
            let link = SerialSession(io: io)
            try await link.connect(path: "/dev/cu.test")
            do { _ = try await link.prepareForControl(ids: [0], timeout: .milliseconds(1)); XCTFail("Should not arm: \(failure)") }
            catch { }
            XCTAssertEqual(io.packets().map { $0[2] }, [0, 128], "\(failure)")
            XCTAssertTrue(io.packets().allSatisfy { $0[2] & 0x70 == 0 })
        }
    }
    func testMissingArmACKAndLaterDeviceFailureDoNotAuthorizeMotion() async throws {
        let io = LatchedSerial(.armMissing, id: 3)
        let link = SerialSession(io: io)
        try await link.connect(path: "/dev/cu.test")
        do { _ = try await link.prepareForControl(ids: [0, 3, 4], timeout: .milliseconds(1)); XCTFail("Missing re-arm acknowledgement") } catch { }
        XCTAssertEqual(io.packets().map { $0[2] }, [0, 128, 3, 131])
    }
    func testCancellationAfterClearStillSendsProtectedStop() async throws {
        let io = LatchedSerial()
        io.afterClear = { withUnsafeCurrentTask { $0?.cancel() } }
        let link = SerialSession(io: io)
        try await link.connect(path: "/dev/cu.test")
        let task = Task {
            do { _ = try await link.prepareForControl(ids: [0, 3]); XCTFail("Cancelled") }
            catch is CancellationError { }
            catch { XCTFail("Unexpected \(error)") }
        }
        await task.value
        XCTAssertEqual(io.packets().map { $0[2] }, [0, 128])
    }
    func testStalePreparationCannotSendFOCAfterSuspensionInEitherMode() async throws {
        for asynchronous in [false, true] {
            let io = LatchedSerial(), clock = TestClock()
            let link = SerialSession(io: io, now: { clock.now() })
            try await link.connect(path: "/dev/cu.test")
            _ = try await link.prepareForControl(ids: [0])
            clock.advance(.milliseconds(501))
            do {
                if asynchronous { try await link.beginAsync(MotorCommand(mode: .foc)) }
                else { _ = try await link.exchange(MotorCommand(mode: .foc)) }
                XCTFail("Expired preparation must fail before FOC write")
            } catch { }
            XCTAssertEqual(io.packets().count, 2)
        }
    }
    func testStopAndDisconnectInvalidateStartupConfirmation() async throws {
        let io = LatchedSerial()
        let session = SerialSession(io: io)
        try await session.connect(path: "/dev/cu.test")
        _ = try await session.prepareForControl(ids: [0])
        _ = await session.stop(ids: [0])
        do { _ = try await session.exchange(MotorCommand(mode: .foc)); XCTFail("Stop invalidates") } catch { }
        _ = try await session.prepareForControl(ids: [0])
        await session.disconnect()
        try await session.connect(path: "/dev/cu.test")
        do { try await session.beginAsync(MotorCommand(mode: .foc)); XCTFail("Reconnect invalidates") } catch { }
        XCTAssertTrue(io.packets().allSatisfy { $0[2] & 0x70 == 0 })
    }
    func testUnacknowledgeableOrInvalidTargetsNeverSendClear() async throws {
        let io = LatchedSerial()
        let link = SerialSession(io: io)
        try await link.connect(path: "/dev/cu.test")
        for ids in [[], [15], [-1], [0, 16]] {
            do { _ = try await link.prepareForControl(ids: ids); XCTFail("Invalid ID") } catch { }
        }
        XCTAssertTrue(io.packets().isEmpty)
    }
}
