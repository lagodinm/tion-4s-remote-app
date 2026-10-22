import Foundation

/// The Breezer 4S state, as returned by a state request (frame `0x3231`, after the echoed command id).
///
/// Byte layout (matches what the Tion Remote app reads, and ESPHome's `tion4s_state_t`):
///
/// | Byte  | Meaning |
/// |-------|---------|
/// | 0     | bit0 power, bit1 sound, bit2 light, bit3 heater element running, bit4 heater mode (0 = heating, 1 = fan only), bit5 last command source, bit6 filter warning, bit7 heater rating (low bit) |
/// | 1     | bits0-1 heater rating (high bits), bit2 MagicAir connected, bit3 MagicAir auto, bit4 timer active |
/// | 2     | air intake: 0 outside air, 1 recirculation |
/// | 3     | target temperature, °C (signed) |
/// | 4     | fan speed |
/// | 5     | outdoor (intake) air temperature, °C (signed) |
/// | 6     | supply air temperature, °C (signed) |
/// | 7, 8  | control board / power board temperature, °C (signed) |
/// | 9-12  | powered-on time, seconds |
/// | 13-16 | fan run time, seconds |
/// | 17-20 | filter time left, seconds |
/// | 21-24 | airflow counter (m³ = counter × 15 / 3600) |
/// | 25-28 | error and warning bits |
/// | 29    | maximum fan speed |
/// | 30    | heater load, % |
public struct BreezerState: Equatable {
    public static let minimumLength = 30
    public static let filterLifeDays = 180

    public let raw: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count >= Self.minimumLength else {
            throw TionProtocolError.payloadTooShort(expected: Self.minimumLength, actual: bytes.count)
        }
        raw = bytes
    }

    /// Parses a state response packet.
    public init(response: TionPacket) throws {
        try self.init(bytes: response.payload)
    }

    private func bit(_ byte: Int, _ bit: Int) -> Bool {
        raw[byte] & (1 << bit) != 0
    }

    private func signed(_ byte: Int) -> Int {
        Int(Int8(bitPattern: raw[byte]))
    }

    public var powerOn: Bool { bit(0, 0) }
    public var soundOn: Bool { bit(0, 1) }
    public var lightOn: Bool { bit(0, 2) }
    /// The heating element is drawing power right now.
    public var heaterRunning: Bool { bit(0, 3) }
    /// Heater mode is "heat to target" (as opposed to fan only).
    public var heaterModeHeating: Bool { !bit(0, 4) }
    public var lastCommandSourceBit: Bool { bit(0, 5) }
    public var filterWarning: Bool { bit(0, 6) }
    /// 0 = no heater, 1 = 1000 W, 2 = 1400 W.
    public var heaterRatingCode: Int { Int(raw[0] >> 7) | Int(raw[1] & 0x03) << 1 }
    public var magicAirConnected: Bool { bit(1, 2) }
    public var magicAirAuto: Bool { bit(1, 3) }
    public var timerActive: Bool { bit(1, 4) }

    public var recirculation: Bool { raw[2] != 0 }
    public var targetTemperature: Int { signed(3) }
    public var fanSpeed: Int { Int(raw[4]) }
    public var outdoorTemperature: Int { signed(5) }
    public var supplyTemperature: Int { signed(6) }
    public var controlBoardTemperature: Int { signed(7) }
    public var powerBoardTemperature: Int { signed(8) }

    public var poweredOnSeconds: UInt32 { raw.readLE(UInt32.self, at: 9) }
    public var fanRunSeconds: UInt32 { raw.readLE(UInt32.self, at: 13) }
    public var filterSecondsLeft: UInt32 { raw.readLE(UInt32.self, at: 17) }
    public var airflowCounter: UInt32 { raw.readLE(UInt32.self, at: 21) }
    public var faultBits: UInt32 { raw.readLE(UInt32.self, at: 25) }
    public var maxFanSpeed: Int { Int(raw[29]) }
    public var heaterLoadPercent: Int? { raw.count > 30 ? Int(raw[30]) : nil }

    // MARK: Derived values

    public var heaterInstalled: Bool { heaterRatingCode != 0 }

    public var heaterRatedWatts: Int? {
        switch heaterRatingCode {
        case 1: return 1000
        case 2: return 1400
        default: return nil
        }
    }

    /// Present heater draw, estimated from the rating and the load percentage.
    public var heaterWatts: Int? {
        guard let rated = heaterRatedWatts, let load = heaterLoadPercent else { return nil }
        return rated * load / 100
    }

    /// Heating is effectively on: heater present, in heating mode, and taking outside air
    /// (the Android app treats recirculation as heater off).
    public var heatingEnabled: Bool {
        heaterInstalled && heaterModeHeating && !recirculation
    }

    public var filterDaysLeft: Int { Int(filterSecondsLeft / 86_400) }

    public var filterPercentLeft: Int {
        Swift.max(0, Swift.min(100, filterDaysLeft * 100 / Self.filterLifeDays))
    }

    /// Total air moved since manufacture, m³.
    public var totalAirflowCubicMeters: Double {
        Double(airflowCounter) * 15 / 3600
    }

    public var faults: [DeviceFault] { DeviceFault.decode(faultBits) }

    /// Average airflow in m³/h between an earlier reading and this one, from the airflow and fan-time counters.
    public func airflowRate(since earlier: BreezerState) -> Double? {
        guard fanRunSeconds > earlier.fanRunSeconds, airflowCounter >= earlier.airflowCounter else { return nil }
        let seconds = Double(fanRunSeconds - earlier.fanRunSeconds)
        return Double(airflowCounter - earlier.airflowCounter) * 15 / seconds
    }
}

/// The values sent with a "set state" command (`0x3230`).
public struct BreezerSettings: Equatable, Codable {
    public static let temperatureRange = 0...30
    /// Filter life written by the Android app when the filter counter is reset.
    public static let filterResetDays = 181

    public var powerOn: Bool
    public var soundOn: Bool
    public var lightOn: Bool
    public var heaterOn: Bool
    public var recirculation: Bool
    public var targetTemperature: Int
    public var fanSpeed: Int

    public init(powerOn: Bool, soundOn: Bool, lightOn: Bool, heaterOn: Bool, recirculation: Bool, targetTemperature: Int, fanSpeed: Int) {
        self.powerOn = powerOn
        self.soundOn = soundOn
        self.lightOn = lightOn
        self.heaterOn = heaterOn
        self.recirculation = recirculation
        self.targetTemperature = targetTemperature
        self.fanSpeed = fanSpeed
    }

    public init(state: BreezerState) {
        self.init(
            powerOn: state.powerOn,
            soundOn: state.soundOn,
            lightOn: state.lightOn,
            heaterOn: state.heaterModeHeating,
            recirculation: state.recirculation,
            targetTemperature: state.targetTemperature,
            fanSpeed: state.fanSpeed
        )
    }

    /// Command data, as the Tion Remote app sends it:
    /// `[flags][0][intake][target °C][fan speed][filter days u16]`.
    /// Flags: bit0 power, bit1 sound, bit2 light, bit3 heater off, bit4 always set,
    /// bit5 factory reset (never sent), bit6 reset errors, bit7 reset filter.
    public func commandData(resetFilter: Bool = false, resetErrors: Bool = false) -> [UInt8] {
        var flags: UInt8 = 1 << 4
        if powerOn { flags |= 1 << 0 }
        if soundOn { flags |= 1 << 1 }
        if lightOn { flags |= 1 << 2 }
        if !heaterOn { flags |= 1 << 3 }
        if resetErrors { flags |= 1 << 6 }
        if resetFilter { flags |= 1 << 7 }
        var data: [UInt8] = [flags, 0]
        data.append(recirculation ? 1 : 0)
        data.append(UInt8(bitPattern: Int8(clamping: targetTemperature)))
        data.append(UInt8(clamping: Swift.max(1, fanSpeed)))
        data += resetFilter ? UInt16(Self.filterResetDays).littleEndianBytes : [0, 0]
        return data
    }
}

/// An error (EC01–EC11) or warning (WS01–WS06) reported in the state's fault bits.
public struct DeviceFault: Hashable, Identifiable {
    public enum Kind: Hashable {
        case error
        case warning
    }

    public let code: String
    public let kind: Kind
    public let bit: Int

    public var id: String { code }

    public var explanation: String {
        switch code {
        case "EC01", "EC02", "EC03":
            return "Air damper (gate) error. Unplug the breezer for 15 seconds, then switch it on again. If the error remains, contact Tion service with this code."
        case "WS01", "WS03", "WS04":
            return "Intake air is hotter than 50 °C, so the breezer switched to standby. Turn it back on once the warning clears."
        case "WS02", "WS05", "WS06":
            return "Intake air is colder than the permitted minimum, so the breezer switched to standby. Turn it back on once the warning clears."
        default:
            return "Device error. Unplug the breezer for 15 seconds, then switch it on again. If the error remains, contact Tion service with this code."
        }
    }

    public static func decode(_ bits: UInt32) -> [DeviceFault] {
        var faults: [DeviceFault] = []
        for bit in 0...10 where bits & (1 << UInt32(bit)) != 0 {
            faults.append(DeviceFault(code: String(format: "EC%02d", bit + 1), kind: .error, bit: bit))
        }
        for bit in 24...29 where bits & (1 << UInt32(bit)) != 0 {
            faults.append(DeviceFault(code: String(format: "WS%02d", bit - 23), kind: .warning, bit: bit))
        }
        return faults
    }
}

/// Device info response (`0x3331`). The payload has no echoed command id:
/// `[work mode u8][device type u32][firmware u16][hardware u16][reserved]`.
public struct DeviceInfo: Equatable {
    public static let breezer4SType: UInt32 = 0x8003
    /// The Tion app hides timers on older firmware.
    public static let minimumTimerFirmware: UInt16 = 80

    public let workMode: Int
    public let deviceType: UInt32
    public let firmwareVersion: UInt16
    public let hardwareVersion: UInt16

    public init(response: TionPacket) throws {
        let body = response.body
        guard body.count >= 9 else { throw TionProtocolError.payloadTooShort(expected: 9, actual: body.count) }
        workMode = Int(body[0])
        deviceType = body.readLE(UInt32.self, at: 1)
        firmwareVersion = body.readLE(UInt16.self, at: 5)
        hardwareVersion = body.readLE(UInt16.self, at: 7)
    }

    public var isBreezer4S: Bool { deviceType == Self.breezer4SType }
    public var supportsTimers: Bool { firmwareVersion >= Self.minimumTimerFirmware }
    public var firmwareString: String { String(format: "%04X", firmwareVersion) }
    public var hardwareString: String { String(format: "%04X", hardwareVersion) }

    public var workModeName: String {
        switch workMode {
        case 1: return "Normal"
        case 2: return "Firmware update"
        default: return "Mode \(workMode)"
        }
    }
}

/// Turbo mode status (`0x4131`): `[active][seconds left u16][error code]`.
public struct TurboInfo: Equatable {
    public let active: Bool
    public let secondsLeft: Int
    public let errorCode: Int

    public init(response: TionPacket) throws {
        let payload = response.payload
        guard payload.count >= 4 else { throw TionProtocolError.payloadTooShort(expected: 4, actual: payload.count) }
        active = payload[0] == 1
        secondsLeft = Int(payload.readLE(UInt16.self, at: 1))
        errorCode = Int(payload[3])
    }
}

/// Per-slot "active" flags (`0x3531`), one byte per timer slot.
public struct TimersState: Equatable {
    public let active: [Bool]

    public init(response: TionPacket) throws {
        let payload = response.payload
        guard payload.count >= TimerSlot.count else {
            throw TionProtocolError.payloadTooShort(expected: TimerSlot.count, actual: payload.count)
        }
        active = payload.prefix(TimerSlot.count).map { $0 != 0 }
    }
}

/// The breezer's clock counts local wall-clock time as if it were UTC
/// (the Android app adds the time-zone offset before sending, and subtracts it when reading).
public enum DeviceClock {
    public static func deviceValue(for date: Date, timeZone: TimeZone) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down)) + Int64(timeZone.secondsFromGMT(for: date))
    }

    public static func date(fromDeviceValue value: Int64, timeZone: TimeZone, now: Date = Date()) -> Date {
        Date(timeIntervalSince1970: TimeInterval(value - Int64(timeZone.secondsFromGMT(for: now))))
    }

    /// Reads the clock value from a time response (`0x3631`).
    public static func value(from response: TionPacket) throws -> Int64 {
        let payload = response.payload
        guard payload.count >= 8 else { throw TionProtocolError.payloadTooShort(expected: 8, actual: payload.count) }
        return payload.readLE(Int64.self, at: 0)
    }
}

/// Parsed BLE manufacturer data of a Tion device (the format `BleScanService` reads).
public struct TionAdvertisement: Equatable {
    public let productType: UInt16
    /// The device is in pairing mode (blue light flashing).
    public let pairingMode: Bool

    public init?(manufacturerData data: [UInt8]) {
        guard data.count >= 13 else { return nil }
        let known: Set<UInt16> = [0x8003, 0x8004]
        let littleEndian = data.readLE(UInt16.self, at: 8)
        let bigEndian = UInt16(data[8]) << 8 | UInt16(data[9])
        if known.contains(littleEndian) {
            productType = littleEndian
        } else if known.contains(bigEndian) {
            productType = bigEndian
        } else {
            return nil
        }
        pairingMode = data[12] == 1
    }

    public var isBreezer4S: Bool { productType == 0x8003 }
}
