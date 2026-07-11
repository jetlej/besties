import SwiftUI

struct OnboardingView: View {
    @Bindable var appState: AppState
    @State private var checkFailed = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "message.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("Besties")
                .font(.largeTitle.bold())

            Text("Besties needs Full Disk Access to read your iMessage history.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            VStack(alignment: .leading, spacing: 12) {
                Label("Open System Settings → Privacy & Security", systemImage: "1.circle.fill")
                Label("Select Full Disk Access", systemImage: "2.circle.fill")
                Label("Enable Besties in the list", systemImage: "3.circle.fill")
            }
            .font(.body)
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            if appState.whatsAppInstalled {
                Toggle(isOn: $appState.whatsAppEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include WhatsApp messages")
                        Text("Reads the WhatsApp desktop app's history on this Mac — covered by the same permission. You can change this later in Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(maxWidth: 360)
            }

            Button("Open System Settings") {
                PermissionChecker.openSystemPreferences()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("I've enabled it — check again") {
                appState.checkAccess()
                checkFailed = !appState.hasFullDiskAccess
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            if checkFailed {
                VStack(spacing: 8) {
                    Text("Still can't read your messages. macOS applies Full Disk Access when the app restarts.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Button("Relaunch Besties") {
                        PermissionChecker.relaunchApp()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Spacer()
        }
        .padding(40)
    }
}
