import SwiftUI
import TionKit

struct PairingView: View {
    @EnvironmentObject private var store: BreezerStore
    @EnvironmentObject private var link: BreezerLink

    private var nearby: [DiscoveredBreezer] {
        link.discovered.sorted { ($0.pairingMode ? 1 : 0, $0.rssi) > ($1.pairingMode ? 1 : 0, $1.rssi) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    step(1, "Keep your iPhone within 5 m of the breezer with Bluetooth on.")
                    step(2, "The breezer must be in standby (yellow light). If there's no yellow light, briefly press its button.")
                    step(3, "Press and hold the button until the light flashes blue. The breezer is now in pairing mode.")
                    step(4, "Tap your breezer below, then confirm the pairing request iOS shows.")
                } header: {
                    Text("Pair your Breezer 4S")
                } footer: {
                    Text("Close the Tion Remote app on other phones first. The breezer accepts one connection at a time.")
                }

                Section {
                    if case .bluetoothUnavailable(let reason) = link.status {
                        Label(reason, systemImage: "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(.orange)
                    } else if nearby.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Searching for breezers…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(nearby) { breezer in
                        Button {
                            store.pair(with: breezer)
                        } label: {
                            HStack {
                                Image(systemName: "wind")
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(breezer.name).foregroundStyle(.primary)
                                    Text("Signal \(breezer.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if breezer.pairingMode {
                                    Text("Ready to pair")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Nearby")
                }
            }
            .navigationTitle("Add breezer")
            .onAppear { link.startScan() }
            .onDisappear { link.stopScan() }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            Text(text).font(.subheadline)
        }
    }
}
