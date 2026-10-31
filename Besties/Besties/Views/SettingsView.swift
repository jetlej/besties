import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState
    @State private var tab = SettingsTab.general
    @Namespace private var pillNS

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case aiApps = "AI Apps"

        var systemImage: String {
            switch self {
            case .general: return "gearshape.fill"
            case .aiApps: return "sparkles"
            }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            tabBar
            switch tab {
            case .general: GeneralSettingsView(appState: appState)
            case .aiApps: MCPSettingsView(mcp: appState.mcp)
            }
        }
        .padding(20)
        .frame(width: 500)
        .background(Color.paper)
        .preferredColorScheme(.light)
    }

    /// Same look as the main window's tab bar: sun pill on a flat gray track.
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases, id: \.self) { item in
                Button {
                    withAnimation(.spring(duration: 0.28)) { tab = item }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 12, weight: .bold))
                        Text(item.rawValue)
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(tab == item ? Color.ink : Color.ink.opacity(0.55))
                    .background {
                        if tab == item {
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Color.sun)
                                .matchedGeometryEffect(id: "pill", in: pillNS)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.ink.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
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
