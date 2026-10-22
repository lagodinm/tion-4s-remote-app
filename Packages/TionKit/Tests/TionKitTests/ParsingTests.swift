import XCTest
@testable import TionKit

final class ParsingTests: XCTestCase {
    /// A state payload with every field set to a recognisable value.
    private func sampleState() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 31)
        bytes[0] = 0b0100_1101          // power, light, heater running, filter warning; heater mode = heating
        bytes[1] = 0b0001_0101          // heater rating code 2 (1400 W), MagicAir connected, timer active
        bytes[2] = 0                    // outside air
        bytes[3] = 21                   // target °C
        bytes[4] = 4                    // fan speed
        bytes[5] = UInt8(bitPattern: -12) // outdoor °C
        bytes[6] = 19                   // supply °C
        bytes[7] = 35                   // control board °C
        bytes[8] = 41                   // power board °C
        bytes.replaceSubrange(9..<13, with: UInt32(3_600_000).littleEndianBytes)
        bytes.replaceSubrange(13..<17, with: UInt32(1_800_000).littleEndianBytes)
        bytes.replaceSubrange(17..<21, with: UInt32(150 * 86_400).littleEndianBytes)
        bytes.replaceSubrange(21..<25, with: UInt32(240_000).littleEndianBytes)
        bytes.replaceSubrange(25..<29, with: UInt32((1 << 1) | (1 << 25)).littleEndianBytes)
        bytes[29] = 6
        bytes[30] = 55
        return bytes
    }

    func testStateFields() throws {
        let state = try BreezerState(bytes: sampleState())
        XCTAssertTrue(state.powerOn)
        XCTAssertFalse(state.soundOn)
        XCTAssertTrue(state.lightOn)
        XCTAssertTrue(state.heaterRunning)
        XCTAssertTrue(state.heaterModeHeating)
        XCTAssertTrue(state.filterWarning)
        XCTAssertEqual(state.heaterRatingCode, 2)
        XCTAssertEqual(state.heaterRatedWatts, 1400)
        XCTAssertTrue(state.magicAirConnected)
        XCTAssertFalse(state.magicAirAuto)
        XCTAssertTrue(state.timerActive)
        XCTAssertFalse(state.recirculation)
        XCTAssertEqual(state.targetTemperature, 21)
        XCTAssertEqual(state.fanSpeed, 4)
        XCTAssertEqual(state.outdoorTemperature, -12)
        XCTAssertEqual(state.supplyTemperature, 19)
        XCTAssertEqual(state.controlBoardTemperature, 35)
        XCTAssertEqual(state.powerBoardTemperature, 41)
        XCTAssertEqual(state.poweredOnSeconds, 3_600_000)
        XCTAssertEqual(state.fanRunSeconds, 1_800_000)
        XCTAssertEqual(state.filterDaysLeft, 150)
        XCTAssertEqual(state.filterPercentLeft, 83)
        XCTAssertEqual(state.totalAirflowCubicMeters, 1000, accuracy: 0.001)
        XCTAssertEqual(state.maxFanSpeed, 6)
        XCTAssertEqual(state.heaterLoadPercent, 55)
        XCTAssertEqual(state.heaterWatts, 770)
        XCTAssertTrue(state.heatingEnabled)
        XCTAssertEqual(state.faults.map(\.code), ["EC02", "WS02"])
        XCTAssertEqual(state.faults.map(\.kind), [.error, .warning])
    }

    func testStateFromResponsePacketSkipsCommandId() throws {
        let packet = TionPacket(frameType: FrameType.stateResponse.rawValue, requestId: 7, random: 0, body: [9, 9, 9, 9] + sampleState())
        XCTAssertEqual(try BreezerState(response: packet).fanSpeed, 4)
    }

    func testRatingCodeOneUsesBitSevenOfFirstByte() throws {
        var bytes = sampleState()
        bytes[0] |= 0x80
        bytes[1] &= ~0x03
        XCTAssertEqual(try BreezerState(bytes: bytes).heaterRatedWatts, 1000)
    }

    func testShortStateIsRejected() {
        XCTAssertThrowsError(try BreezerState(bytes: [UInt8](repeating: 0, count: 10)))
    }

    func testSettingsRoundTripFromState() throws {
        let settings = BreezerSettings(state: try BreezerState(bytes: sampleState()))
        XCTAssertEqual(settings, BreezerSettings(powerOn: true, soundOn: false, lightOn: true, heaterOn: true, recirculation: false, targetTemperature: 21, fanSpeed: 4))
        XCTAssertEqual(settings.commandData(), [0x15, 0, 0, 21, 4, 0, 0])
    }

    func testAirflowRate() throws {
        var earlier = sampleState()
        earlier.replaceSubrange(13..<17, with: UInt32(1_000).littleEndianBytes)
        earlier.replaceSubrange(21..<25, with: UInt32(10_000).littleEndianBytes)
        var later = earlier
        later.replaceSubrange(13..<17, with: UInt32(1_060).littleEndianBytes)
        later.replaceSubrange(21..<25, with: UInt32(10_400).littleEndianBytes)
        let rate = try BreezerState(bytes: later).airflowRate(since: try BreezerState(bytes: earlier))
        XCTAssertEqual(try XCTUnwrap(rate), 100, accuracy: 0.001) // 400 × 15 / 60 s
    }

    func testDeviceInfo() throws {
        let body: [UInt8] = [1, 0x03, 0x80, 0x00, 0x00, 0x50, 0x00, 0x02, 0x00] + [UInt8](repeating: 0, count: 16)
        let info = try DeviceInfo(response: TionPacket(frameType: FrameType.deviceInfoResponse.rawValue, requestId: 0, random: 0, body: body))
        XCTAssertTrue(info.isBreezer4S)
        XCTAssertEqual(info.firmwareVersion, 80)
        XCTAssertEqual(info.firmwareString, "0050")
        XCTAssertEqual(info.hardwareVersion, 2)
        XCTAssertTrue(info.supportsTimers)
        XCTAssertEqual(info.workModeName, "Normal")
    }

    func testTurboInfo() throws {
        let packet = TionPacket(frameType: FrameType.turboResponse.rawValue, requestId: 0, random: 0, body: [0, 0, 0, 0, 1, 0x58, 0x02, 0])
        let turbo = try TurboInfo(response: packet)
        XCTAssertTrue(turbo.active)
        XCTAssertEqual(turbo.secondsLeft, 600)
        XCTAssertEqual(turbo.errorCode, 0)
    }

    func testTimersState() throws {
        let flags: [UInt8] = [1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        let state = try TimersState(response: TionPacket(frameType: FrameType.timersStateResponse.rawValue, requestId: 0, random: 0, body: [0, 0, 0, 0] + flags))
        XCTAssertEqual(state.active, flags.map { $0 == 1 })
    }

    func testClockEncodesLocalTime() throws {
        let moscow = try XCTUnwrap(TimeZone(secondsFromGMT: 3 * 3600))
        let date = Date(timeIntervalSince1970: 1_761_100_000)
        let value = DeviceClock.deviceValue(for: date, timeZone: moscow)
        XCTAssertEqual(value, 1_761_100_000 + 3 * 3600)
        XCTAssertEqual(DeviceClock.date(fromDeviceValue: value, timeZone: moscow, now: date), date)

        let packet = TionPacket(frameType: FrameType.timeResponse.rawValue, requestId: 0, random: 0, body: [0, 0, 0, 0] + value.littleEndianBytes)
        XCTAssertEqual(try DeviceClock.value(from: packet), value)
    }

    func testAdvertisement() {
        var data = [UInt8](repeating: 0, count: 13)
        data[8] = 0x03
        data[9] = 0x80
        data[12] = 1
        let ad = TionAdvertisement(manufacturerData: data)
        XCTAssertEqual(ad?.isBreezer4S, true)
        XCTAssertEqual(ad?.pairingMode, true)

        data[12] = 0
        XCTAssertEqual(TionAdvertisement(manufacturerData: data)?.pairingMode, false)
        XCTAssertNil(TionAdvertisement(manufacturerData: [1, 2, 3]))
    }
}
