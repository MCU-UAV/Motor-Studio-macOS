import XCTest
@testable import MotorCore

private struct Vector: Decodable, Sendable { let operation: String; let tx: String; let rx: String; let timeout: Int }
private func bytes(_ text: String) -> [UInt8] {
    stride(from: 0, to: text.count, by: 2).map { i in
        let start = text.index(text.startIndex, offsetBy: i)
        return UInt8(text[start..<text.index(start, offsetBy: 2)], radix: 16)!
    }
}
private func fixtures() throws -> [Vector] {
    let url = Bundle.module.url(forResource: "private-vectors", withExtension: "json", subdirectory: "Fixtures")!
    return try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
}
private func appendCRC(_ data: [UInt8]) throws -> [UInt8] {
    var b = data; ServoProtocol.append(try ServoProtocol.crc(Array(b[2...])), to: &b); return b
}
private func feedback(_ id: Int) throws -> [UInt8] { try appendCRC([0xfc, 0xee, UInt8(id), 30, 35, 48] + Array(repeating: 0, count: 16)) }
private func bootReply(_ tx: [UInt8], payload: [UInt8]? = nil, accepted: Bool = true) throws -> [UInt8] {
    var b: [UInt8] = [0xfc, 0xee, (tx[2] & 15) | (accepted ? 128 : 0), tx[5], tx[6], tx[7]]
    b += payload ?? Array(tx[8..<(tx.count - 4)]); b += Array(repeating: 0, count: 8)
    return try appendCRC(b)
}

// Actual SDK TX is the mutation oracle. RX fixtures are explicitly synthetic.
private actor SDKTransport: MaintenanceTransport {
    let vectors: [Vector]
    var packets: [[UInt8]] = []
    var baud = 6_000_000
    var registers: [Int: UInt8] = [4: 0, 5: 1, 14: 60]
    var currentID = 0
    let failure: String
    init(_ failure: String = "") throws { vectors = try fixtures(); self.failure = failure }
    func setBaud(_ baud: Int) async throws { self.baud = baud }
    func transact(_ b: [UInt8], responseLength: Int, timeout: Duration) async throws -> [UInt8] {
        try Task.checkCancellation(); packets.append(b)
        let id = Int(b[2] & 15)
        if b[2] >> 4 != 15 {
            if b[2] >> 4 == 0 && id != 15 {
                if id != currentID && failure != "occupied" { throw MotorError.timeout }
                if failure == "faultStop" {
                    var bad = try feedback(id); bad[14] = 4
                    return try appendCRC(Array(bad.prefix(22)))
                }
                return try feedback(id)
            }
            guard let vector = vectors.first(where: { bytes($0.tx) == b }) else { throw MotorError.invalid("控制帧与 SDK 不同：\(b.hex)") }
            if responseLength == 0 { return [] }
            var response = bytes(vector.rx)
            if failure == "staleClear", b[5] == 0xff { return try feedback(id) }
            if failure == "faultStop", b[2] >> 4 == 0 {
                response[14] = 4; response = try appendCRC(Array(response.prefix(22)))
            }
            if failure == "version", b[4] == 0, b[5] == 0xfe {
                response[10] = 0x25; response = try appendCRC(Array(response.prefix(22)))
            }
            return response
        }
        let command = Int(b[5] & 15), code = Int(b[5] >> 4)
        let location = Int(ServoProtocol.read16(b, 6)), address = location & 0x3fff, sector = location >> 14
        if failure == "timeout", command == 0, address == 32 { throw MotorError.timeout }
        if command == 0, code == 0, sector == 0 {
            if id != currentID { throw MotorError.timeout }
            return try bootReply(b, payload: [registers[address, default: 0]] + Array(repeating: 0, count: 7))
        }
        if command == 0, code == 9, sector == 1 {
            // SDK's read probe payload contains uninitialized stack bytes; use zeroes.
            return try bootReply(b, payload: Array(repeating: 0, count: 32))
        }
        guard let vector = vectors.first(where: { bytes($0.tx) == b }) else { throw MotorError.invalid("维护写入帧与 SDK 不同：\(b.hex)") }
        if command == 1, code == 0, sector == 0 { registers[address] = b[8] }
        if command == 1, address == 4, sector == 0, code == 0 { currentID = Int(b[8]) }
        if failure == "readback", command == 1, sector == 1 {
            var p = Array(b[8..<(b.count - 4)]); p[0] ^= 1; return try bootReply(b, payload: p)
        }
        if failure == "cancel", command == 1, sector == 1 { throw CancellationError() }
        if failure == "rejected", command == 1 { return try bootReply(b, accepted: false) }
        return bytes(vector.rx)
    }
}
final class MaintenanceTests: XCTestCase {
    private func controller(_ t: SDKTransport) -> MaintenanceController {
        MaintenanceController(transport: t, clientTag: 0x123456f9, timestamp: { 1_700_000_000 }, sleep: { _ in })
    }
    private func firmware(_ size: Int = 777) throws -> FirmwareImage {
        let stem = "N1215-288_APP_0226"
        return try FirmwareImage(filename: stem + String(format: "_%04X_ANY.bin", MaintenanceProtocol.crc16(Array(stem.utf8))), data: Data((0..<size).map { UInt8($0 % 256) }))
    }
    func testPrivateCodecMatchesEverySDKCapture() throws {
        let vectors = try fixtures(); XCTAssertGreaterThan(vectors.count, 100)
        for vector in vectors {
            let b = bytes(vector.tx)
            XCTAssertEqual(try ServoProtocol.crc(Array(b.dropLast(4))), ServoProtocol.read32(b, b.count - 4))
            if b[2] >> 4 == 15 {
                let c = ServoProtocol.read32(b, 4)
                let request = try BootRequest(id: Int(b[2] & 15), lengthCode: Int(c >> 12 & 15), command: Int(c >> 8 & 15), address: Int(c >> 16 & 0x3fff), sector: Int(c >> 30), payload: Array(b[8..<(b.count - 4)]))
                XCTAssertEqual(try request.encode(), b)
                XCTAssertEqual(try request.decode(bytes(vector.rx)), Array(bytes(vector.rx)[6..<(6 + request.payload.count)]))
            }
        }
    }
    func testBootRejectsCorruptMismatchedAndNegativeAcknowledgements() throws {
        let request = try BootRequest(id: 0, command: 1, address: 5)
        let tx = try request.encode(); var reply = try bootReply(tx); reply[6] ^= 1
        XCTAssertThrowsError(try request.decode(reply))
        XCTAssertThrowsError(try request.decode(bootReply(tx, accepted: false)))
        XCTAssertThrowsError(try request.decode(bootReply(BootRequest(id: 1, command: 1, address: 5).encode())))
        XCTAssertThrowsError(try request.decode([]))
        XCTAssertThrowsError(try BootRequest(id: 15, command: 1))
        XCTAssertThrowsError(try BootRequest(id: 0, lengthCode: 9, command: 1, payload: [0]))
    }
    func testFirmwareValidationAndPaddedCRCMatchSDK() throws {
        let image = try firmware(); XCTAssertEqual(image.bytes.count, 784)
        XCTAssertEqual(Array(image.bytes.suffix(7)), Array(repeating: 255, count: 7))
        XCTAssertEqual(image.crc, 0x8514); XCTAssertEqual(try firmware(768).crc, 0x77e2)
        XCTAssertThrowsError(try FirmwareImage(filename: "N1215-288_APP_0226_0000.bin", data: Data(repeating: 0, count: 8)))
        XCTAssertThrowsError(try FirmwareImage(filename: image.filename.replacingOccurrences(of: "APP", with: "BOOT"), data: Data(image.bytes)))
        XCTAssertThrowsError(try FirmwareImage(filename: image.filename, data: Data(repeating: 0, count: 131073)))
        XCTAssertThrowsError(try FirmwareImage(filename: image.filename, data: Data()))
    }
    func testCalibrationModesAndResponseValidationMatchSDK() throws {
        for (op, calibration) in [("calibration", Calibration(mode: .limits, position: 0.2, travel: 1.5)), ("factory", Calibration(mode: .factory)), ("precise", Calibration(mode: .precise))] {
            let v = try XCTUnwrap(fixtures().first { $0.operation == op && bytes($0.tx)[5] == 0xfc })
            XCTAssertEqual(try calibration.encode(id: 0, clientTag: 0x123456f9, timestamp: 1_700_000_000), bytes(v.tx))
            _ = try calibration.validate(bytes(v.rx), id: 0)
            XCTAssertThrowsError(try calibration.validate(feedback(0), id: 0))
        }
        XCTAssertThrowsError(try Calibration(mode: .limits, position: .nan, travel: 1).encode(id: 0, clientTag: 0, timestamp: 0))
        XCTAssertThrowsError(try Calibration(mode: .limits, position: 0, travel: 0).encode(id: 0, clientTag: 0, timestamp: 0))
    }
    func testVersionUsesDedicatedFrame() throws {
        let v = try XCTUnwrap(fixtures().first { $0.operation == "version" })
        let version = try FirmwareVersion.decode(bytes(v.rx), id: 0)
        XCTAssertEqual(version.raw, 0x030a0226); XCTAssertTrue(version.supportsCalibration); XCTAssertTrue(version.supportsBaudChange)
        XCTAssertThrowsError(try FirmwareVersion.decode(feedback(0), id: 0))
        XCTAssertFalse(FirmwareVersion(raw: 0x03090214).supportsBaudChange)
    }
    func testAllConfigurationOperationsUseSDKWrites() async throws {
        let operations: [MaintenanceOperation] = [.version, .serialNumber, .clearError, .restart, .enterBootloader, .switchBoot, .changeID(3), .automaticBoot(true), .automaticBoot(false), .changeBaud(4_000_000), .calibrate(.init(mode: .precise)), .calibrate(.init(mode: .factory)), .calibrate(.init(mode: .limits, position: 0.2, travel: 1.5))]
        for operation in operations {
            let t = try SDKTransport(); let result = try await controller(t).run(operation, id: 0)
            XCTAssertFalse(result.message.isEmpty)
            if case .changeBaud = operation { let baud = await t.baud; XCTAssertEqual(baud, 4_000_000) }
            if case .changeID = operation { XCTAssertEqual(result.newID, 3) }
        }
    }
    func testOTACompleteAgainstSDKAndFinalVersionCheck() async throws {
        let t = try SDKTransport(); let result = try await controller(t).run(.firmware(firmware()), id: 0)
        XCTAssertEqual(result.version?.app, 0x0226)
        let packets = await t.packets
        let writes = packets.filter { $0[2] >> 4 == 15 && $0[5] & 15 == 1 && $0[7] >> 6 == 1 }
        XCTAssertEqual(writes.count, 26)
        let otaVectors = try fixtures().filter { $0.operation == "ota777" }
        let otaPackets: [[UInt8]] = otaVectors.map { bytes($0.tx) }
        let expected = otaPackets.filter { $0[2] >> 4 == 15 && $0[5] & 15 == 1 && $0[7] >> 6 == 1 }
        XCTAssertEqual(writes, expected)
    }
    func testFailedWriteOrCancellationNeverSavesOrStartsImage() async throws {
        for failure in ["readback", "cancel", "rejected", "timeout"] {
            let t = try SDKTransport(failure)
            do { _ = try await controller(t).run(.firmware(firmware()), id: 0); XCTFail("Expected \(failure)") } catch { }
            let packets = await t.packets
            XCTAssertFalse(packets.contains { $0[2] >> 4 == 15 && ($0[5] == 5 || $0[5] == 2) })
        }
    }
    func testOccupiedIDAndInvalidInputNeverWriteConfiguration() async throws {
        let t = try SDKTransport("occupied")
        do { _ = try await controller(t).run(.changeID(3), id: 0); XCTFail("Occupied ID") } catch { }
        let packets = await t.packets; XCTAssertEqual(packets.count, 1)
        for op: MaintenanceOperation in [.changeID(15), .changeID(0), .changeBaud(9600)] {
            let t = try SDKTransport()
            do { _ = try await controller(t).run(op, id: 0); XCTFail("Invalid") } catch { }
            let packets = await t.packets; XCTAssertTrue(packets.isEmpty)
        }
    }
    func testTinyNonzeroTravelCannotSilentlySelectPreciseMode() throws {
        for value in [1e-8, -1e-8] {
            XCTAssertThrowsError(try Calibration(mode: .limits, travel: value).encode(id: 0, clientTag: 0, timestamp: 0))
        }
    }
    func testStaleStopFrameCannotConfirmClearError() async throws {
        let t = try SDKTransport("staleClear")
        do { _ = try await controller(t).run(.clearError, id: 0); XCTFail("Not a clear acknowledgement") } catch { }
    }
    func testRestartWaitsForApplicationWithoutSecondBootReset() async throws {
        let t = try SDKTransport()
        _ = try await controller(t).run(.restart, id: 0)
        let frames = await t.packets
        XCTAssertEqual(frames.map { $0[2] }, [15, 0x70, 0])
        let bad = try SDKTransport("faultStop")
        do { _ = try await controller(bad).run(.restart, id: 0); XCTFail("Fault cannot confirm restart") } catch { }
    }
    func testWrongRunningVersionDoesNotReportUpgradeSuccess() async throws {
        let t = try SDKTransport("version")
        do { _ = try await controller(t).run(.firmware(firmware()), id: 0); XCTFail("Wrong version") }
        catch { XCTAssertTrue(error.localizedDescription.contains("版本"), error.localizedDescription) }
    }
}

private actor DuplicateTransport: MaintenanceTransport {
    let captures: [Vector]
    var packets: [[UInt8]] = []
    var discoveredQueries = 0
    var assigned = 0
    var saved = 0
    let noisy: Bool
    init(noisy: Bool = false) throws {
        let url = Bundle.module.url(forResource: "duplicate-vectors", withExtension: "json", subdirectory: "Fixtures")!
        captures = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url)); self.noisy = noisy
    }
    func setBaud(_ baud: Int) async throws { }
    func transact(_ b: [UInt8], responseLength: Int, timeout: Duration) async throws -> [UInt8] {
        packets.append(b)
        if b[2] >> 4 == 0, b[2] & 15 != 15 { throw MotorError.timeout }
        if responseLength == 0 { return [] }
        if assigned == 0, b[5] == 0, b[6] == 4, b[2] & 15 != 0 { throw MotorError.timeout }
        if b[5] == 0x97 {
            if b[32] == 0 { discoveredQueries += 1 } else { assigned += 1 }
            if noisy { throw MotorError.collision }
            guard let vector = captures.first(where: { bytes($0.tx) == b }) else { throw MotorError.invalid("SN 搜索/分配与 SDK 不一致：\(b.hex)") }
            if vector.operation == "collision" { throw MotorError.collision }
            return bytes(vector.rx)
        }
        if b[5] == 2 { saved += 1 }
        if b[5] == 0, b[6] == 4 { return try bootReply(b, payload: [b[2] & 15] + Array(repeating: 0, count: 7)) }
        guard let vector = captures.first(where: { bytes($0.tx) == b }) else { throw MotorError.invalid("配置与 SDK 不一致：\(b.hex)") }
        return bytes(vector.rx)
    }
}
extension MaintenanceTests {
    func testDuplicateIDsDiscoveredAssignedAndSavedAgainstSDK() async throws {
        let t = try DuplicateTransport()
        let c = MaintenanceController(transport: t, clientTag: 0x123456f9, timestamp: { 1_700_000_000 }, sleep: { _ in })
        let result = try await c.repairIDs(0)
        XCTAssertEqual(result.discoveredIDs, [0, 1])
        let queries = await t.discoveredQueries, assigned = await t.assigned, saved = await t.saved
        XCTAssertEqual(queries, 3); XCTAssertEqual(assigned, 2); XCTAssertEqual(saved, 2)
    }
    func testNoisySerialSearchTerminatesWithoutAssigningIDs() async throws {
        let t = try DuplicateTransport(noisy: true)
        let c = MaintenanceController(transport: t, clientTag: 0x123456f9, sleep: { _ in })
        do { _ = try await c.repairIDs(0); XCTFail("Noise must fail") } catch { }
        let queries = await t.discoveredQueries, assigned = await t.assigned
        XCTAssertLessThanOrEqual(queries, 97); XCTAssertEqual(assigned, 0)
    }
    func test96BitMidpointAndCarry() {
        XCTAssertEqual(SerialNumber96.zero.midpoint(to: .maximum), SerialNumber96(high: 0x7fffffff, low: .max))
        XCTAssertEqual(SerialNumber96(high: 1, low: .max).successor(), SerialNumber96(high: 2, low: 0))
        let a = SerialNumber96(high: 0x80000000, low: 3)
        XCTAssertEqual(SerialNumber96(wire: a.wire), a)
        XCTAssertEqual(a.midpoint(to: a.successor()), a)
    }
}
