import Foundation

struct SavedDevice: Codable, Equatable {
    let id: UUID
    var name: String

    private static let key = "savedBreezer"

    static func load() -> SavedDevice? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SavedDevice.self, from: data)
    }

    static func save(_ device: SavedDevice?) {
        if let device, let data = try? JSONEncoder().encode(device) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

/// One reading kept for the history chart.
struct HistorySample: Codable, Identifiable, Equatable {
    let date: Date
    let outdoor: Int
    let supply: Int
    let target: Int
    let fanSpeed: Int
    let powerOn: Bool
    let heaterLoad: Int?
    let airflow: Double?

    var id: Date { date }
}

/// Keeps up to 7 days of readings in Application Support. Readings are only taken while the app is open.
enum HistoryStore {
    static let maxAge: TimeInterval = 7 * 24 * 3600

    private static var fileURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return folder.appendingPathComponent("history.json")
    }

    static func load() -> [HistorySample] {
        guard let data = try? Data(contentsOf: fileURL),
              let samples = try? JSONDecoder().decode([HistorySample].self, from: data) else { return [] }
        let cutoff = Date().addingTimeInterval(-maxAge)
        return samples.filter { $0.date > cutoff }
    }

    static func save(_ samples: [HistorySample]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(samples).write(to: fileURL, options: .atomic)
        } catch {
            // History is a convenience; losing it is harmless.
        }
    }
}
