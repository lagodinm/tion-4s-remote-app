import SwiftUI
import TionKit

enum Format {
    static func temperature(_ value: Int) -> String {
        "\(value)°"
    }

    static func duration(_ seconds: UInt32) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        if days > 0 {
            return "\(days) d \(hours) h"
        }
        return "\(hours) h \((seconds % 3600) / 60) min"
    }

    static func cubicMeters(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0))) + " m³"
    }

    static func clockOffset(_ seconds: TimeInterval) -> String {
        let magnitude = abs(seconds)
        if magnitude < 60 { return "In sync (±\(Int(magnitude.rounded())) s)" }
        let minutes = Int((magnitude / 60).rounded())
        return "\(minutes) min \(seconds > 0 ? "ahead" : "behind")"
    }

    static func countdown(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Series colors from the data-viz reference palette (categorical slots 1 and 2), stepped per appearance.
enum ChartColors {
    static let outdoor = Color(light: 0x2A78D6, dark: 0x3987E5)
    static let supply = Color(light: 0xEB6834, dark: 0xD95926)
    static let running = Color(light: 0x1BAF7A, dark: 0x199E70)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// Shows the connection state whenever the breezer isn't ready.
struct ConnectionBanner: View {
    @EnvironmentObject private var link: BreezerLink

    var body: some View {
        if !link.status.isReady {
            HStack(spacing: 12) {
                switch link.status {
                case .connecting, .preparing:
                    ProgressView()
                default:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.status.title).font(.subheadline.weight(.semibold))
                    if case .connecting = link.status {
                        Text("Keep the breezer powered and nearby. Close the Tion Remote app on other phones — the breezer accepts one connection at a time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if case .failed = link.status {
                    Button("Retry") { link.reconnect() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var detail: String?
    let systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(TintedIconLabelStyle(tint: tint))
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

struct TintedIconLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
