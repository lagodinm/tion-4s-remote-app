import SwiftUI
import TionKit

struct ScheduleView: View {
    @EnvironmentObject private var store: BreezerStore
    @EnvironmentObject private var link: BreezerLink
    @State private var editing: TimerSlot?
    @State private var addingPeriod: TimerSlot?
    @State private var noFreeSlots = false

    private var events: [TimerSlot] {
        store.draftSlots.filter(\.isInUse).sorted { ($0.minuteOfDay, $0.id) < ($1.minuteOfDay, $1.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ConnectionBanner()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    Text("Events are stored in the breezer itself, up to \(ScheduleRules.maxEvents), so it follows the schedule even when your phone is off or away. Timers never run on Sundays: that's a limit of the Breezer 4S firmware.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    clockRow
                }

                if !store.timersSupported {
                    Section {
                        Label("This breezer's firmware is too old for schedules. Update it with the Tion Remote app first.",
                              systemImage: "exclamationmark.triangle")
                    }
                } else if store.deviceSlots == nil {
                    Section {
                        if link.status.isReady {
                            Button("Read schedule from breezer") { Task { await store.loadSchedule() } }
                        } else {
                            Text("Connect to the breezer to see its schedule.").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section("Week") {
                        WeekTimelineView(rows: WeekSchedule.dayRows(for: store.draftSlots))
                            .padding(.vertical, 4)
                    }

                    let problems = store.scheduleProblems
                    if !problems.isEmpty {
                        Section {
                            ForEach(problems, id: \.self) { problem in
                                Label(problem, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.footnote)
                            }
                        }
                    } else if store.breezerScheduleNeedsRewrite {
                        Section {
                            Label("The schedule stored in the breezer is laid out in a way its firmware can't run reliably. Tap Save to rewrite it.",
                                  systemImage: "arrow.triangle.2.circlepath")
                                .font(.footnote)
                        }
                    }

                    Section {
                        if events.isEmpty {
                            Text("No events yet. Tap + to add one.").foregroundStyle(.secondary)
                        }
                        ForEach(events) { slot in
                            EventRow(slot: slot) { enabled in
                                var updated = slot
                                updated.enabled = enabled
                                store.upsert(updated)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { editing = slot }
                            .swipeActions {
                                Button("Delete", role: .destructive) { store.removeEvent(id: slot.id) }
                            }
                        }
                    } header: {
                        Text("Events · \(events.count) of \(ScheduleRules.maxEvents)")
                    } footer: {
                        Text("Tap an event to edit it, swipe left to delete. Changes are sent when you tap Save.")
                    }
                }
            }
            .navigationTitle("Schedule")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            add(powerOn: true)
                        } label: {
                            Label("Turn-on event", systemImage: "power")
                        }
                        Button {
                            add(powerOn: false)
                        } label: {
                            Label("Turn-off event", systemImage: "moon.zzz")
                        }
                        Button {
                            addPeriod()
                        } label: {
                            Label("On/off period…", systemImage: "clock.arrow.2.circlepath")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(store.deviceSlots == nil)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await store.loadSchedule(discardChanges: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!link.status.isReady || store.scheduleActivity != nil)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if store.hasUnsavedScheduleChanges {
                    saveBar
                }
            }
            .overlay {
                if let activity = store.scheduleActivity {
                    ProgressView(activity)
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .refreshable { await store.loadSchedule() }
            .sheet(item: $editing) { slot in
                EventEditorView(slot: slot, maxFanSpeed: store.state?.maxFanSpeed ?? 6,
                                heaterInstalled: store.state?.heaterInstalled ?? true) { store.upsert($0) }
            }
            .sheet(item: $addingPeriod) { start in
                PeriodEditorView(start: start, maxFanSpeed: store.state?.maxFanSpeed ?? 6,
                                 heaterInstalled: store.state?.heaterInstalled ?? true) { start, endHour, endMinute in
                    _ = store.addPeriod(start: start, endHour: endHour, endMinute: endMinute)
                }
            }
            .alert("Schedule", isPresented: Binding(get: { store.scheduleMessage != nil }, set: { if !$0 { store.scheduleMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.scheduleMessage ?? "")
            }
            .alert("No room for more events", isPresented: $noFreeSlots) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The breezer can run \(ScheduleRules.maxEvents) events, and a period needs two. Delete an event to make room.")
            }
        }
    }

    private var clockRow: some View {
        HStack {
            Label("Breezer clock", systemImage: "clock")
            Spacer()
            if let offset = store.clockOffset {
                Text(Format.clockOffset(offset))
                    .foregroundStyle(abs(offset) < 60 ? Color.secondary : Color.orange)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
            Button("Sync") { Task { await store.syncClock() } }
                .buttonStyle(.bordered)
                .disabled(!link.status.isReady)
        }
        .font(.subheadline)
    }

    private var saveBar: some View {
        HStack(spacing: 12) {
            Button("Discard", role: .destructive) { store.discardScheduleChanges() }
                .buttonStyle(.bordered)
            Button {
                Task { await store.saveSchedule() }
            } label: {
                Label("Save to breezer", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!link.status.isReady || store.scheduleActivity != nil || !store.scheduleProblems.isEmpty)
        }
        .padding()
        .background(.bar)
    }

    private func add(powerOn: Bool) {
        guard let slot = store.newEvent(powerOn: powerOn, hour: powerOn ? 22 : 7) else {
            noFreeSlots = true
            return
        }
        editing = slot
    }

    private func addPeriod() {
        guard store.freeEventCount >= 2, let start = store.newEvent(powerOn: true, hour: 22) else {
            noFreeSlots = true
            return
        }
        addingPeriod = start
    }
}

private struct EventRow: View {
    let slot: TimerSlot
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: slot.powerOn ? "power.circle.fill" : "moon.zzz.fill")
                .font(.title2)
                .foregroundStyle(slot.powerOn ? ChartColors.running : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(slot.timeText).font(.title3.weight(.semibold).monospacedDigit())
                    Text(slot.powerOn ? "Turn on" : "Turn off").font(.subheadline)
                }
                Text(slot.days.intersection(ScheduleRules.runnableDays).summary).font(.caption).foregroundStyle(.secondary)
                if slot.powerOn {
                    Text(settingsSummary).font(.caption).foregroundStyle(.secondary)
                }
            }
            .opacity(slot.enabled ? 1 : 0.5)
            Spacer()
            Toggle("Enabled", isOn: Binding(get: { slot.enabled }, set: onToggle))
                .labelsHidden()
        }
        .accessibilityElement(children: .combine)
    }

    private var settingsSummary: String {
        var parts = ["Fan \(slot.fanSpeed)"]
        parts.append(slot.recirculation ? "recirculation" : "outside air")
        if slot.heaterOn && !slot.recirculation {
            parts.append("heater \(slot.targetTemperature)°")
        }
        return parts.joined(separator: " · ")
    }
}

struct WeekTimelineView: View {
    let rows: [[WeekSchedule.Segment]]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<7, id: \.self) { day in
                HStack(spacing: 8) {
                    Text(DayMask.shortNames[day])
                        .font(.caption.monospaced())
                        .frame(width: 34, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.15))
                            ForEach(Array(rows[day].enumerated()), id: \.offset) { _, segment in
                                if segment.isOn == true {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(ChartColors.running)
                                        .frame(width: Swift.max(2, geometry.size.width * CGFloat(segment.endMinute - segment.startMinute) / 1440 - 2))
                                        .offset(x: geometry.size.width * CGFloat(segment.startMinute) / 1440 + 1)
                                }
                            }
                        }
                    }
                    .frame(height: 16)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText(day: day))
            }
            HStack(spacing: 0) {
                Color.clear.frame(width: 42)
                ForEach(["0", "6", "12", "18", "24"], id: \.self) { hour in
                    Text(hour).font(.caption2).foregroundStyle(.secondary)
                    if hour != "24" { Spacer() }
                }
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(ChartColors.running).frame(width: 14, height: 8)
                Text("Breezer on by schedule").font(.caption2).foregroundStyle(.secondary)
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.15)).frame(width: 14, height: 8)
                    .padding(.leading, 8)
                Text("Off").font(.caption2).foregroundStyle(.secondary)
            }
            Text("Sun: timers don't run, so the breezer stays as Saturday's last event left it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func accessibilityText(day: Int) -> String {
        let onRanges = rows[day].filter { $0.isOn == true }.map { segment in
            String(format: "%02d:%02d to %02d:%02d", segment.startMinute / 60, segment.startMinute % 60,
                   segment.endMinute / 60, segment.endMinute % 60)
        }
        let name = DayMask.shortNames[day]
        return onRanges.isEmpty ? "\(name): off" : "\(name): on " + onRanges.joined(separator: ", ")
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
