import SwiftUI

/// Step 1: Full Disk Access. WhatsApp can't even be detected until this is
/// granted, so the WhatsApp question lives on its own page afterward.
struct OnboardingView: View {
    @Bindable var appState: AppState
    @State private var checkFailed = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "message.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color.brandBlue)

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

            Text("One more thing —")
                .font(.largeTitle.bold())

            Text("You have WhatsApp on this Mac. Want its history in your timeline too?")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)

            HStack(spacing: 14) {
                SourceChoiceCard(
                    title: "iMessage only",
                    subtitle: "Just your iMessage history",
                    icons: [Color.brandBlue],
                    selected: !includeWhatsApp
                ) { includeWhatsApp = false }

                SourceChoiceCard(
                    title: "iMessage + WhatsApp",
                    subtitle: "Both apps, one merged timeline per person",
                    icons: [Color.brandBlue, Color.green],
                    selected: includeWhatsApp
                ) { includeWhatsApp = true }
            }
            .frame(maxWidth: 520)

            Button("Start") {
                appState.whatsAppEnabled = includeWhatsApp
                appState.whatsAppPromptSeen = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 6)

            Text("Everything stays on your Mac. You can change this anytime in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(40)
    }
}

private struct SourceChoiceCard: View {
    let title: String
    let subtitle: String
    let icons: [Color]
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                HStack(spacing: -6) {
                    ForEach(icons.indices, id: \.self) { i in
                        Image(systemName: "message.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(icons[i], in: RoundedRectangle(cornerRadius: 10))
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
