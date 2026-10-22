import XCTest
@testable import TionKit

/// Expected bytes are packets as the Tion Remote app builds them, with fixed ids: request id
/// bytes 11 22 33 44, command id bytes A1 A2 A3 A4, random byte 0x5A.
final class PacketTests: XCTestCase {
    private let requestId: UInt32 = 0x1122_3344
    private let commandId: UInt32 = 0xA1A2_A3A4
    private let random: UInt8 = 0x5A

    private func packetHex(_ request: TionRequest) -> String {
        request.packet(requestId: requestId, random: random).encoded().map { String(format: "%02X", $0) }.joined()
    }

    private func framesHex(_ request: TionRequest) -> [String] {
        TionFraming.frames(for: request.packet(requestId: requestId, random: random).encoded())
            .map { $0.map { String(format: "%02X", $0) }.joined() }
    }

    func testChecksumMatchesCcittFalseCheckValue() {
        XCTAssertEqual(CRC16.ccittFalse(Array("123456789".utf8)), 0x29B1)
    }

    func testRequestState() {
        let request = TionRequest.requestState(commandId: commandId)
        XCTAssertEqual(packetHex(request), "10003A5A323244332211A4A3A2A10BE3")
        XCTAssertEqual(framesHex(request), ["8010003A5A323244332211A4A3A2A10BE3"])
    }

    func testRequestDeviceInfoHasNoCommandId() {
        XCTAssertEqual(packetHex(.requestDeviceInfo()), "0C003A5A323344332211D4C2")
    }

    func testSetStateIsSplitIntoTwoFrames() {
        let settings = BreezerSettings(powerOn: true, soundOn: true, lightOn: false, heaterOn: true, recirculation: false, targetTemperature: 20, fanSpeed: 3)
        let request = TionRequest.setState(settings, commandId: commandId)
        XCTAssertEqual(packetHex(request), "17003A5A303244332211A4A3A2A113000014030000414C")
        XCTAssertEqual(framesHex(request), ["0017003A5A303244332211A4A3A2A11300001403", "C00000414C"])
    }

    func testSetStateWithFilterReset() {
        let settings = BreezerSettings(powerOn: false, soundOn: false, lightOn: true, heaterOn: false, recirculation: true, targetTemperature: 15, fanSpeed: 2)
        let request = TionRequest.setState(settings, resetFilter: true, commandId: commandId)
        XCTAssertEqual(packetHex(request), "17003A5A303244332211A4A3A2A19C00010F02B500197D")
    }

    func testSetTimer() {
        let slot = TimerSlot(id: 2, days: .everyDay, hour: 22, minute: 0, enabled: true, powerOn: true,
                             soundOn: false, lightOn: true, heaterOn: true, targetTemperature: 18, fanSpeed: 4, recirculation: false)
        let request = TionRequest.setTimer(slot, commandId: commandId)
        XCTAssertEqual(packetHex(request), "18003A5A303444332211A4A3A2A1027F1600151204008A0C")
        XCTAssertEqual(framesHex(request), ["0018003A5A303444332211A4A3A2A1027F160015", "C01204008A0C"])
    }

    func testRequestTimer() {
        XCTAssertEqual(packetHex(.requestTimer(id: 5, commandId: commandId)), "11003A5A323444332211A4A3A2A105DF8D")
    }

    func testRequestTimersState() {
        XCTAssertEqual(packetHex(.requestTimersState(commandId: commandId)), "10003A5A323544332211A4A3A2A1BA48")
    }

    func testSetTime() {
        let request = TionRequest.setTime(1_761_100_000, commandId: commandId)
        XCTAssertEqual(packetHex(request), "24003A5A303644332211A4A3A2A1E040F868000000000000000000000000000000000F6E")
        XCTAssertEqual(framesHex(request), ["0024003A5A303644332211A4A3A2A1E040F86800", "C00000000000000000000000000000000F6E"])
    }

    func testRequestTime() {
        XCTAssertEqual(packetHex(.requestTime(commandId: commandId)), "10003A5A323644332211A4A3A2A1970C")
    }

    func testSetTurbo() {
        XCTAssertEqual(packetHex(.setTurbo(seconds: 600, commandId: commandId)),
                       "24003A5A304144332211A4A3A2A15802000000010000000000000000000000000000A388")
    }

    func testRequestTurbo() {
        XCTAssertEqual(packetHex(.requestTurbo(commandId: commandId)), "10003A5A324144332211A4A3A2A18D7C")
    }

    func testAssemblerRebuildsMultiFramePacket() throws {
        var assembler = FrameAssembler()
        XCTAssertNil(assembler.append([UInt8](hex: "0017003A5A303244332211A4A3A2A11300001403")!))
        let bytes = try XCTUnwrap(assembler.append([UInt8](hex: "C00000414C")!))
        let packet = try TionPacket.decode(bytes)
        XCTAssertTrue(packet.checksumValid)
        XCTAssertEqual(packet.frameType, FrameType.stateSet.rawValue)
        XCTAssertEqual(packet.requestId, requestId)
        XCTAssertEqual(packet.body, [0xA4, 0xA3, 0xA2, 0xA1, 0x13, 0x00, 0x00, 0x14, 0x03, 0x00, 0x00])
    }

    func testAssemblerPassesSingleFrameThrough() throws {
        var assembler = FrameAssembler()
        let bytes = try XCTUnwrap(assembler.append([UInt8](hex: "8010003A5A323244332211A4A3A2A10BE3")!))
        XCTAssertEqual(try TionPacket.decode(bytes).frameType, FrameType.stateRequest.rawValue)
    }

    func testDecodeFlagsBadChecksum() throws {
        var bytes = [UInt8](hex: "10003A5A323244332211A4A3A2A10BE3")!
        bytes[bytes.count - 1] ^= 0xFF
        XCTAssertFalse(try TionPacket.decode(bytes).checksumValid)
    }

    func testDecodeRejectsGarbage() {
        XCTAssertThrowsError(try TionPacket.decode([0x01, 0x02, 0x03]))
        XCTAssertThrowsError(try TionPacket.decode([UInt8](hex: "10003B5A323244332211A4A3A2A10BE3")!))
    }

    func testReplyMatchingUsesFrameTypeAndTimerId() {
        let request = TionRequest.requestTimer(id: 3)
        let slot3 = TionPacket(frameType: FrameType.timerResponse.rawValue, requestId: 1, random: 0, body: [0, 0, 0, 0, 3, 0x7F, 7, 0, 0x18, 18, 2, 0])
        let slot4 = TionPacket(frameType: FrameType.timerResponse.rawValue, requestId: 1, random: 0, body: [0, 0, 0, 0, 4, 0x7F, 7, 0, 0x18, 18, 2, 0])
        let state = TionPacket(frameType: FrameType.stateResponse.rawValue, requestId: 1, random: 0, body: [])
        XCTAssertTrue(request.isReply(slot3))
        XCTAssertFalse(request.isReply(slot4))
        XCTAssertFalse(request.isReply(state))
    }
}
