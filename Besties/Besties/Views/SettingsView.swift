import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appState.whatsAppInstalled {
                Toggle("Include WhatsApp messages", isOn: $appState.whatsAppEnabled)
                    .toggleStyle(.switch)
                Text("Combines the WhatsApp desktop app's message history on this Mac with iMessage. People are matched by phone number.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("WhatsApp isn't installed on this Mac, so there's no WhatsApp history to include.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
