/// A command for the breezer plus how to recognise its reply.
public struct TionRequest: Equatable {
    public enum Reply: Equatable {
        /// Nothing comes back; the request is done once written.
        case noReply
        /// A reply of this frame type may come back; it's fine if it doesn't.
        case maybe(UInt16)
        /// A reply of this frame type must come back.
        case required(UInt16)
    }

    public let frameType: UInt16
    /// Echoed by the breezer at the start of the reply. Device-info requests have none.
    public let commandId: UInt32?
    public let data: [UInt8]
    public let reply: Reply
    /// For timer replies: the slot the reply must be about.
    public let timerId: Int?

    public init(frameType: FrameType, commandId: UInt32?, data: [UInt8] = [], reply: Reply, timerId: Int? = nil) {
        self.frameType = frameType.rawValue
        self.commandId = commandId
        self.data = data
        self.reply = reply
        self.timerId = timerId
    }

    public var name: String { FrameType.name(of: frameType) }

    /// Seconds to wait for the reply.
    public var timeout: Double {
        switch reply {
        case .noReply: return 3
        case .maybe: return 1
        case .required: return 3
        }
    }

    public func packet(requestId: UInt32, random: UInt8) -> TionPacket {
        var body: [UInt8] = []
        if let commandId {
            body += commandId.littleEndianBytes
        }
        body += data
        return TionPacket(frameType: frameType, requestId: requestId, random: random, body: body)
    }

    public func isReply(_ packet: TionPacket) -> Bool {
        let expected: UInt16
        switch reply {
        case .noReply:
            return false
        case .maybe(let type), .required(let type):
            expected = type
        }
        guard packet.frameType == expected else { return false }
        if let timerId {
            let payload = packet.payload
            return !payload.isEmpty && Int(payload[0]) == timerId
        }
        return true
    }

    public static func randomId() -> UInt32 {
        UInt32.random(in: UInt32.min...UInt32.max)
    }
}

extension TionRequest {
    public static func requestState(commandId: UInt32 = randomId()) -> TionRequest {
        TionRequest(frameType: .stateRequest, commandId: commandId, reply: .required(FrameType.stateResponse.rawValue))
    }

    public static func setState(_ settings: BreezerSettings, resetFilter: Bool = false, resetErrors: Bool = false, commandId: UInt32 = randomId()) -> TionRequest {
        TionRequest(
            frameType: .stateSet,
            commandId: commandId,
            data: settings.commandData(resetFilter: resetFilter, resetErrors: resetErrors),
            reply: .required(FrameType.stateResponse.rawValue)
        )
    }

    public static func requestDeviceInfo() -> TionRequest {
        TionRequest(frameType: .deviceInfoRequest, commandId: nil, reply: .required(FrameType.deviceInfoResponse.rawValue))
    }

    public static func requestTimer(id: Int, commandId: UInt32 = randomId()) -> TionRequest {
        TionRequest(frameType: .timerRequest, commandId: commandId, data: [UInt8(clamping: id)], reply: .required(FrameType.timerResponse.rawValue), timerId: id)
    }

    public static func setTimer(_ slot: TimerSlot, commandId: UInt32 = randomId()) -> TionRequest {
        TionRequest(frameType: .timerSet, commandId: commandId, data: slot.commandData, reply: .maybe(FrameType.timerResponse.rawValue), timerId: slot.id)
    }

    public static func requestTimersState(commandId: UInt32 = randomId()) -> TionRequest {
        TionRequest(frameType: .timersStateRequest, commandId: commandId, reply: .required(FrameType.timersStateResponse.rawValue))
    }

    public static func requestTime(commandId: UInt32 = randomId()) -> TionRequest {
        TionRequest(frameType: .timeRequest, commandId: commandId, reply: .required(FrameType.timeResponse.rawValue))
    }

    /// `deviceValue` comes from `DeviceClock.deviceValue(for:timeZone:)`. The Android app sends it in a
    /// 20-byte block: 8 bytes little-endian followed by zeros.
    public static func setTime(_ deviceValue: Int64, commandId: UInt32 = randomId()) -> TionRequest {
        var data = deviceValue.littleEndianBytes
        data += [UInt8](repeating: 0, count: 12)
        return TionRequest(frameType: .timeSet, commandId: commandId, data: data, reply: .maybe(FrameType.timeResponse.rawValue))
    }

    public static func requestTurbo(commandId: UInt32 = randomId()) -> TionRequest {
        TionRequest(frameType: .turboRequest, commandId: commandId, reply: .required(FrameType.turboResponse.rawValue))
    }

    /// Starts turbo for `seconds` (0 stops it), as the Tion Remote app does:
    /// a 20-byte block with the period as u32 little-endian and 1 at byte 5.
    public static func setTurbo(seconds: Int, commandId: UInt32 = randomId()) -> TionRequest {
        var data = UInt32(clamping: seconds).littleEndianBytes
        data += [0, 1]
        data += [UInt8](repeating: 0, count: 14)
        return TionRequest(frameType: .turboSet, commandId: commandId, data: data, reply: .maybe(FrameType.turboResponse.rawValue))
    }
}
