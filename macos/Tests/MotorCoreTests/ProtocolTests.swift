import Foundation
import XCTest
@testable import MotorCore

final class ProtocolTests: XCTestCase {
    struct Vector: Decodable {
        var id: Int; var mode: String; var timeout: Int
        var torque: Double; var speed: Double; var position: Double
        var kp: Double; var kd: Double; var hex: String
    }

    func testCommandsMatchActualPackagedWindowsSDK() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sdk-vectors", withExtension: "json", subdirectory: "Fixtures"))
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
        for v in vectors {
            let command = MotorCommand(id: v.id, mode: v.mode == "Stop" ? .stop : .foc,
                torque: v.torque, speed: v.speed, position: v.position, kp: v.kp, kd: v.kd, timeoutProtection: v.timeout != 0)
            XCTAssertEqual(try command.encode().hex.replacingOccurrences(of: " ", with: "").lowercased(), v.hex)
        }
    }
    func testInvalidCommandsNeverWrapOrSilentlySaturate() throws {
        for command in [MotorCommand(id: -1), MotorCommand(id: 16),
                        MotorCommand(mode: .foc, torque: .nan), MotorCommand(mode: .foc, position: .infinity),
                        MotorCommand(mode: .foc, torque: 37), MotorCommand(mode: .foc, kp: -1),
                        MotorCommand(mode: .stop, speed: 1)] {
            XCTAssertThrowsError(try command.encode())
        }
        XCTAssertThrowsError(try ServoProtocol.crc([1, 2, 3]))
    }
    func testFeedbackUnsignedTemperaturesVoltageAndNegativePosition() throws {
        let b = try feedback()
        let result = try MotorFeedback.decode(b)
        XCTAssertEqual(result.id, 3)
        XCTAssertEqual(result.mode, 1)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.temperature, -5)
        XCTAssertEqual(result.windingTemperature, 200)
        XCTAssertEqual(result.voltage, 100)
        XCTAssertEqual(result.position, -2 * .pi / ServoProtocol.ratio, accuracy: 1e-10)
        XCTAssertEqual(result.torque, -128 * ServoProtocol.ratio / 256000, accuracy: 1e-10)
        XCTAssertEqual(result.error, 0x80000001)
        XCTAssertEqual(result.warning, 5)
        XCTAssertEqual(result.encoderPosition, .pi, accuracy: 1e-10)
    }
    func testParserRecoversFromNoiseBadCRCPartialAndConcatenatedFrames() throws {
        let b = try feedback()
        var bad = b; bad[10] ^= 0xff
        var parser = FrameParser()
        XCTAssertTrue(parser.feed([0x01, 0x02, 0xfc]).isEmpty)
        XCTAssertTrue(parser.feed(Array(b.dropFirst().prefix(10))).isEmpty)
        XCTAssertEqual(parser.feed(Array(b.dropFirst(11))).count, 1)
        XCTAssertEqual(parser.feed(bad + b + b).count, 2)
        XCTAssertEqual(parser.badCRC, 1)
        XCTAssertLessThan(parser.buffer.count, 26)
        XCTAssertThrowsError(try MotorFeedback.decode(bad))
        XCTAssertThrowsError(try MotorFeedback.decode(Array(b.dropLast())))
    }
    func testAllFragmentBoundaries() throws {
        let b = try feedback()
        for split in 0...b.count {
            var parser = FrameParser()
            let first = parser.feed(Array(b.prefix(split)))
            let second = parser.feed(Array(b.dropFirst(split)))
            XCTAssertEqual(first.count + second.count, 1)
        }
    }
    func testDefaultCommandAlwaysEnablesTimeoutAndHasZeroTargets() throws {
        let bytes = try MotorCommand(id: 14).encode()
        XCTAssertEqual(bytes[2], 0x8e)
        XCTAssertEqual(Array(bytes[4..<16]), [UInt8](repeating: 0, count: 12))
    }
    func testSessionRejectsUnsupportedPathsBeforeOpeningDevice() async throws {
        let session = SerialSession()
        do { try await session.connect(path: "/dev/null"); XCTFail("Must reject non-serial path") }
        catch { XCTAssertTrue(error is MotorError) }
        do { _ = try await session.exchange(MotorCommand()); XCTFail("Must reject disconnected session") }
        catch { XCTAssertTrue(error is MotorError) }
    }
    private func feedback() throws -> [UInt8] {
        var bytes: [UInt8] = [0xfc, 0xee, 0x13, 0xfb, 200, 200]
        ServoProtocol.append(Int16(-128), to: &bytes)
        ServoProtocol.append(Int16(-64), to: &bytes)
        ServoProtocol.append(Int32(-32768), to: &bytes)
        ServoProtocol.append(UInt32(0x80000001), to: &bytes)
        ServoProtocol.append(UInt16((5 << 13) | 4096), to: &bytes)
        bytes += [0, 0]
        ServoProtocol.append(try ServoProtocol.crc(Array(bytes[2..<22])), to: &bytes)
        return bytes
    }
}
