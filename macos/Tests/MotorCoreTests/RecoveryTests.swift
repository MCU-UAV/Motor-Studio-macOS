import Foundation
import XCTest
@testable import MotorCore

private final class RecoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ delay: Duration) { lock.lock(); value += delay; lock.unlock() }
}
private actor RecoveryTransport: MaintenanceTransport {
    enum Scenario { case ignoredReset, reboot, staysOffline, scanRecovery, scanNeverRecovers, temporary, temporaryRecovery }
    let scenario: Scenario
    let clock: RecoveryClock
    var packets: [[UInt8]] = []
    var reopens = 0
    var stopQueries = 0
    var holdWrites = 0
    init(_ scenario: Scenario, clock: RecoveryClock = RecoveryClock()) { self.scenario = scenario; self.clock = clock }
    func setBaud(_ baud: Int) async throws { }
    func recoverLink() async throws {
        reopens += 1
        if scenario == .scanNeverRecovers || reopens == 1 { throw MotorError.serial("temporary reopen failure") }
    }
    func collectIDs(_ request: [UInt8], timeout: Duration) async throws -> [UInt8] { [0, 3] }
    func transact(_ bytes: [UInt8], responseLength: Int, timeout: Duration) async throws -> [UInt8] {
        packets.append(bytes)
        if (scenario == .scanRecovery || scenario == .scanNeverRecovers) && reopens < 2 { throw MotorError.serial("unplugged") }
        if bytes[2] == 255 {
            holdWrites += 1
            if scenario == .temporaryRecovery && reopens < 2 { throw MotorError.serial("unplugged") }
            if holdWrites == 25 { throw CancellationError() }
        }
        if responseLength == 0 { return [] }
        stopQueries += 1
        clock.advance(.milliseconds(10))
        if scenario == .staysOffline || (scenario == .reboot && stopQueries == 2) { throw MotorError.timeout }
        var b: [UInt8] = [0xfc, 0xee, bytes[2] & 15, 30, 35, 48] + Array(repeating: 0, count: 16)
        ServoProtocol.append(try ServoProtocol.crc(Array(b[2...])), to: &b)
        return b
    }
}
final class RecoveryTests: XCTestCase {
    private func controller(_ t: RecoveryTransport, _ clock: RecoveryClock) -> MaintenanceController {
        MaintenanceController(transport:t,clientTag:0,sleep:{clock.advance($0)},now:{clock.now()})
    }
    func testRestartRejectsIgnoredResetAndMissingReturn() async throws {
        for scenario: RecoveryTransport.Scenario in [.ignoredReset,.staysOffline] {
            let clock=RecoveryClock()
            let t=RecoveryTransport(scenario,clock:clock)
            do { _ = try await controller(t,clock).run(.restart,id:0); XCTFail("No completed transition") }
            catch { XCTAssertTrue(error.localizedDescription.contains("复位")) }
        }
    }
    func testRestartRequiresOfflineThenHealthyStop() async throws {
        let clock=RecoveryClock()
        let t=RecoveryTransport(.reboot,clock:clock)
        _ = try await controller(t,clock).run(.restart,id:0)
        let count=await t.stopQueries
        XCTAssertEqual(count,3)
    }
    func testScanRetriesFailedReopenAndStopsAtLimit() async throws {
        for scenario: RecoveryTransport.Scenario in [.scanRecovery,.scanNeverRecovers] {
            let clock=RecoveryClock(), t=RecoveryTransport(scenario)
            do {
                let result=try await controller(t,clock).run(.scanIDs,id:0)
                XCTAssertEqual(scenario,.scanRecovery);XCTAssertEqual(result.discoveredIDs,[0,3])
            } catch { XCTAssertEqual(scenario,.scanNeverRecovers) }
            let reopens=await t.reopens;XCTAssertEqual(reopens,2)
        }
    }
    func testTemporaryBootContinuesPastTenAndDoesNotSaveOrStartOnExit() async throws {
        for scenario: RecoveryTransport.Scenario in [.temporary,.temporaryRecovery] {
            let clock=RecoveryClock(), t=RecoveryTransport(scenario)
            let result=try await controller(t,clock).run(.temporaryBoot,id:0)
            XCTAssertTrue(result.message.contains("退出"))
            let writes=await t.holdWrites, packets=await t.packets, reopens=await t.reopens
            XCTAssertEqual(writes,25)
            XCTAssertEqual(reopens,scenario == .temporaryRecovery ? 2 : 0)
            XCTAssertTrue(packets.dropFirst(2).allSatisfy{$0[2]==255 && $0[5]==1 && $0[6]==15})
        }
    }
    func testTemporaryBootTaskCancellationEndsPromptly() async throws {
        let t=RecoveryTransport(.temporary)
        let c=MaintenanceController(transport:t,clientTag:0)
        let task=Task { try await c.run(.temporaryBoot,id:0) }
        task.cancel()
        do {
            let result=try await task.value
            XCTAssertTrue(result.message.contains("退出"))
        } catch is CancellationError { }
    }
}

private actor BaudRecoveryTransport: MaintenanceTransport {
    let deviceBaud: Int
    let bootOnly: Bool
    let rejected: Bool
    var hostBaud = 6_000_000
    var appReady: Bool
    var bootResetSeen = false
    var switched: [Int] = []
    var configWrites = 0
    init(deviceBaud: Int, bootOnly: Bool = true, rejected: Bool = false) {
        self.deviceBaud=deviceBaud;self.bootOnly=bootOnly;self.rejected=rejected;appReady = !bootOnly
    }
    func currentBaud() async -> Int { hostBaud }
    func setBaud(_ baud: Int) async throws { hostBaud=baud;switched.append(baud) }
    func transact(_ b:[UInt8],responseLength:Int,timeout:Duration) async throws -> [UInt8] {
        if responseLength==0 { return [] }
        guard hostBaud==deviceBaud else { throw MotorError.timeout }
        var reply:[UInt8]
        if b[2]>>4 == 15 {
            if b[5]==4 {
                if rejected { throw MotorError.invalid("Boot rejected reset") }
                bootResetSeen=true;appReady=true
            }
            if b[5]&15 == 1 { configWrites += 1 }
            var payload=Array(b[8..<(b.count-4)])
            if b[5]==0 && b[6]==14 { payload[0]=UInt8(deviceBaud/100000) }
            reply=[0xfc,0xee,128,b[5],b[6],b[7]]+payload+Array(repeating:0,count:8)
        } else {
            guard appReady else { throw MotorError.timeout }
            reply=[0xfc,0xee,b[2]&127,30,35,48]+Array(repeating:0,count:16)
            if b[5]==0xfe { reply[3]=128;reply.replaceSubrange(10..<14,with:[0x26,2,0x0a,3]) }
        }
        ServoProtocol.append(try ServoProtocol.crc(Array(reply[2...])),to:&reply);return reply
    }
}
extension RecoveryTests {
    func testBaudRestoresBootApplicationAndFindsOtherRate() async throws {
        for rate in [6_000_000,4_000_000] {
            let t=BaudRecoveryTransport(deviceBaud:rate)
            let c=MaintenanceController(transport:t,clientTag:0,sleep:{_ in})
            let result=try await c.run(.changeBaud(rate),id:0)
            XCTAssertEqual(result.newBaud,rate)
            let reset=await t.bootResetSeen, host=await t.hostBaud, writes=await t.configWrites
            XCTAssertTrue(reset);XCTAssertEqual(host,rate)
            // Only unlock; the baud already matches so it must not save/write baud.
            XCTAssertEqual(writes,1)
        }
    }
    func testBaudDoesNotRetryExplicitDeviceRejection() async throws {
        let t=BaudRecoveryTransport(deviceBaud:6_000_000,rejected:true)
        do { _ = try await MaintenanceController(transport:t,clientTag:0,sleep:{_ in}).run(.changeBaud(4_000_000),id:0);XCTFail("Device rejected") } catch { }
        let switches=await t.switched, writes=await t.configWrites
        XCTAssertTrue(switches.isEmpty);XCTAssertEqual(writes,0)
    }
}
