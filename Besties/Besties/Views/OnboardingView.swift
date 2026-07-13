import SwiftUI
import AppKit

/// Step 1: Full Disk Access. WhatsApp can't even be detected until this is
/// granted, so the WhatsApp question lives on its own page afterward.
struct OnboardingView: View {
    @Bindable var appState: AppState
    @State private var checkFailed = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)

            Text("Besties")
                .font(.largeTitle.bold())

            Text("Besties needs Full Disk Access to read your iMessage history.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)

            VStack(alignment: .leading, spacing: 12) {
                Label("Open System Settings → Privacy & Security", systemImage: "1.circle.fill")
                Label("Select Full Disk Access", systemImage: "2.circle.fill")
                Label("Enable Besties in the list", systemImage: "3.circle.fill")
            }
            .font(.body)
            .padding()
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.ink.opacity(0.08)))

            Button("Open System Settings") {
                PermissionChecker.openSystemPreferences()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            // Fixed-height slot for both states, so swapping the button for
            // relaunch + caption never shifts or re-centers the layout.
            VStack(spacing: 8) {
                if checkFailed {
                    Button("Relaunch Besties") {
                        PermissionChecker.relaunchApp()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Text("Enabled it already? macOS applies Full Disk Access when the app restarts — relaunch and you're in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 320)
                } else {
                    Button("I've enabled it — check again") {
                        appState.checkAccess()
                        checkFailed = !appState.hasFullDiskAccess
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
            .frame(height: 72, alignment: .top)

            Spacer()
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
    }
}

/// Step 2, shown only when WhatsApp's message store exists on this Mac:
/// pick which histories to include. One merged timeline either way.
struct WhatsAppOnboardingView: View {
    @Bindable var appState: AppState
    @State private var includeWhatsApp = true

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("Include WhatsApp?")
                .font(.largeTitle.bold())

            HStack(spacing: 14) {
                SourceChoiceCard(
                    title: "Messages only",
                    subtitle: "Just your Messages history",
                    apps: [.messages],
                    selected: !includeWhatsApp
                ) { includeWhatsApp = false }

                SourceChoiceCard(
                    title: "Messages + WhatsApp",
                    subtitle: "One merged timeline per person",
                    apps: [.messages, .whatsApp],
                    selected: includeWhatsApp
                ) { includeWhatsApp = true }
            }
            .frame(maxWidth: 520)

            Button {
                appState.whatsAppEnabled = includeWhatsApp
                appState.whatsAppPromptSeen = true
            } label: {
                Text("Start")
                    .font(.title3.bold())
                    .padding(.horizontal, 32)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 6)

            Text("You can change this anytime in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(40)
    }
}

/// Mini app-icon tiles matching the real apps: Messages is a green gradient
/// bubble, WhatsApp a green gradient phone-in-bubble.
private enum SourceApp {
    case messages, whatsApp

    /// Messages uses the system bubble; WhatsApp uses the official logo
    /// (asset rendered from the brand glyph).
    @ViewBuilder var glyph: some View {
        switch self {
        case .messages:
            Image(systemName: "message.fill")
                .font(.system(size: 21))
                .foregroundStyle(.white)
        case .whatsApp:
            Image("WhatsAppGlyph")
                .resizable()
                .scaledToFit()
                .frame(width: 27, height: 27)
        }
    }

    var gradient: LinearGradient {
        switch self {
        case .messages:
            LinearGradient(colors: [Color(red: 107/255, green: 227/255, blue: 111/255),
                                    Color(red: 16/255, green: 195/255, blue: 47/255)],
                           startPoint: .top, endPoint: .bottom)
        case .whatsApp:
            LinearGradient(colors: [Color(red: 91/255, green: 246/255, blue: 117/255),
                                    Color(red: 15/255, green: 188/255, blue: 56/255)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

private struct SourceChoiceCard: View {
    let title: String
    let subtitle: String
    let apps: [SourceApp]
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                HStack(spacing: -6) {
                    ForEach(apps.indices, id: \.self) { i in
                        apps[i].glyph
                            .frame(width: 42, height: 42)
                            .background(apps[i].gradient, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.paper, lineWidth: 2))
                    }
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .padding(.horizontal, 14)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(selected ? Color.ink : Color.ink.opacity(0.12), lineWidth: selected ? 2 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.ink)
                        .frame(width: 22, height: 22)
                        .background(Color.sun, in: Circle())
                        .overlay(Circle().strokeBorder(Color.ink, lineWidth: 1.5))
                        .offset(x: 8, y: -8)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
