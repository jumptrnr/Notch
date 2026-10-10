import SwiftUI

/// WindSensei section of the settings window: the API key, or the connected state.
struct WindSenseiSettingsView: View {
    @ObservedObject var plugin: WindSenseiPlugin
    @State private var keyField = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WindSensei")
                .font(.headline)

            if plugin.isConfigured {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(plugin.spots.isEmpty ? "Connected" : "Connected · \(plugin.spots.count) favourite spots")
                        .font(.callout)
                    Spacer()
                    Button("Disconnect") { plugin.disconnect() }
                }
                if let error = plugin.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 8) {
                    SecureField("API key (ss_…)", text: $keyField)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(connect)
                    Button("Connect", action: connect)
                        .disabled(keyField.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Link("Create a key on windsensei.com", destination: WindSenseiPlugin.site.appending(path: "/dashboard/profile"))
                    .font(.caption)
            }

            Text("""
            Adds a Wind tab with your favourite spots: the station's observed wind, today's \
            forecast and the next rideable block, as WindSensei's widgets show them. The key is \
            kept in an owner-only file under ~/Library/Application Support/Notch.
            """)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connect() {
        plugin.connect(apiKey: keyField)
        keyField = ""
    }
}
