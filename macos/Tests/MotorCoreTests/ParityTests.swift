import XCTest
@testable import MotorCore

private struct Capture: Decodable {
    let operation: String
    let tx: String
    let rx: String
    var values: [Double]?
    var id: Int?
}
private func decodeHex(_ hex: String) -> [UInt8] {
    stride(from: 0, to: hex.count, by: 2).map {
        let start = hex.index(hex.startIndex, offsetBy: $0)
        return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    }
}
private func captures(_ name: String) throws -> [Capture] {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode([Capture].self, from: Data(contentsOf: url))
}

/// Consumes the SDK trace in order. Missing reset, duplicate write or reordered save fails immediately.
private actor OrderedReplay: MaintenanceTransport {
    var remaining: [Capture]
    var packets: [[UInt8]] = []
    let corruptAssignment: Bool
    init(_ name: String, operation: String? = nil, corruptAssignment: Bool = false) throws {
        remaining = try captures(name).filter { operation == nil || $0.operation == operation }
        self.corruptAssignment = corruptAssignment
    }
    func setBaud(_ baud: Int) async throws { }
    func consume(_ bytes: [UInt8]) throws -> [UInt8] {
        guard let next = remaining.first, decodeHex(next.tx) == bytes else {
            throw MotorError.invalid("Sequence differs from SDK at \(packets.count): \(bytes.hex); expected \(remaining.first?.tx ?? "end")")
        }
        remaining.removeFirst(); return decodeHex(next.rx)
    }
    func transact(_ bytes: [UInt8], responseLength: Int, timeout: Duration) async throws -> [UInt8] {
        packets.append(bytes)
        // Extra native read-after-save, not part of SDK trace.
        if bytes[2] >> 4 == 15, bytes[5] == 0, bytes[6] == 4, bytes[2] & 15 != 15 {
            var reply: [UInt8] = [0xfc, 0xee, bytes[2] & 15 | 128, 0, 4, 0, bytes[2] & 15]
            reply += Array(repeating: 0, count: 15)
            ServoProtocol.append(try ServoProtocol.crc(Array(reply[2...])), to: &reply)
            return reply
        }
        let collision = remaining.first?.operation == "collision"
        var response = try consume(bytes)
        if collision { throw MotorError.collision }
        if corruptAssignment, bytes[5] == 0x97, bytes[32] == 1 {
            response[6] ^= 1
            response.removeLast(4); ServoProtocol.append(try ServoProtocol.crc(Array(response[2...])), to: &response)
        }
        return responseLength == 0 ? [] : response
    }
    func collectIDs(_ bytes: [UInt8], timeout: Duration) async throws -> [UInt8] {
        packets.append(bytes)
        _ = try consume(bytes)
        return try consume([])
    }
}
private actor Delays {
    var values: [Duration] = []
    func append(_ value: Duration) { values.append(value) }
}
private actor RawScan: MaintenanceTransport {
    let responses: [[UInt8]]
    var attempts = 0
    var writes = 0
    init(_ responses: [[UInt8]]) { self.responses = responses }
    func transact(_ bytes: [UInt8], responseLength: Int, timeout: Duration) async throws -> [UInt8] { writes += 1; return [] }
    func collectIDs(_ bytes: [UInt8], timeout: Duration) async throws -> [UInt8] {
        defer { attempts += 1 }; return responses[min(attempts, responses.count - 1)]
    }
    func setBaud(_ baud: Int) async throws { }
}

final class ParityTests: XCTestCase {
    func testSwitchRequiresExactSDKStopResetSwitchOrderAndDelays() async throws {
        let transport = try OrderedReplay("parity-vectors", operation: "switch")
        let delays = Delays()
        let controller = MaintenanceController(transport: transport, clientTag: 0, sleep: { await delays.append($0) })
        _ = try await controller.run(.switchBoot, id: 0)
        let remaining = await transport.remaining, waits = await delays.values
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(waits, [.milliseconds(1), .milliseconds(80)])
    }
    func testRawScanMatchesSDKSequenceAndHasNoConfigurationWrites() async throws {
        let t = try OrderedReplay("parity-vectors", operation: "scan")
        let result = try await MaintenanceController(transport: t, clientTag: 0, sleep: { _ in }).run(.scanIDs, id: 0)
        XCTAssertEqual(result.discoveredIDs, [0, 3, 14])
        let remaining = await t.remaining
        XCTAssertTrue(remaining.isEmpty)
    }
    func testEmptyScanRetriesAndInvalidBytesNeverBecomeIDs() async throws {
        let t = RawScan([[], [3, 3, 0]])
        let result = try await MaintenanceController(transport: t, clientTag: 0, sleep: { _ in }).run(.scanIDs, id: 0)
        XCTAssertEqual(result.discoveredIDs, [0, 3])
        let attempts = await t.attempts; XCTAssertEqual(attempts, 2)
        for response: [UInt8] in [[15], [0xfc, 0xee], Array(repeating: 1, count: 32)] {
            let bad = RawScan([response])
            do { _ = try await MaintenanceController(transport: bad, clientTag: 0, sleep: { _ in }).run(.scanIDs, id: 0); XCTFail("Invalid scan") }
            catch { }
            let attempts = await bad.attempts; XCTAssertEqual(attempts, 1)
        }
    }
    func testWholeBusRepairMatchesSDKSequenceAndPreservesUniqueIDs() async throws {
        let t = try OrderedReplay("bus-vectors")
        let controller = MaintenanceController(transport: t, clientTag: 0x123456f9, timestamp: { 1_700_000_000 }, sleep: { _ in })
        let result = try await controller.run(.repairDuplicateIDs, id: 7)
        XCTAssertEqual(result.discoveredIDs, [0, 1, 3])
        XCTAssertEqual(result.devices?.map(\.oldID), [0, 3, 3])
        XCTAssertEqual(result.devices?.map(\.id), [0, 3, 1])
        let remaining = await t.remaining
        XCTAssertTrue(remaining.isEmpty)
    }
    func testSequentialReorderMatchesSDKIncludingSaveBeforeStart() async throws {
        let t = try OrderedReplay("reorder-vectors")
        let controller = MaintenanceController(transport: t, clientTag: 0x123456f9, timestamp: { 1_700_000_000 }, sleep: { _ in })
        let result = try await controller.run(.reorderIDs, id: 0)
        XCTAssertEqual(result.devices?.map(\.oldID), [0, 3, 3])
        XCTAssertEqual(result.devices?.map(\.id), [0, 1, 2])
        let remaining = await t.remaining
        XCTAssertTrue(remaining.isEmpty)
    }
    func testCorruptSNEchoStopsBeforeSaveOrFurtherAssignments() async throws {
        let t = try OrderedReplay("bus-vectors", corruptAssignment: true)
        do {
            _ = try await MaintenanceController(transport: t, clientTag: 0x123456f9, sleep: { _ in }).run(.repairDuplicateIDs, id: 0)
            XCTFail("Wrong SN echo")
        } catch { }
        let packets = await t.packets
        XCTAssertEqual(packets.filter { $0[5] == 0x97 && $0[32] == 1 }.count, 1)
        XCTAssertFalse(packets.contains { $0[5] == 2 })
    }
    func testOutputRotorAndBroadcastEncodingMatchSDK() throws {
        for capture in try captures("parity-vectors") where capture.values != nil {
            let v = capture.values!
            let command = MotorCommand(id: capture.id!, mode: .foc, torque: v[0], speed: v[1], position: v[2], kp: v[3], kd: v[4], side: capture.operation.hasSuffix("Rotor") ? .rotor : .output)
            XCTAssertEqual(try command.encode(), decodeHex(capture.tx))
        }
        let original = MotorCommand(mode: .foc, torque: 0.1, speed: 1, position: 0.3, kp: 5, kd: 0.2)
        let converted = original.converted(to: .rotor).converted(to: .output)
        XCTAssertEqual(converted.torque, original.torque, accuracy: 1e-12)
        XCTAssertEqual(converted.kp, original.kp, accuracy: 1e-12)
        XCTAssertEqual(converted.position, original.position, accuracy: 1e-12)
        XCTAssertEqual(try MotorCommand(id: 15, timeoutProtection: false).encode()[2], 15)
    }
    func testHourRetentionDoesNotDropAtThirtyThousandFramesAndExpiresByTime() {
        var series = TimeSeries<Int>(retention: 3600)
        let start = Date(timeIntervalSince1970: 0)
        for i in 0...360_000 { series.append(i, at: start.addingTimeInterval(Double(i) / 100)) }
        XCTAssertEqual(series.count, 360_001)
        series.append(360_001, at: start.addingTimeInterval(3600.01))
        XCTAssertEqual(series.count, 360_001)
        XCTAssertEqual(series.values(from: start.addingTimeInterval(3599.99), through: start.addingTimeInterval(3600.01), matching: { _ in true }), [359999, 360000, 360001])
        series.retention = 30; series.expire(at: start.addingTimeInterval(3601))
        XCTAssertLessThanOrEqual(series.count, 3001)
    }
    func testChartEnvelopeKeepsShortSpikesEndpointsAndOrder() {
        var values = Array(repeating: 0.0, count: 10_000)
        values[567] = 100; values[8750] = -99
        let indices = envelopeIndices(count: values.count, budget: 600) { values[$0] }
        XCTAssertTrue(indices.contains(567)); XCTAssertTrue(indices.contains(8750))
        XCTAssertEqual(indices.first, 0); XCTAssertEqual(indices.last, 9999)
        XCTAssertEqual(indices, indices.sorted()); XCTAssertLessThanOrEqual(indices.count, 600)
    }
}
