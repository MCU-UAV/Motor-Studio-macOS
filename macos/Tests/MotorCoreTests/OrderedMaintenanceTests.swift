import Foundation
import XCTest
@testable import MotorCore

private struct Fixture: Decodable { let operation: String; let tx: String; let rx: String }
private func hex(_ value: String) -> [UInt8] {
    let chars=Array(value); return stride(from:0,to:chars.count,by:2).map { UInt8(String(chars[$0...($0+1)]),radix:16)! }
}
private func crcFrame(_ value: [UInt8]) throws -> [UInt8] { var b=value; ServoProtocol.append(try ServoProtocol.crc(Array(b[2...])),to:&b);return b }
private func bootRX(_ tx: [UInt8], value: UInt8) throws -> [UInt8] {
    try crcFrame([0xfc,0xee,tx[2]&15|128,tx[5],tx[6],tx[7],value]+Array(repeating:0,count:15))
}
private struct Event { let tx: [UInt8]; let rx: [UInt8]; let timeout: Bool }
private actor Replay: MaintenanceTransport {
    var events: [Event]
    var consumed=0
    let failAt: Int?
    init(_ events: [Event], failAt: Int? = nil) { self.events=events; self.failAt=failAt }
    func setBaud(_ baud: Int) async throws { XCTAssertEqual(baud,4_000_000) }
    func transact(_ tx: [UInt8],responseLength:Int,timeout:Duration) async throws -> [UInt8] {
        guard let next=events.first, next.tx==tx else { throw MotorError.invalid("ORDER mismatch step \(consumed), got \(tx.hex)") }
        events.removeFirst();consumed += 1
        if consumed - 1 == failAt { throw MotorError.invalid("injected rejection") }
        if next.timeout { throw MotorError.timeout }
        return responseLength==0 ? [] : next.rx
    }
    func remaining() -> Int { events.count }
}
final class OrderedMaintenanceTests: XCTestCase {
    func testCompleteSDKSequencesAndEveryRejectedStep() async throws {
        let url = Bundle.module.url(forResource:"private-vectors",withExtension:"json",subdirectory:"Fixtures")!
        let fixtures=try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:url))
        let stop=try MaintenanceProtocol.command(id:0,mode:0)
        let stopRX=try crcFrame([0xfc,0xee,0,30,35,48]+Array(repeating:0,count:16))
        let version=fixtures.first { $0.operation=="version" }!
        func image(_ size:Int) throws -> FirmwareImage {
            let stem="N1215-288_APP_0226"
            return try FirmwareImage(filename:stem+String(format:"_%04X_ANY.bin",MaintenanceProtocol.crc16(Array(stem.utf8))),data:Data((0..<size).map{UInt8($0%256)}))
        }
        let operations:[(String,MaintenanceOperation)] = [("baud",.changeBaud(4_000_000)),("version",.version),("sn",.serialNumber),("clear",.clearError),("id",.changeID(3)),("atb",.automaticBoot(true)),("atb_off",.automaticBoot(false)),("calibration",.calibrate(.init(mode:.limits,position:0.2,travel:1.5))),("factory",.calibrate(.init(mode:.factory))),("precise",.calibrate(.init(mode:.precise))),("ota768",.firmware(try image(768))),("ota777",.firmware(try image(777)))]
        for (name,operation) in operations {
            var expected=try fixtures.filter{$0.operation==name}.map { f -> Event in
                var tx=hex(f.tx)
                // This SDK read-only probe contains stack garbage. Deterministically zero its payload and recalculate TX CRC.
                if tx[2]>>4==15 && tx[5]==0x90 && tx[6]==0 && tx[7]==64 {
                    tx.replaceSubrange(8..<(tx.count-4),with:Array(repeating:0,count:32))
                    tx.removeLast(4);ServoProtocol.append(try ServoProtocol.crc(tx),to:&tx)
                }
                return Event(tx:tx,rx:hex(f.rx),timeout:false)
            }
            // Explicitly enumerated native extra checks; SDK events are never skipped/reordered.
            if name=="id" {
                let probe=try BootRequest(id:3,command:0,address:4).encode()
                expected.insert(contentsOf:[Event(tx:try MaintenanceProtocol.command(id:3,mode:0),rx:[],timeout:true),Event(tx:probe,rx:[],timeout:true)],at:0)
                expected.append(Event(tx:probe,rx:try bootRX(probe,value:3),timeout:false))
            }
            if name=="atb" || name=="atb_off" {
                let read=try BootRequest(id:0,command:0,address:5).encode()
                expected.append(Event(tx:read,rx:try bootRX(read,value:name=="atb" ? 1:0),timeout:false))
            }
            if name=="clear" { expected.append(Event(tx:stop,rx:stopRX,timeout:false)) }
            if ["calibration","factory","precise"].contains(name) { expected.insert(Event(tx:stop,rx:stopRX,timeout:false),at:0) }
            if name.hasPrefix("ota") { expected.append(Event(tx:hex(version.tx),rx:hex(version.rx),timeout:false)) }
            let replay=Replay(expected)
            let controller=MaintenanceController(transport:replay,clientTag:0x123456f9,timestamp:{1_700_000_000},sleep:{_ in})
            _ = try await controller.run(operation,id:0)
            let remaining=await replay.remaining()
            XCTAssertEqual(remaining,0,name)
            for step in expected.indices {
                let failed=Replay(expected,failAt:step)
                let controller=MaintenanceController(transport:failed,clientTag:0x123456f9,timestamp:{1_700_000_000},sleep:{_ in})
                do { _ = try await controller.run(operation,id:0); XCTFail("Expected rejection at \(name):\(step)") } catch { }
                let consumed=await failed.consumed
                XCTAssertEqual(consumed,step+1,"No later writes after \(name):\(step)")
            }
        }
    }
}
