import Foundation
import XCTest
@testable import MotorCore

private final class StreamClock: @unchecked Sendable {
    var instant = ContinuousClock.now
}
private final class StreamSerial: SerialIO, @unchecked Sendable {
    var chunks: [[UInt8]] = []
    var packets: [[UInt8]] = []
    var flushes = 0
    var autoReply = true
    var ids: Set<Int> = [0, 3]
    var noiseID: Int?
    var timedOut = false
    func open(_ path: String, baud: Int) throws -> Int32 { 7 }
    func close(_ fd: Int32) { }
    func setBaud(_ fd: Int32, baud: Int) -> Bool { true }
    func flush(_ fd: Int32) -> Bool { flushes += 1; chunks = []; return true }
    func write(_ fd: Int32, bytes: [UInt8], timeout: Int32) -> Int {
        packets.append(bytes)
        let id = Int(bytes[2] & 15)
        if noiseID == id { chunks.append([1, 2, 3]) }
        if autoReply && ids.contains(id) { chunks.append(Self.reply(id, mode: Int(bytes[2] >> 4 & 7), timedOut: timedOut)) }
        return bytes.count
    }
    func read(_ fd: Int32, capacity: Int, timeout: Int32) throws -> [UInt8] {
        chunks.isEmpty ? [] : chunks.removeFirst()
    }
    static func reply(_ id: Int, mode: Int = 0, timedOut: Bool = false) -> [UInt8] {
        var b: [UInt8] = [0xfc, 0xee, UInt8(id | mode << 4 | (timedOut ? 128 : 0)), 30, 40, 48] + Array(repeating: 0, count: 16)
        ServoProtocol.append(try! ServoProtocol.crc(Array(b[2...])), to: &b)
        return b
    }
}
final class StreamingTests: XCTestCase {
    func testPipelinePreservesFragmentsAndMatchesPerIDWithoutFlush() async throws {
        let io = StreamSerial()
        let session = SerialSession(io: io)
        try await session.connect(path: "/dev/cu.fake")
        _ = try await session.prepareForControl(ids: [0, 3])
        try await session.startStream(ids: [0, 3])
        let before = io.flushes; io.autoReply = false
        let a = MotorCommand(id: 0, mode: .foc, torque: 0.1), b = MotorCommand(id: 3, mode: .foc, torque: 0.2)
        try await session.sendStream(a); try await session.sendStream(b)
        XCTAssertEqual(io.flushes, before, "No flush can discard a prior response")
        let response = StreamSerial.reply(3, mode: 1) + StreamSerial.reply(0, mode: 1)
        io.chunks = [Array(response.prefix(9)), Array(response.dropFirst(9))]
        let first = try await session.pollStream(); XCTAssertTrue(first.feedback.isEmpty)
        let next = try await session.pollStream()
        XCTAssertEqual(next.feedback.map(\.command), [b, a]); XCTAssertTrue(next.expiredIDs.isEmpty)
        do { _ = try await session.exchange(MotorCommand()); XCTFail("stream owns link") } catch { }
        do { _ = try await session.maintain(.version, id: 0); XCTFail("stream owns link") } catch { }
        await session.cancelAsync()
        do { try await session.sendStream(a); XCTFail("cancelled") } catch { }
    }
    func testExpiredCRCAndUnsolicitedRepliesNeverConfirmControl() async throws {
        let io = StreamSerial(), clock = StreamClock()
        let session = SerialSession(io: io, now: { clock.instant })
        try await session.connect(path: "/dev/cu.fake")
        try await session.startStream(ids: [0]); io.autoReply = false
        try await session.sendStream(MotorCommand())
        var bad = StreamSerial.reply(0); bad[8] ^= 1
        io.chunks = [bad + StreamSerial.reply(3)]
        let empty = try await session.pollStream(); XCTAssertTrue(empty.feedback.isEmpty)
        clock.instant += .milliseconds(41)
        io.chunks = [StreamSerial.reply(0)]
        let expired = try await session.pollStream()
        XCTAssertEqual(expired.expiredIDs, [0]); XCTAssertTrue(expired.feedback.isEmpty)
        let stats = await session.statistics
        XCTAssertEqual(stats.badCRC, 1); XCTAssertEqual(stats.wrongID, 2); XCTAssertEqual(stats.timeouts, 1)
        do { try await session.sendStream(MotorCommand(mode: .foc)); XCTFail("not prepared") } catch { }
    }
    func testBroadcastRequiresEveryPreparedMotorFreshAndProtected() async throws {
        let io = StreamSerial(), clock = StreamClock()
        let session = SerialSession(io: io, now: { clock.instant })
        try await session.connect(path: "/dev/cu.fake")
        _ = try await session.prepareForControl(ids: [0])
        try await session.startStream(ids: [0, 3])
        do { try await session.broadcast(MotorCommand(id: 15, mode: .foc)); XCTFail("ID 3 not prepared") } catch { }
        await session.cancelAsync()
        _ = try await session.prepareForControl(ids: [0, 3]); try await session.startStream(ids: [0, 3])
        do { try await session.broadcast(MotorCommand(id: 15, mode: .foc, timeoutProtection: false)); XCTFail("protection required") } catch { }
        try await session.broadcast(MotorCommand(id: 15, mode: .foc))
        clock.instant += .milliseconds(501)
        let count = io.packets.count
        do { try await session.broadcast(MotorCommand(id: 15, mode: .foc)); XCTFail("expired") } catch { }
        XCTAssertEqual(io.packets.count, count)
    }
    func testDiscoveryIsStopOnlyAndRejectsNoiseAndEmptyBus() async throws {
        let io = StreamSerial()
        let link = SerialSession(io: io)
        try await link.connect(path: "/dev/cu.fake")
        let ids = try await link.detectOnlineIDs(); XCTAssertEqual(ids, [0, 3])
        XCTAssertEqual(io.packets.map { Int($0[2] & 15) }, Array(0...14))
        XCTAssertTrue(io.packets.allSatisfy { $0[2] & 0xf0 == 0x80 && $0[4..<16].allSatisfy { $0 == 0 } })
        io.ids = []; let empty = try await link.detectOnlineIDs(); XCTAssertTrue(empty.isEmpty)
        io.noiseID = 0
        do { _ = try await link.detectOnlineIDs(); XCTFail("noise must not become absent motor") } catch MotorError.collision { }
    }
    func testFrequencySaturationTruncationAndNonFinite() throws {
        for (input, output) in [(-1e300, 0.0), (0, 0), (0.99, 0), (99.99, 99), (10000, 10000), (1e300, 10000)] {
            XCTAssertEqual(try ControlFrequency.normalized(input), output)
        }
        for invalid in [Double.nan, .infinity, -.infinity] { XCTAssertThrowsError(try ControlFrequency.normalized(invalid)) }
    }
    func testDetectionRetainsFaultStatusAndRevokesPriorPreparation() async throws {
        let io = StreamSerial(), session: SerialSession
        session = SerialSession(io: io)
        try await session.connect(path: "/dev/cu.fake")
        _ = try await session.prepareForControl(ids: [0, 3])
        io.timedOut = true
        let replies = try await session.detectOnlineMotors()
        XCTAssertEqual(replies.map(\.id), [0, 3]); XCTAssertTrue(replies.allSatisfy(\.timedOut))
        let count = io.packets.count
        do { _ = try await session.exchange(MotorCommand(mode: .foc)); XCTFail("detection is not preparation") } catch { }
        XCTAssertEqual(io.packets.count, count)
    }
}
