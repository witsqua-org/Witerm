#if os(iOS)
import SwiftUI
import WitermCore

/// Round 20: every device connected to the open paired terminal, from the
/// terminal's ⋯ menu (and the iPad header's): this device first, then the
/// Mac by its name, then the others, each typing or watching, and the one
/// whose size the terminal uses when the Mac says so. A system list in a
/// sheet, never a menu; it follows the model, which lists the terminal again
/// every 5 seconds while it's open.
struct ConnectedDevicesSheet: View {
    static let symbol = "macbook.and.iphone"
    let model: RemoteTerminalModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let devices = model.connectedDevices {
                    List {
                        Section {
                            ForEach(devices) { row($0) }
                        } footer: {
                            footer(alone: devices.count == 1)
                        }
                    }
                } else {
                    // The terminal disconnected while this was open.
                    ContentUnavailableView(String(localized: "Disconnected", bundle: .main),
                                           systemImage: WitermSymbols.disconnected)
                }
            }
            .navigationTitle(String(localized: "Connected Devices", bundle: .main))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .main)) { dismiss() }
                        .accessibilityIdentifier("connectedDevicesDone")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ device: ConnectedDevice) -> some View {
        let facts = Self.facts(device)
        return Label {
            VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                Text(verbatim: device.name)
                Text(verbatim: facts.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: Self.icon(device))
                .foregroundStyle(device.kind == .mac ? model.selectedGrant?.host.identityHue ?? .accentColor : .accentColor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: device.name))
        .accessibilityValue(Text(verbatim: facts.joined(separator: ", ")))
        .accessibilityIdentifier("connectedDevice-\(device.id)")
    }

    /// Typing or Watching, and Sets the terminal size when it does.
    static func facts(_ device: ConnectedDevice) -> [String] {
        [device.typing ? String(localized: "Typing", bundle: .main) : String(localized: "Watching", bundle: .main),
         device.setsSize ? String(localized: "Sets the terminal size", bundle: .main) : nil].compactMap { $0 }
    }

    static func icon(_ device: ConnectedDevice) -> String {
        switch device.kind {
        case .thisDevice: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        case .mac: "laptopcomputer"
        case .paired: "ipad.and.iphone"
        }
    }

    /// That nobody else is connected, and the terminal's size.
    @ViewBuilder private func footer(alone: Bool) -> some View {
        let lines = [alone ? String(localized: "No other devices are connected.", bundle: .main) : nil,
                     model.liveGrid.map { String(localized: "Terminal size: \($0.columns) × \($0.rows)", bundle: .main) }]
            .compactMap { $0 }
        if !lines.isEmpty {
            Text(verbatim: lines.joined(separator: "\n"))
                .accessibilityLabel(Text(verbatim: [alone ? String(localized: "No other devices are connected.", bundle: .main) : nil,
                                                    model.liveGrid.map { String(localized: "Terminal size: \($0.columns) columns, \($0.rows) rows", bundle: .main) }]
                    .compactMap { $0 }.joined(separator: " ")))
                .accessibilityIdentifier("connectedDevicesFooter")
        }
    }
}
#endif
