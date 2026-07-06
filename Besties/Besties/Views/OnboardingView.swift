import SwiftUI

struct OnboardingView: View {
    let appState: AppState
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
