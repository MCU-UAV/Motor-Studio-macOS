import Foundation
import XCTest
@testable import MotorCore

private final class SimulatedSerial: SerialIO, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [[UInt8]] = []
    private var sent: [[UInt8]] = []
    var respond = true // Configured before starting the session.
    var rejectBroadcast = false
    var rejectMaintenance = false
    func open(_ path: String, baud: Int) throws -> Int32 { 42 }
    func close(_ fd: Int32) { }
    func flush(_ fd: Int32) -> Bool { lock.lock(); defer { lock.unlock() }; chunks = []; return true }
    func setBaud(_ fd: Int32, baud: Int) -> Bool { true }
    func write(_ fd: Int32, bytes: [UInt8], timeout: Int32) -> Int {
        lock.lock(); defer { lock.unlock() }
        sent.append(bytes)
        if rejectBroadcast && bytes[2] & 15 == 15 { return -1 }
        if rejectMaintenance && bytes[2] & 0x70 != 0 { return -1 }
        guard respond, bytes[2] & 15 != 15 else { return bytes.count }
        var frame: [UInt8] = [0xfc, 0xee, bytes[2] & 0x7f, 30, 35, 48] + Array(repeating: 0, count: 16)
        ServoProtocol.append(try! ServoProtocol.crc(Array(frame[2...])), to: &frame)
        chunks = [[], Array(frame.prefix(10)), Array(frame.dropFirst(10))]
        return bytes.count
    }
    func read(_ fd: Int32, capacity: Int, timeout: Int32) throws -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        return chunks.isEmpty ? [] : chunks.removeFirst()
    }
    func packets() -> [[UInt8]] { lock.lock(); defer { lock.unlock() }; return sent }
}
private actor RecoveringScan: MaintenanceTransport {
    var recovered = 0
    var requests = 0
    func transact(_ bytes: [UInt8], responseLength: Int, timeout: Duration) async throws -> [UInt8] { [] }
    func setBaud(_ baud: Int) async throws { }
    func recoverLink() async throws { recovered += 1 }
    func collectIDs(_ request: [UInt8], timeout: Duration) async throws -> [UInt8] {
        requests += 1
        if requests == 1 { throw MotorError.serial("unplug") }
        return [2]
    }
}
final class SessionTests: XCTestCase {
    func testTemporaryBootOwnsSerialUntilCancelledAndReleasesLease() async throws {
        let io = SimulatedSerial()
        let session = SerialSession(io: io)
        try await session.connect(path: "/dev/cu.test")
        let task = Task { try await session.maintain(.temporaryBoot, id: 0) }
        defer { task.cancel() }
        for _ in 0..<100 {
            if io.packets().filter({ $0[2] == 255 }).count > 10 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(io.packets().filter { $0[2] == 255 }.count, 10)
        do { _ = try await session.exchange(MotorCommand()); XCTFail("Lease must exclude control") } catch { }
        do { _ = try await session.maintain(.version, id: 0); XCTFail("Lease must exclude maintenance") } catch { }
        task.cancel()
        let result = try await task.value
        XCTAssertTrue(result.message.contains("退出"))
        let count = io.packets().count
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(io.packets().count, count)
        let connected = await session.isConnected
        XCTAssertTrue(connected)
        _ = try await session.exchange(MotorCommand())
    }
    func testAsyncPartialReceiveExclusionAndStopBroadcastThenVerification() async throws {
        let io = SimulatedSerial()
        let link = SerialSession(io: io)
        try await link.connect(path: "/dev/cu.test")
        _ = try await link.prepareForControl(ids: [3])
        try await link.beginAsync(MotorCommand(id: 3, mode: .foc))
        do { try await link.beginAsync(MotorCommand(id: 4)); XCTFail("Cannot overlap requests") } catch { }
        let empty = try await link.receiveAsync(), partial = try await link.receiveAsync()
        XCTAssertNil(empty); XCTAssertNil(partial)
        let feedback = try await link.receiveAsync(); XCTAssertEqual(feedback?.id, 3)
        try await link.beginAsync(MotorCommand(id: 3))
        let stopped = await link.stop(ids: [3]); XCTAssertTrue(stopped)
        let packets = io.packets()
        XCTAssertEqual(packets[packets.count - 2][2] & 15, 15)
        XCTAssertEqual(packets.last![2] & 15, 3)
        XCTAssertEqual(packets.last![2] >> 4 & 7, 0)
        await link.disconnect()
    }
    func testBroadcastDoesNotWaitForFeedbackAndCannotUseExchange() async throws {
        let io = SimulatedSerial()
        let session = SerialSession(io: io)
        try await session.connect(path: "/dev/cu.test")
        try await session.broadcast(MotorCommand(id: 15))
        let stats = await session.statistics
        XCTAssertEqual(stats.sent, 1); XCTAssertEqual(stats.received, 0); XCTAssertEqual(stats.timeouts, 0)
        do { _ = try await session.exchange(MotorCommand(id: 15)); XCTFail("Broadcast cannot receive") } catch { }
        let stopped = await session.stop(ids: []); XCTAssertFalse(stopped, "Unknown motors cannot be acknowledged")
        XCTAssertEqual(io.packets().count, 2)
    }
    func testAsyncTimeoutReleasesPendingRequestAndCancellationAllowsMaintenance() async throws {
        let io = SimulatedSerial(); io.respond = false
        let session = SerialSession(io: io)
        try await session.connect(path: "/dev/cu.test")
        try await session.beginAsync(MotorCommand(id: 1), timeout: .zero)
        do { _ = try await session.receiveAsync(); XCTFail("Must time out") } catch MotorError.timeout { }
        try await session.beginAsync(MotorCommand(id: 2))
        await session.cancelAsync()
        try await session.broadcast(MotorCommand(id: 15))
        let stats = await session.statistics; XCTAssertEqual(stats.timeouts, 1)
    }
    func testSearchSafeRecoversSerialErrorBeforeRetryingBroadcastScan() async throws {
        let t = RecoveringScan()
        let result = try await MaintenanceController(transport: t, clientTag: 0, sleep: { _ in }).run(.scanIDs, id: 0)
        XCTAssertEqual(result.discoveredIDs, [2])
        let recovered = await t.recovered, requests = await t.requests
        XCTAssertEqual(recovered, 1); XCTAssertEqual(requests, 2)
    }
    func testBroadcastFailureStillAttemptsEveryUnicastStop() async throws {
        let io = SimulatedSerial(); io.rejectBroadcast = true
        let session = SerialSession(io: io)
        try await session.connect(path: "/dev/cu.test")
        let stopped = await session.stop(ids: [0, 3])
        XCTAssertFalse(stopped)
        XCTAssertEqual(io.packets().map { $0[2] & 15 }, [15, 0, 3])
    }
    func testInterruptedStateChangeClosesConnectionButReadOnlyFailureDoesNot() async throws {
        for operation: MaintenanceOperation in [.restart, .changeBaud(4_000_000), .version] {
            let io = SimulatedSerial(); io.rejectMaintenance = true
            let session = SerialSession(io: io)
            try await session.connect(path: "/dev/cu.test")
            do { _ = try await session.maintain(operation, id: 0); XCTFail("Must fail") } catch { }
            let connected = await session.isConnected
            if case .version = operation { XCTAssertTrue(connected) } else { XCTAssertFalse(connected) }
        }
    }
}
