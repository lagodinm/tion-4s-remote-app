import SwiftUI
import TionKit

struct ControlView: View {
    @EnvironmentObject private var store: BreezerStore
    @EnvironmentObject private var link: BreezerLink
    @State private var confirmFilterReset = false
    @State private var confirmErrorReset = false

    private static let turboMinutes = [1, 5, 10, 15, 20]
    private static let placeholder = BreezerSettings(powerOn: false, soundOn: false, lightOn: false, heaterOn: false,
                                                     recirculation: false, targetTemperature: 18, fanSpeed: 1)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ConnectionBanner()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                if let settings = store.settings, let state = store.state {
                    Group {
                        Section {
                            Toggle(isOn: binding(\.powerOn)) {
                                Label("Power", systemImage: "power")
                            }
                        }

                        Section("Ventilation") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Fan speed").font(.subheadline)
                                Picker("Fan speed", selection: binding(\.fanSpeed)) {
                                    ForEach(1...Swift.max(1, state.maxFanSpeed), id: \.self) { Text("\($0)").tag($0) }
                                }
                                .pickerStyle(.segmented)
                            }
                            Picker("Air intake", selection: binding(\.recirculation)) {
                                Text("Outside air").tag(false)
                                Text("Recirculation").tag(true)
                            }
                        }

                        Section {
                            Toggle(isOn: binding(\.heaterOn)) {
                                Label("Heater", systemImage: "heater.vertical")
                            }
                            .disabled(!state.heaterInstalled)
                            Stepper(value: binding(\.targetTemperature), in: BreezerSettings.temperatureRange) {
                                LabeledContent("Supply air target", value: "\(settings.targetTemperature) °C")
                            }
                            .disabled(!settings.heaterOn || !state.heaterInstalled)
                        } header: {
                            Text("Heating")
                        } footer: {
                            Text(heatingFooter(state: state, settings: settings))
                        }

                        Section {
                            if let turbo = store.turbo, turbo.active {
                                LabeledContent("Turbo running", value: "\(Format.countdown(turbo.secondsLeft)) left")
                                Button("Stop turbo", role: .destructive) {
                                    Task { await store.setTurbo(minutes: 0) }
                                }
                            } else {
                                HStack {
                                    ForEach(Self.turboMinutes, id: \.self) { minutes in
                                        Button("\(minutes) min") {
                                            Task { await store.setTurbo(minutes: minutes) }
                                        }
                                        .buttonStyle(.bordered)
                                        .frame(maxWidth: .infinity)
                                    }
                                }
                            }
                        } header: {
                            Text("Turbo")
                        } footer: {
                            Text(turboFooter)
                        }

                        Section("Indicators") {
                            Toggle(isOn: binding(\.soundOn)) { Label("Sound", systemImage: "speaker.wave.2") }
                            Toggle(isOn: binding(\.lightOn)) { Label("Light", systemImage: "lightbulb") }
                        }

                        Section {
                            Button("Reset filter counter…") { confirmFilterReset = true }
                            Button("Clear errors…") { confirmErrorReset = true }
                        } header: {
                            Text("Maintenance")
                        } footer: {
                            Text("Reset the filter counter only after fitting a new filter. It restarts at \(BreezerSettings.filterResetDays) days.")
                        }
                    }
                    .disabled(!link.status.isReady)
                } else {
                    Section {
                        Text("Controls appear once the breezer is connected.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Control")
            .confirmationDialog("Reset the filter counter?", isPresented: $confirmFilterReset, titleVisibility: .visible) {
                Button("Reset filter counter", role: .destructive) {
                    Task { await store.resetFilterCounter() }
                }
            } message: {
                Text("Do this after replacing the filter.")
            }
            .confirmationDialog("Clear the error list?", isPresented: $confirmErrorReset, titleVisibility: .visible) {
                Button("Clear errors", role: .destructive) {
                    Task { await store.resetErrors() }
                }
            } message: {
                Text("Errors that are still present will come back.")
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<BreezerSettings, Value>) -> Binding<Value> where Value: Equatable {
        Binding(
            get: { (store.settings ?? Self.placeholder)[keyPath: keyPath] },
            set: { newValue in
                guard store.settings?[keyPath: keyPath] != newValue else { return }
                store.change { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private func heatingFooter(state: BreezerState, settings: BreezerSettings) -> String {
        if !state.heaterInstalled { return "This breezer has no heater fitted." }
        if settings.recirculation { return "The heater is normally off during recirculation." }
        return "The heater warms the incoming air to the target temperature."
    }

    private var turboFooter: String {
        if let turbo = store.turbo, turbo.errorCode != 0 {
            return "Turbo isn't available (code \(turbo.errorCode)). It's disabled when the intake air is below 0 °C."
        }
        return "Runs the fan at maximum for a while, then returns to the current speed."
    }
}
