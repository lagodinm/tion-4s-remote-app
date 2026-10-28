import Charts
import SwiftUI
import TionKit

struct DashboardView: View {
    @EnvironmentObject private var store: BreezerStore
    @EnvironmentObject private var link: BreezerLink

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ConnectionBanner()
                    if let state = store.state {
                        PowerHeader(state: state)
                        LazyVGrid(columns: columns, spacing: 12) {
                            readingTiles(state)
                        }
                        TemperatureHistoryCard(samples: store.history)
                        FilterCard(state: state)
                        FaultsCard(state: state)
                        DetailsCard(state: state)
                    } else if link.status.isReady {
                        ProgressView("Reading the breezer…").padding(.top, 40)
                    } else {
                        ContentUnavailableView("No readings yet", systemImage: "wind",
                                               description: Text("Readings appear once the breezer is connected."))
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(store.savedDevice?.name ?? "Breezer")
            .refreshable { await store.refreshState() }
        }
    }

    @ViewBuilder
    private func readingTiles(_ state: BreezerState) -> some View {
        StatTile(title: "Outdoor air", value: Format.temperature(state.outdoorTemperature),
                 detail: "Entering the intake", systemImage: "thermometer.snowflake", tint: ChartColors.outdoor)
        StatTile(title: "Supply air", value: Format.temperature(state.supplyTemperature),
                 detail: "Blowing into the room", systemImage: "wind", tint: ChartColors.supply)
        StatTile(title: "Target", value: Format.temperature(state.targetTemperature),
                 detail: state.heatingEnabled ? "Heater keeps supply air at this" : "Heater off", systemImage: "thermometer.medium")
        StatTile(title: "Fan speed", value: "\(state.fanSpeed) of \(state.maxFanSpeed)",
                 detail: airflowDetail, systemImage: "fan")
        StatTile(title: "Heater", value: heaterValue(state), detail: heaterDetail(state), systemImage: "heater.vertical")
        StatTile(title: "Air intake", value: state.recirculation ? "Recirculation" : "Outside air",
                 detail: state.recirculation ? "Room air, damper closed" : "Fresh air from outside", systemImage: "arrow.triangle.2.circlepath")
    }

    private var airflowDetail: String {
        guard let rate = store.airflowRate else { return "Airflow: measuring…" }
        return "Airflow ≈ \(Int(rate.rounded())) m³/h"
    }

    private func heaterValue(_ state: BreezerState) -> String {
        guard state.heaterInstalled else { return "None" }
        guard state.heatingEnabled else { return "Off" }
        if let watts = state.heaterWatts, state.heaterRunning { return "\(watts) W" }
        return "Standby"
    }

    private func heaterDetail(_ state: BreezerState) -> String {
        guard state.heaterInstalled else { return "No heater fitted" }
        var parts: [String] = []
        if let rated = state.heaterRatedWatts { parts.append("\(rated) W heater") }
        if let load = state.heaterLoadPercent { parts.append("load \(load)%") }
        return parts.joined(separator: " · ")
    }
}

private struct PowerHeader: View {
    @EnvironmentObject private var store: BreezerStore
    let state: BreezerState

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "power.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(state.powerOn ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.powerOn ? "Running" : "Off").font(.title2.weight(.bold))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Power", isOn: Binding(
                get: { store.settings?.powerOn ?? state.powerOn },
                set: { on in store.change { $0.powerOn = on } }
            ))
            .labelsHidden()
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var subtitle: String {
        var parts: [String] = []
        if let next = nextEventText { parts.append(next) }
        if let updated = store.lastUpdated {
            parts.append("Updated \(updated.formatted(date: .omitted, time: .standard))")
        }
        return parts.joined(separator: " · ")
    }

    private var nextEventText: String? {
        guard store.deviceSlots != nil else { return nil }
        let now = WeekSchedule.minuteOfWeek(for: Date())
        guard let next = WeekSchedule.nextEvent(after: now, slots: store.deviceSlots ?? []) else { return nil }
        return "Next: \(next.powerOn ? "on" : "off") \(WeekSchedule.label(forMinuteOfWeek: next.minuteOfWeek))"
    }
}

private struct TemperatureHistoryCard: View {
    let samples: [HistorySample]
    @State private var range: TimeRange = .sixHours
    @State private var selectedDate: Date?

    enum TimeRange: String, CaseIterable, Identifiable {
        case hour = "1 h", sixHours = "6 h", day = "24 h", week = "7 d"
        var id: String { rawValue }
        var seconds: TimeInterval {
            switch self {
            case .hour: return 3600
            case .sixHours: return 6 * 3600
            case .day: return 24 * 3600
            case .week: return 7 * 24 * 3600
            }
        }
    }

    private var visible: [HistorySample] {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        return samples.filter { $0.date >= cutoff }
    }

    private var selected: HistorySample? {
        guard let selectedDate else { return nil }
        return visible.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        Card(title: "Temperatures") {
            Picker("Range", selection: $range) {
                ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if visible.count < 2 {
                Text("History builds up while the app is open — a reading every 15 seconds.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart {
                    ForEach(visible) { sample in
                        LineMark(x: .value("Time", sample.date), y: .value("°C", sample.outdoor),
                                 series: .value("Series", "Outdoor"))
                            .foregroundStyle(by: .value("Series", "Outdoor"))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        LineMark(x: .value("Time", sample.date), y: .value("°C", sample.supply),
                                 series: .value("Series", "Supply"))
                            .foregroundStyle(by: .value("Series", "Supply"))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    if let selected {
                        RuleMark(x: .value("Time", selected.date))
                            .foregroundStyle(Color.secondary.opacity(0.4))
                            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(selected.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Text("Outdoor \(selected.outdoor)° · Supply \(selected.supply)°")
                                        .font(.caption.weight(.semibold))
                                    Text("Fan \(selected.fanSpeed)\(selected.powerOn ? "" : " (off)")")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(6)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                            }
                    }
                }
                .chartForegroundStyleScale(["Outdoor": ChartColors.outdoor, "Supply": ChartColors.supply])
                .chartLegend(position: .top, alignment: .leading)
                .chartYAxisLabel("°C")
                .chartXSelection(value: $selectedDate)
                .frame(height: 220)
                Text("Touch and drag on the chart to read values.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FilterCard: View {
    let state: BreezerState

    var body: some View {
        Card(title: "Filter") {
            Gauge(value: Double(state.filterPercentLeft), in: 0...100) {
                EmptyView()
            } currentValueLabel: {
                Text("\(state.filterPercentLeft)%")
            }
            .gaugeStyle(.linearCapacity)
            .tint(state.filterPercentLeft > 15 ? Color.green : Color.orange)
            HStack {
                Text("\(state.filterDaysLeft) days left of \(BreezerState.filterLifeDays)")
                Spacer()
                if state.filterWarning {
                    Label("Replace soon", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.subheadline)
        }
    }
}

private struct FaultsCard: View {
    let state: BreezerState

    var body: some View {
        Card(title: "Errors and warnings") {
            let faults = state.faults
            if faults.isEmpty {
                Label("None reported", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ForEach(faults) { fault in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(fault.code + (fault.kind == .error ? " · error" : " · warning"),
                              systemImage: fault.kind == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(fault.kind == .error ? Color.red : Color.orange)
                            .font(.subheadline.weight(.semibold))
                        Text(fault.explanation).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct DetailsCard: View {
    @EnvironmentObject private var store: BreezerStore
    let state: BreezerState

    var body: some View {
        Card(title: "Details") {
            VStack(spacing: 8) {
                LabeledContent("Air moved in total", value: Format.cubicMeters(state.totalAirflowCubicMeters))
                LabeledContent("Powered-on time", value: Format.duration(state.poweredOnSeconds))
                LabeledContent("Fan run time", value: Format.duration(state.fanRunSeconds))
                LabeledContent("Control board", value: Format.temperature(state.controlBoardTemperature))
                LabeledContent("Power board", value: Format.temperature(state.powerBoardTemperature))
                LabeledContent("Heater element", value: state.heaterRunning ? "Heating" : "Idle")
                LabeledContent("Turbo", value: turboText)
                LabeledContent("Schedule", value: state.timerActive ? "Timers enabled" : "No timers enabled")
                LabeledContent("MagicAir", value: state.magicAirConnected ? (state.magicAirAuto ? "Connected · auto" : "Connected") : "Not connected")
                LabeledContent("Sound / light", value: "\(state.soundOn ? "On" : "Off") / \(state.lightOn ? "On" : "Off")")
            }
            .font(.subheadline)
        }
    }

    private var turboText: String {
        guard let turbo = store.turbo else { return "—" }
        return turbo.active ? "On, \(Format.countdown(turbo.secondsLeft)) left" : "Off"
    }
}
