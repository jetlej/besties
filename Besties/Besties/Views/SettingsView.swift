import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState

    /// Fixed size: expanding an AI option scrolls inside the window instead
    /// of growing it.
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                GeneralSettingsView(appState: appState)
                SettingsCard(title: "AI") {
                    AIChooserView(mcp: appState.mcp, compact: true)
                }
                SearchIndexRow(appState: appState)
            }
            .padding(20)
        }
        .frame(width: 500, height: 640)
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
        SettingsCard(title: "General") {
            HStack(spacing: 6) {
                Text("Include WhatsApp messages")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(appState.whatsAppInstalled ? Color.ink : Color.ink.opacity(0.4))
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Color.ink.opacity(0.35))
                Spacer()
                Toggle("Include WhatsApp messages", isOn: $appState.whatsAppEnabled)
                    .toggleStyle(.switch)
                    .tint(Color.brandBlue)
                    .labelsHidden()
                    .disabled(!appState.whatsAppInstalled)
            }
            .help(appState.whatsAppInstalled
                  ? "Combines the WhatsApp desktop app's message history on this Mac with iMessage. People are matched by phone number."
                  : "WhatsApp isn't installed on this Mac, so there's no WhatsApp history to include.")
        }
    }
}

/// One quiet row under the cards — rarely needed, so it stays small.
private struct SearchIndexRow: View {
    @Bindable var appState: AppState

    var body: some View {
        HStack(spacing: 6) {
            Text("Search index")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.ink.opacity(0.5))
            Image(systemName: "info.circle")
                .font(.caption2)
                .foregroundStyle(Color.ink.opacity(0.35))
            Spacer()
            Button(appState.searchProgress == nil ? "Rebuild" : "Rebuilding…") {
                appState.rebuildSearchIndex()
            }
            .controlSize(.small)
            .disabled(appState.searchProgress != nil)
        }
        .padding(.horizontal, 4)
        .help("Search can still turn up messages you've since deleted in Messages — rebuilding drops them and re-reads your history.")
    }
}
