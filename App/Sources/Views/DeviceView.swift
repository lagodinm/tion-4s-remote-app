import SwiftUI
import TionKit

struct DeviceView: View {
    @EnvironmentObject private var store: BreezerStore
    @EnvironmentObject private var link: BreezerLink
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            List {
                Section("Breezer") {
                    LabeledContent("Name", value: store.savedDevice?.name ?? "—")
                    LabeledContent("Connection", value: link.status.title)
                    if let info = store.deviceInfo {
                        LabeledContent("Model", value: info.isBreezer4S ? "Breezer 4S" : String(format: "Type 0x%04X", info.deviceType))
                        LabeledContent("Firmware", value: info.firmwareString)
                        LabeledContent("Hardware", value: info.hardwareString)
                        LabeledContent("Mode", value: info.workModeName)
                    }
                    if let state = store.state {
                        LabeledContent("Heater", value: state.heaterRatedWatts.map { "\($0) W" } ?? "Not fitted")
                        LabeledContent("Max fan speed", value: "\(state.maxFanSpeed)")
                    }
                    Button("Reconnect") { link.reconnect() }
                }

                Section("Clock") {
                    LabeledContent("Breezer vs phone", value: store.clockOffset.map(Format.clockOffset) ?? "—")
                    Button("Set breezer clock to phone time") { Task { await store.syncClock() } }
                        .disabled(!link.status.isReady)
                }

                if let active = store.timersState?.active {
                    Section("Timer slots enabled, as the breezer reports") {
                        Text((0..<TimerSlot.count).map { "\($0 + 1): \(active[safe: $0] == true ? "yes" : "no")" }.joined(separator: "   "))
                            .font(.caption.monospaced())
                    }
                }

                if let state = store.state {
                    Section {
                        RawStateTable(raw: state.raw)
                    } header: {
                        Text("Last state packet")
                    } footer: {
                        Text("For checking the decoding against the breezer's own display.")
                    }
                }

                Section {
                    NavigationLink("Bluetooth log") { LogView() }
                }

                Section {
                    Button("Forget this breezer", role: .destructive) { confirmForget = true }
                } footer: {
                    Text("To pair again, also remove the breezer in Settings › Bluetooth if it's listed there.")
                }
            }
            .navigationTitle("Device")
            .confirmationDialog("Forget this breezer?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) { store.forgetDevice() }
            } message: {
                Text("The schedule stays stored in the breezer.")
            }
        }
    }
}

private struct RawStateTable: View {
    let raw: [UInt8]

    private static let meanings: [Int: String] = [
        0: "Flags: power, sound, light, heater, mode, filter",
        1: "Flags: heater rating, MagicAir, timers enabled, counter",
        2: "Air intake",
        3: "Target °C",
        4: "Fan speed",
        5: "Outdoor °C",
        6: "Supply °C",
        7: "Control board °C",
        8: "Power board °C",
        9: "Powered-on time (s), 4 bytes",
        13: "Fan run time (s), 4 bytes",
        17: "Filter time left (s), 4 bytes",
        21: "Airflow counter, 4 bytes",
        25: "Error/warning bits, 4 bytes",
        29: "Max fan speed",
        30: "Heater load %",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(raw.enumerated()), id: \.offset) { index, byte in
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%2d", index)).foregroundStyle(.secondary)
                    Text(String(format: "%02X", byte))
                    Text(String(format: "%4d", Int(byte)))
                        .foregroundStyle(.secondary)
                    Text(Self.meanings[index] ?? "").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .font(.caption.monospaced())
        .textSelection(.enabled)
    }
}

private struct LogView: View {
    @EnvironmentObject private var link: BreezerLink

    var body: some View {
        List(link.log.reversed()) { entry in
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.date.formatted(date: .omitted, time: .standard)) \(label(entry.kind))")
                    .font(.caption2)
                    .foregroundStyle(color(entry.kind))
                Text(entry.text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Bluetooth log")
        .toolbar {
            ShareLink(item: exportText) {
                Image(systemName: "square.and.arrow.up")
            }
        }
    }

    private var exportText: String {
        link.log.map { "\($0.date.ISO8601Format()) \(label($0.kind)) \($0.text)" }.joined(separator: "\n")
    }

    private func label(_ kind: LinkLogEntry.Kind) -> String {
        switch kind {
        case .sent: return "→ sent"
        case .received: return "← received"
        case .info: return "info"
        case .error: return "error"
        }
    }

    private func color(_ kind: LinkLogEntry.Kind) -> Color {
        switch kind {
        case .sent: return .blue
        case .received: return .green
        case .info: return .secondary
        case .error: return .red
        }
    }
}
