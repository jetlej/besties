import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 12) {
            GeneralSettingsView(appState: appState)
            SettingsCard(title: "AI") {
                AIChooserView(mcp: appState.mcp, compact: true)
            }
        }
        .padding(20)
        .frame(width: 500)
        .background(Color.paper)
        .preferredColorScheme(.light)
    }
}

// MARK: - Shared card chrome

/// A white rounded card on the paper background — the same surface the main
/// window's stat cards use.
struct SettingsCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.ink)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.ink.opacity(0.08)))
    }
}

extension Text {
    /// Secondary copy inside a settings card.
    func settingsCaption() -> some View {
        self.font(.callout)
            .foregroundStyle(Color.ink.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "WhatsApp") {
                if appState.whatsAppInstalled {
                    HStack {
                        Text("Include WhatsApp messages")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Color.ink)
                        Spacer()
                        Toggle("Include WhatsApp messages", isOn: $appState.whatsAppEnabled)
                            .toggleStyle(.switch)
                            .tint(Color.brandBlue)
                            .labelsHidden()
                    }
                    Text("Combines the WhatsApp desktop app's message history on this Mac with iMessage. People are matched by phone number.")
                        .settingsCaption()
                } else {
                    Label("WhatsApp isn't installed on this Mac, so there's no WhatsApp history to include.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(Color.ink.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsCard(title: "Search") {
                Button(appState.searchProgress == nil ? "Rebuild search index" : "Rebuilding…") {
                    appState.rebuildSearchIndex()
                }
                .disabled(appState.searchProgress != nil)
                Text("Search can still turn up messages you've since deleted in Messages — rebuilding drops them and re-reads your history.")
                    .settingsCaption()
            }
        }
    }
}
