import Foundation

/// Days of the week as the breezer stores them: bit 0 = Monday … bit 6 = Sunday.
public struct DayMask: OptionSet, Hashable, Codable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue & 0x7F
    }

    public static let monday = DayMask(rawValue: 1 << 0)
    public static let tuesday = DayMask(rawValue: 1 << 1)
    public static let wednesday = DayMask(rawValue: 1 << 2)
    public static let thursday = DayMask(rawValue: 1 << 3)
    public static let friday = DayMask(rawValue: 1 << 4)
    public static let saturday = DayMask(rawValue: 1 << 5)
    public static let sunday = DayMask(rawValue: 1 << 6)

    public static let weekdays: DayMask = [.monday, .tuesday, .wednesday, .thursday, .friday]
    public static let weekend: DayMask = [.saturday, .sunday]
    public static let everyDay = DayMask(rawValue: 0x7F)
    public static let mondayToSaturday: DayMask = [.weekdays, .saturday]

    public static let shortNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    public static let letters = ["M", "T", "W", "T", "F", "S", "S"]

    /// `index` 0 = Monday … 6 = Sunday.
    public static func day(_ index: Int) -> DayMask {
        DayMask(rawValue: 1 << UInt8(index))
    }

    public func includes(day index: Int) -> Bool {
        rawValue & (1 << UInt8(index)) != 0
    }

    /// Moves every day forward (positive) or back (negative), wrapping around the week.
    public func shifted(by days: Int) -> DayMask {
        var result: UInt8 = 0
        for index in 0..<7 where includes(day: index) {
            let target = ((index + days) % 7 + 7) % 7
            result |= 1 << UInt8(target)
        }
        return DayMask(rawValue: result)
    }

    public var summary: String {
        if isEmpty { return "No days" }
        switch self {
        case .everyDay: return "Every day"
        case .mondayToSaturday: return "Mon–Sat"
        case .weekdays: return "Weekdays"
        case .weekend: return "Weekends"
        default: return (0..<7).filter { includes(day: $0) }.map { Self.shortNames[$0] }.joined(separator: ", ")
        }
    }
}

/// One of the 12 timer slots stored on the Breezer 4S.
///
/// At the scheduled time on each selected day the breezer applies the slot's settings: it turns
/// on (with the stored fan speed, heater and intake) or turns off. Command data, as the Tion Remote
/// app sends it: `[id][days][hour][minute][flags][target °C][fan speed][intake]`.
/// Flags: bit0 power, bit1 sound, bit2 light, bit3 heater off, bit4 slot enabled.
public struct TimerSlot: Equatable, Hashable, Codable, Identifiable {
    public static let count = 12

    public var id: Int
    public var days: DayMask
    public var hour: Int
    public var minute: Int
    public var enabled: Bool
    public var powerOn: Bool
    public var soundOn: Bool
    public var lightOn: Bool
    public var heaterOn: Bool
    public var targetTemperature: Int
    public var fanSpeed: Int
    public var recirculation: Bool

    public init(
        id: Int,
        days: DayMask = .everyDay,
        hour: Int = 0,
        minute: Int = 0,
        enabled: Bool = true,
        powerOn: Bool = true,
        soundOn: Bool = false,
        lightOn: Bool = true,
        heaterOn: Bool = false,
        targetTemperature: Int = 18,
        fanSpeed: Int = 2,
        recirculation: Bool = false
    ) {
        self.id = id
        self.days = days
        self.hour = hour
        self.minute = minute
        self.enabled = enabled
        self.powerOn = powerOn
        self.soundOn = soundOn
        self.lightOn = lightOn
        self.heaterOn = heaterOn
        self.targetTemperature = targetTemperature
        self.fanSpeed = fanSpeed
        self.recirculation = recirculation
    }

    /// Parses the 8 bytes `[id][days][hour][minute][flags][target][fan][intake]`.
    public init(data: [UInt8]) throws {
        guard data.count >= 8 else { throw TionProtocolError.payloadTooShort(expected: 8, actual: data.count) }
        let flags = data[4]
        self.init(
            id: Int(data[0]),
            days: DayMask(rawValue: data[1]),
            hour: Int(data[2]),
            minute: Int(data[3]),
            enabled: flags & (1 << 4) != 0,
            powerOn: flags & (1 << 0) != 0,
            soundOn: flags & (1 << 1) != 0,
            lightOn: flags & (1 << 2) != 0,
            heaterOn: flags & (1 << 3) == 0,
            targetTemperature: Int(Int8(bitPattern: data[5])),
            fanSpeed: Int(data[6]),
            recirculation: data[7] != 0
        )
    }

    /// Parses a timer response (`0x3431`).
    public init(response: TionPacket) throws {
        try self.init(data: response.payload)
    }

    /// An unused slot, as the Android app writes when a timer is deleted.
    public static func empty(id: Int) -> TimerSlot {
        TimerSlot(id: id, days: [], hour: 0, minute: 0, enabled: false, powerOn: false)
    }

    public var commandData: [UInt8] {
        var flags: UInt8 = 0
        if powerOn { flags |= 1 << 0 }
        if soundOn { flags |= 1 << 1 }
        if lightOn { flags |= 1 << 2 }
        if !heaterOn { flags |= 1 << 3 }
        if enabled { flags |= 1 << 4 }
        var data: [UInt8] = [UInt8(clamping: id), days.rawValue, UInt8(clamping: hour), UInt8(clamping: minute), flags]
        data.append(UInt8(bitPattern: Int8(clamping: targetTemperature)))
        data.append(UInt8(clamping: fanSpeed))
        data.append(recirculation ? 1 : 0)
        return data
    }

    /// The slot holds an event (same rule the Android app uses).
    public var isInUse: Bool {
        !days.isEmpty || enabled || hour != 0 || minute != 0
    }

    /// The slot will fire on at least one day.
    public var isActive: Bool {
        enabled && !days.isEmpty
    }

    public var minuteOfDay: Int { hour * 60 + minute }

    public var timeText: String { String(format: "%02d:%02d", hour, minute) }

    /// The same slot, emptied: no days, 00:00, disabled. Other settings are kept, like the Android app does.
    public func cleared() -> TimerSlot {
        var slot = self
        slot.days = []
        slot.hour = 0
        slot.minute = 0
        slot.enabled = false
        return slot
    }

    /// Compares only what changes the breezer's behaviour, ignoring settings that don't apply:
    /// anything in a slot that never fires, and everything but power in a turn-off event (the
    /// firmware overwrites those with the current settings when it fires).
    public func behavesLike(_ other: TimerSlot) -> Bool {
        guard id == other.id, enabled == other.enabled, days == other.days,
              hour == other.hour, minute == other.minute else { return false }
        guard isActive else { return true }
        guard powerOn == other.powerOn else { return false }
        guard powerOn else { return true }
        return fanSpeed == other.fanSpeed && heaterOn == other.heaterOn
            && targetTemperature == other.targetTemperature && recirculation == other.recirculation
            && soundOn == other.soundOn && lightOn == other.lightOn
    }
}

/// Turns timer slots into a weekly picture of when the breezer runs.
public enum WeekSchedule {
    public static let minutesPerDay = 1440
    public static let minutesPerWeek = 7 * 1440

    public struct Event: Equatable {
        public let slotId: Int
        /// 0 = Monday 00:00.
        public let minuteOfWeek: Int
        public let powerOn: Bool
    }

    public struct Segment: Equatable {
        public let startMinute: Int
        public let endMinute: Int
        /// `nil` when nothing in the schedule decides the state.
        public let isOn: Bool?

        public init(startMinute: Int, endMinute: Int, isOn: Bool?) {
            self.startMinute = startMinute
            self.endMinute = endMinute
            self.isOn = isOn
        }
    }

    /// The moments the breezer actually acts on. Sunday occurrences are left out: the firmware
    /// never runs them (see `ScheduleRules.runnableDays`).
    public static func events(from slots: [TimerSlot]) -> [Event] {
        var events: [Event] = []
        for slot in slots where slot.isActive {
            for day in 0..<7 where slot.days.intersection(ScheduleRules.runnableDays).includes(day: day) {
                events.append(Event(slotId: slot.id, minuteOfWeek: day * minutesPerDay + slot.minuteOfDay, powerOn: slot.powerOn))
            }
        }
        return events.sorted { ($0.minuteOfWeek, $0.slotId) < ($1.minuteOfWeek, $1.slotId) }
    }

    /// Seven rows (Monday first) of on/off segments covering each whole day. The state carries
    /// over from the previous event, wrapping from the end of the week to the start.
    public static func dayRows(for slots: [TimerSlot]) -> [[Segment]] {
        let allEvents = events(from: slots)
        return (0..<7).map { segments(day: $0, events: allEvents) }
    }

    static func segments(day: Int, events: [Event]) -> [Segment] {
        guard let lastOfWeek = events.last else {
            return [Segment(startMinute: 0, endMinute: minutesPerDay, isOn: nil)]
        }
        let dayStart = day * minutesPerDay
        let dayEnd = dayStart + minutesPerDay
        var current = (events.last { $0.minuteOfWeek <= dayStart } ?? lastOfWeek).powerOn
        var cursor = dayStart
        var result: [Segment] = []
        for event in events where event.minuteOfWeek > dayStart && event.minuteOfWeek < dayEnd {
            if event.minuteOfWeek > cursor {
                result.append(Segment(startMinute: cursor - dayStart, endMinute: event.minuteOfWeek - dayStart, isOn: current))
                cursor = event.minuteOfWeek
            }
            current = event.powerOn
        }
        result.append(Segment(startMinute: cursor - dayStart, endMinute: minutesPerDay, isOn: current))
        return merged(result)
    }

    static func merged(_ segments: [Segment]) -> [Segment] {
        var result: [Segment] = []
        for segment in segments {
            if let last = result.last, last.isOn == segment.isOn, last.endMinute == segment.startMinute {
                result[result.count - 1] = Segment(startMinute: last.startMinute, endMinute: segment.endMinute, isOn: last.isOn)
            } else {
                result.append(segment)
            }
        }
        return result
    }

    /// The next event strictly after `minuteOfWeek`, wrapping to next week.
    public static func nextEvent(after minuteOfWeek: Int, slots: [TimerSlot]) -> Event? {
        let allEvents = events(from: slots)
        return allEvents.first { $0.minuteOfWeek > minuteOfWeek } ?? allEvents.first
    }

    /// Minutes since Monday 00:00 for `date` in the calendar's time zone.
    public static func minuteOfWeek(for date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        let dayIndex = ((parts.weekday ?? 2) + 5) % 7
        return dayIndex * minutesPerDay + (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// Minutes of the week where more than one event is due. The firmware runs only the one in the
    /// lowest slot and skips the others.
    public static func conflicts(in slots: [TimerSlot]) -> [Int] {
        var counts: [Int: Int] = [:]
        for event in events(from: slots) {
            counts[event.minuteOfWeek, default: 0] += 1
        }
        return counts.filter { $0.value > 1 }.keys.sorted()
    }

    /// "Tue 07:00" for a minute of the week.
    public static func label(forMinuteOfWeek minute: Int) -> String {
        let day = (minute / minutesPerDay) % 7
        let inDay = minute % minutesPerDay
        return DayMask.shortNames[day] + " " + String(format: "%02d:%02d", inDay / 60, inDay % 60)
    }
}

/// How the Breezer 4S firmware actually runs its timer slots, and the layout the app writes so
/// that every event runs.
///
/// - Slots work in pairs (0, 1), (2, 3) … When an even slot fires, the firmware overwrites the odd
///   slot after it with the settings from just before, and an odd slot only fires if nothing has
///   changed since its even partner ran. So each event gets an even slot of its own and odd slots
///   stay empty: at most 6 events.
/// - The breezer's clock chip numbers weekdays 0–6, but the firmware stores Sunday as 7 and can't
///   handle 0. Nothing runs on Sundays, and an event due on a Sunday stalls the whole schedule
///   until the clock is next set. So events never include Sunday.
/// - When several events are due in the same minute, only the one in the lowest slot runs.
/// - An event fires once, at the start of its minute. A missed minute isn't caught up.
public enum ScheduleRules {
    public static let eventSlotIds = Array(stride(from: 0, to: TimerSlot.count, by: 2))
    public static var maxEvents: Int { eventSlotIds.count }
    public static let runnableDays = DayMask.mondayToSaturday

    public static func eventCount(in slots: [TimerSlot]) -> Int {
        slots.filter(\.isInUse).count
    }

    /// Events that are only set for Sunday, so would never run.
    public static func sundayOnlyEvents(in slots: [TimerSlot]) -> [TimerSlot] {
        slots.filter { $0.isInUse && !$0.days.isEmpty && $0.days.isDisjoint(with: runnableDays) }
    }

    /// The 12 slots to write for `slots`: every event in an even slot (events already in one keep
    /// it), without Sunday, and every odd slot empty. `nil` if there are more than `maxEvents` events.
    public static func layout(_ slots: [TimerSlot]) -> [TimerSlot]? {
        let events = slots.filter(\.isInUse).sorted { $0.id < $1.id }
        guard events.count <= maxEvents else { return nil }
        var freeIds = eventSlotIds.filter { id in !events.contains { $0.id == id } }
        var result = (0..<TimerSlot.count).map { TimerSlot.empty(id: $0) }
        for var event in events {
            if !eventSlotIds.contains(event.id) {
                event.id = freeIds.removeFirst()
            }
            event.days.remove(.sunday)
            result[event.id] = event
        }
        return result
    }

    /// The breezer has to be told the time on a weekday other than Sunday: set on a Sunday, its
    /// clock chip goes on to report Monday as the invalid day 0, so Monday's events are skipped
    /// and later days run a day late until the clock is set again.
    public static func isSafeDayToSetClock(_ date: Date, calendar: Calendar = .current) -> Bool {
        calendar.component(.weekday, from: date) != 1
    }
}
