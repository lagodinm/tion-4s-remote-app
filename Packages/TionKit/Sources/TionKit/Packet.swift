import Foundation

/// Frame types of the Breezer 4S. On the wire they are little-endian, so `0x3232` is sent as `32 32`
/// and `0x3230` as `30 32`. A response type is the request type with the low byte set to `0x31`.
public enum FrameType: UInt16, CaseIterable {
    case stateSet = 0x3230
    case stateResponse = 0x3231
    case stateRequest = 0x3232
    case deviceInfoResponse = 0x3331
    case deviceInfoRequest = 0x3332
    case timerSet = 0x3430
    case timerResponse = 0x3431
    case timerRequest = 0x3432
    case timersStateResponse = 0x3531
    case timersStateRequest = 0x3532
    case timeSet = 0x3630
    case timeResponse = 0x3631
    case timeRequest = 0x3632
    case turboSet = 0x4130
    case turboResponse = 0x4131
    case turboRequest = 0x4132

    public var name: String {
        switch self {
        case .stateSet: return "set state"
        case .stateResponse: return "state"
        case .stateRequest: return "get state"
        case .deviceInfoResponse: return "device info"
        case .deviceInfoRequest: return "get device info"
        case .timerSet: return "set timer"
        case .timerResponse: return "timer"
        case .timerRequest: return "get timer"
        case .timersStateResponse: return "timers state"
        case .timersStateRequest: return "get timers state"
        case .timeSet: return "set clock"
        case .timeResponse: return "clock"
        case .timeRequest: return "get clock"
        case .turboSet: return "set turbo"
        case .turboResponse: return "turbo"
        case .turboRequest: return "get turbo"
        }
    }

    public static func name(of rawValue: UInt16) -> String {
        FrameType(rawValue: rawValue)?.name ?? String(format: "frame 0x%04X", rawValue)
    }
}

/// One packet of Tion's "Smarty" BLE protocol, used by the Breezer 4S.
///
/// Layout (multi-byte fields little-endian, checksum big-endian):
///
///     [length u16][0x3A][random u8][frame type u16][request id u32][body ...][CRC-16]
///
/// `length` counts the whole packet including itself and the CRC. For requests the body is
/// `[command id u32][command data]` (device-info requests have no command id). Responses echo
/// the command id at the start of the body, followed by the payload.
public struct TionPacket: Equatable {
    public static let magic: UInt8 = 0x3A
    public static let headerLength = 10
    public static let minimumLength = headerLength + 2

    public var frameType: UInt16
    public var requestId: UInt32
    public var random: UInt8
    public var body: [UInt8]
    /// False when a received packet's checksum didn't match. Encoded packets always carry a valid one.
    public var checksumValid: Bool

    public init(frameType: UInt16, requestId: UInt32, random: UInt8, body: [UInt8], checksumValid: Bool = true) {
        self.frameType = frameType
        self.requestId = requestId
        self.random = random
        self.body = body
        self.checksumValid = checksumValid
    }

    /// The body without the 4-byte echoed command id that starts every response except device info.
    public var payload: [UInt8] {
        body.count > 4 ? Array(body[4...]) : []
    }

    public func encoded() -> [UInt8] {
        let length = Self.headerLength + body.count + 2
        var bytes: [UInt8] = []
        bytes.reserveCapacity(length)
        bytes += UInt16(length).littleEndianBytes
        bytes.append(Self.magic)
        bytes.append(random)
        bytes += frameType.littleEndianBytes
        bytes += requestId.littleEndianBytes
        bytes += body
        let crc = CRC16.ccittFalse(bytes)
        bytes.append(UInt8(crc >> 8))
        bytes.append(UInt8(crc & 0xFF))
        return bytes
    }

    public static func decode(_ bytes: [UInt8]) throws -> TionPacket {
        guard bytes.count >= minimumLength else { throw TionProtocolError.packetTooShort(bytes.count) }
        guard bytes[2] == magic else { throw TionProtocolError.badMagic(bytes[2]) }
        let length = Int(bytes.readLE(UInt16.self, at: 0))
        guard length >= minimumLength, length <= bytes.count else {
            throw TionProtocolError.badLength(declared: length, actual: bytes.count)
        }
        let packet = Array(bytes[0..<length])
        let received = UInt16(packet[length - 2]) << 8 | UInt16(packet[length - 1])
        let computed = CRC16.ccittFalse(packet[0..<(length - 2)])
        return TionPacket(
            frameType: packet.readLE(UInt16.self, at: 4),
            requestId: packet.readLE(UInt32.self, at: 6),
            random: packet[3],
            body: Array(packet[headerLength..<(length - 2)]),
            checksumValid: received == computed
        )
    }
}

/// Splits packets into BLE writes and reassembles notifications, like the Android app does.
///
/// A packet of up to 20 bytes is sent as one frame prefixed with `0x80`. Longer packets go in
/// 19-byte chunks prefixed `0x00` (first), `0x40` (middle) and `0xC0` (last).
public enum TionFraming {
    public static let maxSinglePacket = 20
    public static let chunkSize = 19
    public static let singlePrefix: UInt8 = 0x80
    public static let firstPrefix: UInt8 = 0x00
    public static let middlePrefix: UInt8 = 0x40
    public static let lastPrefix: UInt8 = 0xC0

    public static func frames(for packet: [UInt8]) -> [[UInt8]] {
        if packet.count <= maxSinglePacket {
            return [[singlePrefix] + packet]
        }
        var frames: [[UInt8]] = []
        var offset = 0
        while offset < packet.count {
            let end = Swift.min(offset + chunkSize, packet.count)
            let prefix: UInt8 = offset == 0 ? firstPrefix : (end == packet.count ? lastPrefix : middlePrefix)
            frames.append([prefix] + packet[offset..<end])
            offset = end
        }
        return frames
    }
}

public struct FrameAssembler {
    private var buffer: [UInt8]?

    public init() {}

    public mutating func reset() {
        buffer = nil
    }

    /// Feeds one notification. Returns the packet bytes once the last frame of a packet has arrived.
    public mutating func append(_ frame: [UInt8]) -> [UInt8]? {
        guard let prefix = frame.first else { return nil }
        let data = Array(frame.dropFirst())
        switch prefix {
        case TionFraming.singlePrefix:
            buffer = nil
            return data
        case TionFraming.firstPrefix:
            buffer = data
            return nil
        case TionFraming.lastPrefix:
            guard let started = buffer else { return nil }
            buffer = nil
            return started + data
        default:
            buffer?.append(contentsOf: data)
            return nil
        }
    }
}
