import SwiftUI

@main
struct TionBreezerApp: App {
    @StateObject private var store = BreezerStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(store.link)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: BreezerStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if store.savedDevice == nil {
                PairingView()
            } else {
                TabView {
                    DashboardView()
                        .tabItem { Label("Status", systemImage: "gauge.with.dots.needle.33percent") }
                    ControlView()
                        .tabItem { Label("Control", systemImage: "slider.horizontal.3") }
                    ScheduleView()
                        .tabItem { Label("Schedule", systemImage: "calendar.badge.clock") }
                    DeviceView()
                        .tabItem { Label("Device", systemImage: "info.circle") }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            store.scenePhaseChanged(phase)
        }
        .alert("Breezer", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.message ?? "")
        }
    }
}
