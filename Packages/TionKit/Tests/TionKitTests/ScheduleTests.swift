import XCTest
@testable import TionKit

final class ScheduleTests: XCTestCase {
    /// On 04:00, off 07:00, on 22:00, off 02:00, every day.
    private func exampleSlots() -> [TimerSlot] {
        var slots = (0..<TimerSlot.count).map { TimerSlot.empty(id: $0) }
        slots[0] = TimerSlot(id: 0, days: .everyDay, hour: 4, minute: 0, powerOn: true)
        slots[1] = TimerSlot(id: 1, days: .everyDay, hour: 7, minute: 0, powerOn: false)
        slots[2] = TimerSlot(id: 2, days: .everyDay, hour: 22, minute: 0, powerOn: true)
        slots[3] = TimerSlot(id: 3, days: .everyDay, hour: 2, minute: 0, powerOn: false)
        return slots
    }

    private func segment(_ start: Int, _ end: Int, _ on: Bool?) -> WeekSchedule.Segment {
        WeekSchedule.Segment(startMinute: start, endMinute: end, isOn: on)
    }

    func testExampleScheduleTimeline() {
        let rows = WeekSchedule.dayRows(for: exampleSlots())
        XCTAssertEqual(rows.count, 7)
        let expected = [
            segment(0, 120, true),
            segment(120, 240, false),
            segment(240, 420, true),
            segment(420, 1320, false),
            segment(1320, 1440, true),
        ]
        for row in rows.prefix(6) {
            XCTAssertEqual(row, expected)
        }
        // Nothing runs on Sunday, so Saturday's 22:00 turn-on lasts until Monday 02:00.
        XCTAssertEqual(rows[6], [segment(0, 1440, true)])
    }

    func testEmptyScheduleIsUndecided() {
        let rows = WeekSchedule.dayRows(for: (0..<12).map { TimerSlot.empty(id: $0) })
        XCTAssertEqual(rows[0], [segment(0, 1440, nil)])
    }

    func testStateCarriesOverFromPreviousWeekday() {
        let slots = [
            TimerSlot(id: 0, days: .friday, hour: 23, minute: 0, powerOn: true),
            TimerSlot(id: 1, days: .monday, hour: 8, minute: 30, powerOn: false),
        ]
        let rows = WeekSchedule.dayRows(for: slots)
        XCTAssertEqual(rows[0], [segment(0, 510, true), segment(510, 1440, false)])   // Monday
        XCTAssertEqual(rows[4], [segment(0, 1380, false), segment(1380, 1440, true)])  // Friday
        XCTAssertEqual(rows[5], [segment(0, 1440, true)])                               // Saturday
    }

    func testDisabledSlotsAreIgnored() {
        var slots = exampleSlots()
        slots[2].enabled = false
        slots[3].enabled = false
        XCTAssertEqual(WeekSchedule.dayRows(for: slots)[2], [segment(0, 240, false), segment(240, 420, true), segment(420, 1440, false)])
    }

    func testNextEventWrapsAroundTheWeek() {
        let slots = exampleSlots()
        let sundayLate = 6 * 1440 + 23 * 60
        let next = WeekSchedule.nextEvent(after: sundayLate, slots: slots)
        XCTAssertEqual(next?.minuteOfWeek, 2 * 60)
        XCTAssertEqual(next?.powerOn, false)
        XCTAssertEqual(WeekSchedule.nextEvent(after: 5 * 60, slots: slots)?.minuteOfWeek, 7 * 60)
    }

    func testMinuteOfWeekStartsOnMonday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        // 2026-10-19 was a Monday.
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 4, minute: 30)))
        XCTAssertEqual(WeekSchedule.minuteOfWeek(for: monday, calendar: calendar), 270)
        let sunday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 23, minute: 59)))
        XCTAssertEqual(WeekSchedule.minuteOfWeek(for: sunday, calendar: calendar), 6 * 1440 + 23 * 60 + 59)
    }

    func testConflicts() {
        var slots = exampleSlots()
        slots[4] = TimerSlot(id: 4, days: .monday, hour: 7, minute: 0, powerOn: true)
        XCTAssertEqual(WeekSchedule.conflicts(in: slots), [7 * 60])
        XCTAssertEqual(WeekSchedule.label(forMinuteOfWeek: 7 * 60), "Mon 07:00")
    }

    func testEventsAtTheSameMinuteConflictEvenWithTheSameAction() {
        var slots = exampleSlots()
        slots[4] = TimerSlot(id: 4, days: .tuesday, hour: 4, minute: 0, powerOn: true, fanSpeed: 5)
        XCTAssertEqual(WeekSchedule.conflicts(in: slots), [1440 + 4 * 60])
    }

    func testSundayEventsNeverRun() {
        let slots = [TimerSlot(id: 0, days: .sunday, hour: 9, minute: 0, powerOn: true)]
        XCTAssertTrue(WeekSchedule.events(from: slots).isEmpty)
        XCTAssertEqual(ScheduleRules.sundayOnlyEvents(in: slots).map(\.id), [0])
        XCTAssertTrue(ScheduleRules.sundayOnlyEvents(in: exampleSlots()).isEmpty)
    }

    /// The layout found on a breezer: alternating events in consecutive slots, every day.
    func testLayoutMovesEventsIntoEvenSlotsAndDropsSunday() throws {
        var slots = (0..<TimerSlot.count).map { TimerSlot.empty(id: $0) }
        slots[0] = TimerSlot(id: 0, days: .everyDay, hour: 7, minute: 0, powerOn: false)
        slots[1] = TimerSlot(id: 1, days: .everyDay, hour: 6, minute: 0, powerOn: true)
        slots[2] = TimerSlot(id: 2, days: .everyDay, hour: 5, minute: 0, powerOn: false)
        slots[3] = TimerSlot(id: 3, days: .everyDay, hour: 4, minute: 0, powerOn: true)

        let layout = try XCTUnwrap(ScheduleRules.layout(slots))
        XCTAssertEqual(layout.map(\.id), Array(0..<TimerSlot.count))
        XCTAssertEqual(layout.filter(\.isInUse).map(\.id), [0, 2, 4, 6])
        XCTAssertEqual(layout.filter(\.isInUse).map(\.timeText), ["07:00", "05:00", "06:00", "04:00"])
        XCTAssertTrue(layout.filter(\.isInUse).allSatisfy { $0.days == .mondayToSaturday })
        XCTAssertTrue(layout.enumerated().filter { $0.offset % 2 == 1 }.allSatisfy { !$0.element.isInUse })
        XCTAssertEqual(WeekSchedule.dayRows(for: layout)[0], WeekSchedule.dayRows(for: slots)[0])
    }

    func testLayoutKeepsEventsAlreadyInEvenSlots() throws {
        var slots = (0..<TimerSlot.count).map { TimerSlot.empty(id: $0) }
        slots[4] = TimerSlot(id: 4, days: .weekdays, hour: 4, minute: 0, powerOn: true)
        slots[5] = TimerSlot(id: 5, days: .weekdays, hour: 7, minute: 0, powerOn: false)
        let layout = try XCTUnwrap(ScheduleRules.layout(slots))
        XCTAssertEqual(layout[4], slots[4])
        XCTAssertEqual(layout[0].timeText, "07:00")
        XCTAssertFalse(layout[5].isInUse)
    }

    func testLayoutRejectsMoreThanSixEvents() {
        let slots = (0..<7).map { TimerSlot(id: $0, days: .weekdays, hour: $0, minute: 0, powerOn: $0 % 2 == 0) }
        XCTAssertNil(ScheduleRules.layout(slots))
        XCTAssertNotNil(ScheduleRules.layout(Array(slots.prefix(6))))
    }

    func testClockIsNotSetOnSundays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 3 * 3600))
        let sunday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12)))
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 0, minute: 1)))
        XCTAssertFalse(ScheduleRules.isSafeDayToSetClock(sunday, calendar: calendar))
        XCTAssertTrue(ScheduleRules.isSafeDayToSetClock(monday, calendar: calendar))
    }

    func testDayMaskShiftWrapsSundayToMonday() {
        XCTAssertEqual(DayMask([.sunday, .monday]).shifted(by: 1), [.monday, .tuesday])
        XCTAssertEqual(DayMask.everyDay.shifted(by: 1), .everyDay)
        XCTAssertEqual(DayMask.monday.shifted(by: -1), .sunday)
    }

    func testDayMaskSummary() {
        XCTAssertEqual(DayMask.everyDay.summary, "Every day")
        XCTAssertEqual(DayMask.mondayToSaturday.summary, "Mon–Sat")
        XCTAssertEqual(DayMask.weekdays.summary, "Weekdays")
        XCTAssertEqual(DayMask([.monday, .wednesday]).summary, "Mon, Wed")
        XCTAssertEqual(DayMask().summary, "No days")
    }

    func testTimerSlotRoundTrip() throws {
        let slot = TimerSlot(id: 7, days: [.saturday, .sunday], hour: 9, minute: 45, enabled: true, powerOn: true,
                             soundOn: true, lightOn: false, heaterOn: false, targetTemperature: -3, fanSpeed: 5, recirculation: true)
        XCTAssertEqual(try TimerSlot(data: slot.commandData), slot)
        let response = TionPacket(frameType: FrameType.timerResponse.rawValue, requestId: 0, random: 0, body: [1, 2, 3, 4] + slot.commandData)
        XCTAssertEqual(try TimerSlot(response: response), slot)
    }

    func testEmptyAndClearedSlotsAreUnused() {
        XCTAssertFalse(TimerSlot.empty(id: 3).isInUse)
        XCTAssertFalse(exampleSlots()[1].cleared().isInUse)
        XCTAssertTrue(exampleSlots()[1].isInUse)
    }

    func testBehavesLikeIgnoresSettingsOfTurnOffEvents() {
        let off = TimerSlot(id: 1, days: .everyDay, hour: 7, minute: 0, powerOn: false, fanSpeed: 2)
        var stored = off
        stored.fanSpeed = 5
        stored.heaterOn = true
        XCTAssertTrue(off.behavesLike(stored))
        stored.hour = 8
        XCTAssertFalse(off.behavesLike(stored))
    }

    /// When an even slot fires the firmware writes the previous settings into the odd slot after
    /// it, so an unused odd slot can come back with power on and other values.
    func testBehavesLikeIgnoresSettingsOfUnusedSlots() {
        var overwritten = TimerSlot.empty(id: 3)
        overwritten.powerOn = true
        overwritten.fanSpeed = 5
        overwritten.targetTemperature = 25
        XCTAssertTrue(TimerSlot.empty(id: 3).behavesLike(overwritten))
    }
}
