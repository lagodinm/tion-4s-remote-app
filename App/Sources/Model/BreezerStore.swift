import Foundation
import SwiftUI
import TionKit

@MainActor
final class BreezerStore: ObservableObject {
    let link = BreezerLink()

    @Published private(set) var savedDevice: SavedDevice?
    @Published private(set) var state: BreezerState?
    @Published private(set) var lastUpdated: Date?
    /// Settings the user changed that haven't been confirmed by the breezer yet.
    @Published private(set) var pendingSettings: BreezerSettings?
    @Published private(set) var deviceInfo: DeviceInfo?
    @Published private(set) var turbo: TurboInfo?
    @Published private(set) var turboReadAt: Date?
    /// Breezer clock minus phone clock, in seconds.
    @Published private(set) var clockOffset: TimeInterval?
    @Published private(set) var airflowRate: Double?
    @Published private(set) var history: [HistorySample] = []
    @Published var message: String?

    // Schedule: `deviceSlots` is what the breezer reported last; `draftSlots` is what the user is editing.
    @Published private(set) var deviceSlots: [TimerSlot]?
    @Published var draftSlots: [TimerSlot] = (0..<TimerSlot.count).map { TimerSlot.empty(id: $0) }
    @Published private(set) var timersState: TimersState?
    @Published private(set) var scheduleActivity: String?
    @Published var scheduleMessage: String?

    private var pollTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private var pausePolling = 0
    private var isForeground = true
    private var counterSamples: [(date: Date, state: BreezerState)] = []
    private var lastHistorySave = Date()

    static let pollInterval: Double = 3
    static let historyInterval: TimeInterval = 15

    init() {
        savedDevice = SavedDevice.load()
        history = HistoryStore.load()
        link.onReady = { [weak self] in self?.linkReady() }
        link.onUnsolicitedPacket = { [weak self] packet in self?.handleUnsolicited(packet) }
        if let savedDevice {
            link.connect(to: savedDevice.id)
        }
    }

    // MARK: Device

    func pair(with breezer: DiscoveredBreezer) {
        link.stopScan()
        let device = SavedDevice(id: breezer.id, name: breezer.name)
        savedDevice = device
        SavedDevice.save(device)
        link.connect(to: breezer.id)
    }

    func forgetDevice() {
        pollTask?.cancel()
        settingsTask?.cancel()
        pendingSettings = nil
        link.disconnect()
        SavedDevice.save(nil)
        savedDevice = nil
        state = nil
        lastUpdated = nil
        airflowRate = nil
        counterSamples.removeAll()
        deviceInfo = nil
        turbo = nil
        deviceSlots = nil
        draftSlots = (0..<TimerSlot.count).map { TimerSlot.empty(id: $0) }
        timersState = nil
        clockOffset = nil
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isForeground = true
            if link.status.isReady {
                Task { await refreshState() }
            } else if let savedDevice {
                link.connect(to: savedDevice.id)
            }
        case .background:
            isForeground = false
            HistoryStore.save(history)
        default:
            break
        }
    }

    private func linkReady() {
        Task {
            await refreshState()
            await loadDeviceInfo()
            await checkClock(sync: true)
            await refreshTurbo()
            if deviceInfo?.supportsTimers ?? true {
                await loadSchedule()
            }
            startPolling()
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard let self else { return }
                guard self.link.status.isReady, self.pausePolling == 0, self.isForeground else { continue }
                await self.refreshState()
                tick += 1
                if tick % 10 == 0 {
                    await self.refreshTurbo()
                }
            }
        }
    }

    // MARK: State

    func refreshState() async {
        guard link.status.isReady else { return }
        if let reply = try? await link.send(.requestState()) {
            apply(stateReply: reply)
        }
    }

    private func handleUnsolicited(_ packet: TionPacket) {
        if packet.frameType == FrameType.stateResponse.rawValue {
            apply(stateReply: packet)
        }
    }

    private func apply(stateReply packet: TionPacket) {
        guard packet.frameType == FrameType.stateResponse.rawValue,
              let newState = try? BreezerState(response: packet) else { return }
        state = newState
        lastUpdated = Date()
        updateAirflow(newState)
        recordHistory(newState)
    }

    private func updateAirflow(_ newState: BreezerState) {
        let now = Date()
        counterSamples.append((now, newState))
        counterSamples.removeAll { now.timeIntervalSince($0.date) > 180 }
        if !newState.powerOn {
            airflowRate = 0
        } else if let oldest = counterSamples.first, now.timeIntervalSince(oldest.date) >= 30,
                  let rate = newState.airflowRate(since: oldest.state) {
            airflowRate = rate
        }
    }

    private func recordHistory(_ newState: BreezerState) {
        let now = Date()
        if let last = history.last, now.timeIntervalSince(last.date) < Self.historyInterval { return }
        history.append(HistorySample(
            date: now,
            outdoor: newState.outdoorTemperature,
            supply: newState.supplyTemperature,
            target: newState.targetTemperature,
            fanSpeed: newState.fanSpeed,
            powerOn: newState.powerOn,
            heaterLoad: newState.heaterLoadPercent,
            airflow: airflowRate
        ))
        let cutoff = now.addingTimeInterval(-HistoryStore.maxAge)
        if let first = history.first, first.date < cutoff {
            history.removeAll { $0.date < cutoff }
        }
        if now.timeIntervalSince(lastHistorySave) > 300 {
            lastHistorySave = now
            HistoryStore.save(history)
        }
    }

    // MARK: Control

    /// The settings shown in the controls: pending edits first, otherwise the breezer's state.
    var settings: BreezerSettings? {
        pendingSettings ?? state.map(BreezerSettings.init(state:))
    }

    /// Applies a change locally right away and sends it after a short pause, so a burst of taps becomes one command.
    func change(_ edit: (inout BreezerSettings) -> Void) {
        guard var updated = settings else { return }
        edit(&updated)
        pendingSettings = updated
        settingsTask?.cancel()
        settingsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.sendSettings()
        }
    }

    private func sendSettings(resetFilter: Bool = false, resetErrors: Bool = false) async {
        guard let sent = settings else { return }
        do {
            if let reply = try await link.send(.setState(sent, resetFilter: resetFilter, resetErrors: resetErrors)) {
                apply(stateReply: reply)
            }
            if pendingSettings == sent {
                pendingSettings = nil
            }
        } catch {
            pendingSettings = nil
            message = "Couldn't change the setting: \(error.localizedDescription)"
        }
    }

    func resetFilterCounter() async {
        await sendSettings(resetFilter: true)
    }

    func resetErrors() async {
        await sendSettings(resetErrors: true)
    }

    func refreshTurbo() async {
        guard link.status.isReady else { return }
        if let reply = try? await link.send(.requestTurbo()), let info = try? TurboInfo(response: reply) {
            turbo = info
            turboReadAt = Date()
        }
    }

    func setTurbo(minutes: Int) async {
        do {
            try await link.send(.setTurbo(seconds: minutes * 60))
        } catch {
            message = "Couldn't change turbo: \(error.localizedDescription)"
        }
        try? await Task.sleep(for: .milliseconds(300))
        await refreshTurbo()
        await refreshState()
    }

    // MARK: Device info and clock

    func loadDeviceInfo() async {
        if let reply = try? await link.send(.requestDeviceInfo()), let info = try? DeviceInfo(response: reply) {
            deviceInfo = info
        }
    }

    /// Reads the breezer's clock. With `sync` it also sets it, even when it's right: setting the
    /// clock makes the breezer plan its next timer again, which restarts a schedule the firmware
    /// has stalled (see `ScheduleRules`). Never on a Sunday.
    func checkClock(sync: Bool) async {
        guard let reply = try? await link.send(.requestTime()),
              let value = try? DeviceClock.value(from: reply) else { return }
        let now = Date()
        let offset = DeviceClock.date(fromDeviceValue: value, timeZone: .current, now: now).timeIntervalSince(now)
        clockOffset = offset
        guard sync else { return }
        if ScheduleRules.isSafeDayToSetClock(now) {
            link.addLog(.info, "Setting the breezer clock (it was off by \(Int(offset)) s)")
            await setClock()
        } else {
            link.addLog(.info, "Not setting the breezer clock on a Sunday (it's off by \(Int(offset)) s)")
        }
    }

    /// The Sync button.
    func syncClock() async {
        guard ScheduleRules.isSafeDayToSetClock(Date()) else {
            message = "The breezer can't take the time on a Sunday: its firmware would then skip Monday's events. The app sets the clock automatically when it connects on any other day."
            return
        }
        await setClock()
    }

    private func setClock() async {
        do {
            try await link.send(.setTime(DeviceClock.deviceValue(for: Date(), timeZone: .current)))
        } catch {
            message = "Couldn't set the breezer's clock: \(error.localizedDescription)"
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        await checkClock(sync: false)
    }

    // MARK: Schedule

    /// True when saving would change what the breezer does: the user edited events, or the slots
    /// on the breezer aren't laid out the way its firmware needs (see `ScheduleRules`).
    var hasUnsavedScheduleChanges: Bool {
        guard let deviceSlots else { return false }
        guard let planned = ScheduleRules.layout(draftSlots) else { return true }
        return zip(planned, deviceSlots).contains { !$0.behavesLike($1) }
    }

    /// The breezer holds a schedule its firmware can't run as shown, so it needs saving again.
    var breezerScheduleNeedsRewrite: Bool {
        guard let deviceSlots else { return false }
        guard let planned = ScheduleRules.layout(deviceSlots) else { return true }
        return zip(planned, deviceSlots).contains { !$0.behavesLike($1) }
    }

    var eventCount: Int { ScheduleRules.eventCount(in: draftSlots) }

    var freeEventCount: Int { Swift.max(0, ScheduleRules.maxEvents - eventCount) }

    /// Why the draft can't be saved yet, as sentences for the user. Empty when it can.
    var scheduleProblems: [String] {
        var problems: [String] = []
        if eventCount > ScheduleRules.maxEvents {
            let extra = eventCount - ScheduleRules.maxEvents
            problems.append("The breezer can run \(ScheduleRules.maxEvents) events. Delete \(extra) to save.")
        }
        let clashes = WeekSchedule.conflicts(in: draftSlots)
        if !clashes.isEmpty {
            problems.append("More than one event at " + clashes.map(WeekSchedule.label(forMinuteOfWeek:)).joined(separator: ", ")
                            + ". The breezer would run only one of them, so change a time.")
        }
        let sundayOnly = ScheduleRules.sundayOnlyEvents(in: draftSlots)
        if !sundayOnly.isEmpty {
            problems.append("Events set only for Sunday never run (" + sundayOnly.map(\.timeText).joined(separator: ", ")
                            + "). Pick other days or delete them.")
        }
        return problems
    }

    var timersSupported: Bool { deviceInfo?.supportsTimers ?? true }

    func loadSchedule(discardChanges: Bool = false) async {
        guard link.status.isReady, scheduleActivity == nil else { return }
        if let deviceInfo, !deviceInfo.supportsTimers {
            scheduleMessage = "This breezer's firmware (\(deviceInfo.firmwareString)) is too old for schedules. Update it with the Tion Remote app."
            return
        }
        scheduleActivity = "Reading the schedule…"
        pausePolling += 1
        defer {
            pausePolling -= 1
            scheduleActivity = nil
        }
        var slots: [TimerSlot] = []
        for id in 0..<TimerSlot.count {
            guard let slot = await readSlot(id) else {
                scheduleMessage = "Couldn't read timer slot \(id + 1). Pull down to try again."
                return
            }
            slots.append(slot)
        }
        let userEdited = deviceSlots.map { $0 != draftSlots } ?? false
        let keepDraft = userEdited && !discardChanges
        deviceSlots = slots
        if !keepDraft {
            draftSlots = slots
        }
        await refreshTimersState()
    }

    private func readSlot(_ id: Int) async -> TimerSlot? {
        for _ in 0..<3 {
            if let reply = try? await link.send(.requestTimer(id: id)),
               let slot = try? TimerSlot(response: reply), slot.id == id {
                return slot
            }
        }
        return nil
    }

    private func refreshTimersState() async {
        if let reply = try? await link.send(.requestTimersState()), let info = try? TimersState(response: reply) {
            timersState = info
        }
    }

    func upsert(_ slot: TimerSlot) {
        guard let index = draftSlots.firstIndex(where: { $0.id == slot.id }) else { return }
        draftSlots[index] = slot
    }

    func removeEvent(id: Int) {
        guard let index = draftSlots.firstIndex(where: { $0.id == id }) else { return }
        draftSlots[index] = draftSlots[index].cleared()
    }

    func discardScheduleChanges() {
        if let deviceSlots {
            draftSlots = deviceSlots
        }
    }

    /// A new event in the first free even slot, pre-filled with the breezer's current settings.
    func newEvent(powerOn: Bool, hour: Int = 8, minute: Int = 0, excluding taken: Set<Int> = []) -> TimerSlot? {
        guard eventCount + taken.count < ScheduleRules.maxEvents,
              let free = draftSlots.first(where: {
                  ScheduleRules.eventSlotIds.contains($0.id) && !$0.isInUse && !taken.contains($0.id)
              }) else { return nil }
        let current = settings
        return TimerSlot(
            id: free.id,
            days: ScheduleRules.runnableDays,
            hour: hour,
            minute: minute,
            enabled: true,
            powerOn: powerOn,
            soundOn: current?.soundOn ?? false,
            lightOn: current?.lightOn ?? true,
            heaterOn: current?.heaterOn ?? false,
            targetTemperature: current?.targetTemperature ?? 18,
            fanSpeed: Swift.max(1, current?.fanSpeed ?? 2),
            recirculation: current?.recirculation ?? false
        )
    }

    /// Adds a turn-on event and a turn-off event. If the period crosses midnight the turn-off
    /// event fires on the following days, except Sunday, when timers don't run.
    func addPeriod(start: TimerSlot, endHour: Int, endMinute: Int) -> Bool {
        guard let endTemplate = newEvent(powerOn: false, hour: endHour, minute: endMinute, excluding: [start.id]) else { return false }
        var end = endTemplate
        let crossesMidnight = endHour * 60 + endMinute <= start.minuteOfDay
        end.days = (crossesMidnight ? start.days.shifted(by: 1) : start.days).intersection(ScheduleRules.runnableDays)
        guard !end.days.isEmpty else { return false }
        end.soundOn = start.soundOn
        end.lightOn = start.lightOn
        upsert(start)
        upsert(end)
        return true
    }

    /// Writes the slots that need to change, in the layout `ScheduleRules` describes, mirroring the
    /// Tion app: set the clock, mute the beeper, write each slot with a pause, restore the previous
    /// settings, then read the slots back to confirm.
    func saveSchedule() async {
        guard let original = deviceSlots, link.status.isReady, scheduleActivity == nil else { return }
        if let problem = scheduleProblems.first {
            scheduleMessage = problem
            return
        }
        guard let planned = ScheduleRules.layout(draftSlots) else { return }
        // Clear odd slots first, so events moving out of them stop before their new slots start.
        let changed = planned
            .filter { slot in !(original.first { $0.id == slot.id }?.behavesLike(slot) ?? false) }
            .sorted { ($0.id % 2 == 1 ? 0 : 1, $0.id) < ($1.id % 2 == 1 ? 0 : 1, $1.id) }
        guard !changed.isEmpty else { return }
        let savedOnSunday = !ScheduleRules.isSafeDayToSetClock(Date())

        pausePolling += 1
        defer {
            pausePolling -= 1
            scheduleActivity = nil
        }

        // Send any control change still waiting out its debounce, so it isn't lost.
        if pendingSettings != nil {
            settingsTask?.cancel()
            await sendSettings()
        }

        // Set the clock even on a Sunday: without it the breezer would plan its next timer from a
        // Sunday clock it can't read, and stop running timers altogether until the clock is set.
        scheduleActivity = "Setting the breezer's clock…"
        try? await link.send(.setTime(DeviceClock.deviceValue(for: Date(), timeZone: .current)))
        try? await Task.sleep(for: .milliseconds(400))

        let previous = settings
        if var muted = previous, muted.soundOn {
            muted.soundOn = false
            try? await link.send(.setState(muted))
            try? await Task.sleep(for: .milliseconds(400))
        }

        var failed: [Int] = []
        for (index, slot) in changed.enumerated() {
            scheduleActivity = "Writing slot \(index + 1) of \(changed.count)…"
            do {
                try await link.send(.setTimer(slot))
            } catch {
                failed.append(slot.id)
            }
            try? await Task.sleep(for: .milliseconds(1000))
        }

        if let previous, previous.soundOn, let reply = try? await link.send(.setState(previous)) {
            apply(stateReply: reply)
        }

        scheduleActivity = "Checking what the breezer stored…"
        var stored = original
        var mismatched: [Int] = []
        for slot in changed {
            guard let readBack = await readSlot(slot.id), let index = stored.firstIndex(where: { $0.id == slot.id }) else {
                mismatched.append(slot.id)
                continue
            }
            stored[index] = readBack
            if !readBack.behavesLike(slot) {
                mismatched.append(slot.id)
            }
        }
        deviceSlots = stored

        let problems = Set(failed + mismatched)
        if problems.isEmpty {
            draftSlots = stored
            scheduleMessage = savedOnSunday
                ? "Saved. Because it's Sunday, the breezer will skip Monday's events unless you open this app on Monday: its firmware mishandles a clock set on a Sunday."
                : "Saved to the breezer. It will follow this schedule even when your phone is away."
        } else {
            // Keep the user's version of the slots that didn't stick so they can try again.
            draftSlots = stored.map { slot in
                problems.contains(slot.id) ? (changed.first { $0.id == slot.id } ?? slot) : slot
            }
            scheduleMessage = "\(problems.count) slot(s) didn't save. Tap Save to try again."
        }
        await refreshTimersState()
        await checkClock(sync: false)
    }
}
