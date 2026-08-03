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

            Divider()
                .padding(.vertical, 4)

            Button(appState.searchProgress == nil ? "Rebuild search index" : "Rebuilding…") {
                appState.rebuildSearchIndex()
            }
            .disabled(appState.searchProgress != nil)
            Text("Search can still turn up messages you've since deleted in Messages — rebuilding drops them and re-reads your history.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 380)
    }
}
