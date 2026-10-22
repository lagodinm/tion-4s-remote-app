import SwiftUI
import TionKit

struct EventEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var slot: TimerSlot
    let maxFanSpeed: Int
    let heaterInstalled: Bool
    let onSave: (TimerSlot) -> Void

    init(slot: TimerSlot, maxFanSpeed: Int, heaterInstalled: Bool, onSave: @escaping (TimerSlot) -> Void) {
        _slot = State(initialValue: slot)
        self.maxFanSpeed = maxFanSpeed
        self.heaterInstalled = heaterInstalled
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Action", selection: $slot.powerOn) {
                        Text("Turn on").tag(true)
                        Text("Turn off").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                Section("Time") {
                    TimeWheel(hour: $slot.hour, minute: $slot.minute)
                }
                Section("Repeat") {
                    DayPicker(days: $slot.days)
                }
                if slot.powerOn {
                    RunSettingsSection(slot: $slot, maxFanSpeed: maxFanSpeed, heaterInstalled: heaterInstalled)
                }
                Section {
                    Toggle("Enabled", isOn: $slot.enabled)
                    Toggle("Beep", isOn: $slot.soundOn)
                    Toggle("Indicator light", isOn: $slot.lightOn)
                } footer: {
                    Text("Slot \(slot.id + 1) of \(TimerSlot.count) in the breezer.")
                }
            }
            .navigationTitle(slot.powerOn ? "Turn on" : "Turn off")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(slot)
                        dismiss()
                    }
                    .disabled(slot.days.isEmpty)
                }
            }
        }
    }
}

/// Adds a turn-on event and a matching turn-off event.
struct PeriodEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var start: TimerSlot
    @State private var endHour = 7
    @State private var endMinute = 0
    let maxFanSpeed: Int
    let heaterInstalled: Bool
    let onSave: (TimerSlot, Int, Int) -> Void

    init(start: TimerSlot, maxFanSpeed: Int, heaterInstalled: Bool, onSave: @escaping (TimerSlot, Int, Int) -> Void) {
        _start = State(initialValue: start)
        self.maxFanSpeed = maxFanSpeed
        self.heaterInstalled = heaterInstalled
        self.onSave = onSave
    }

    private var crossesMidnight: Bool {
        endHour * 60 + endMinute <= start.minuteOfDay
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Turn on at") {
                    TimeWheel(hour: $start.hour, minute: $start.minute)
                }
                Section {
                    TimeWheel(hour: $endHour, minute: $endMinute)
                } header: {
                    Text("Turn off at")
                } footer: {
                    if crossesMidnight {
                        Text("Ends the next morning: the turn-off event runs on the day after each selected day.")
                    }
                }
                Section("Starting on") {
                    DayPicker(days: $start.days)
                }
                RunSettingsSection(slot: $start, maxFanSpeed: maxFanSpeed, heaterInstalled: heaterInstalled)
            }
            .navigationTitle("On/off period")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onSave(start, endHour, endMinute)
                        dismiss()
                    }
                    .disabled(start.days.isEmpty || (endHour == start.hour && endMinute == start.minute))
                }
            }
        }
    }
}

private struct RunSettingsSection: View {
    @Binding var slot: TimerSlot
    let maxFanSpeed: Int
    let heaterInstalled: Bool

    var body: some View {
        Section("When it turns on") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Fan speed").font(.subheadline)
                Picker("Fan speed", selection: $slot.fanSpeed) {
                    ForEach(1...Swift.max(1, maxFanSpeed), id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Picker("Air intake", selection: $slot.recirculation) {
                Text("Outside air").tag(false)
                Text("Recirculation").tag(true)
            }
            if heaterInstalled {
                Toggle("Heater", isOn: $slot.heaterOn)
                if slot.heaterOn {
                    Stepper(value: $slot.targetTemperature, in: BreezerSettings.temperatureRange) {
                        LabeledContent("Supply air target", value: "\(slot.targetTemperature) °C")
                    }
                }
            }
        }
    }
}

struct TimeWheel: View {
    @Binding var hour: Int
    @Binding var minute: Int

    var body: some View {
        DatePicker("Time", selection: Binding(
            get: {
                Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                hour = parts.hour ?? 0
                minute = parts.minute ?? 0
            }
        ), displayedComponents: .hourAndMinute)
        .datePickerStyle(.wheel)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }
}

struct DayPicker: View {
    @Binding var days: DayMask

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<7, id: \.self) { index in
                    let selected = days.includes(day: index)
                    Button {
                        if selected {
                            days.remove(.day(index))
                        } else {
                            days.insert(.day(index))
                        }
                    } label: {
                        Text(DayMask.letters[index])
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .background(selected ? Color.accentColor : Color.secondary.opacity(0.15), in: Circle())
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(DayMask.shortNames[index])
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)
            HStack {
                presetButton("Every day", .everyDay)
                presetButton("Weekdays", .weekdays)
                presetButton("Weekends", .weekend)
            }
        }
        .padding(.vertical, 4)
    }

    private func presetButton(_ title: String, _ mask: DayMask) -> some View {
        Button(title) { days = mask }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
    }
}
