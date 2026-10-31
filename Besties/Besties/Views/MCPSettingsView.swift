import SwiftUI
import AppKit

/// Settings → AI Apps: turn on the MCP server, then pick your AI app and
/// copy its one setup snippet.
struct MCPSettingsView: View {
    @Bindable var mcp: MCPController
    @State private var showToken = false
    @State private var copied = false
    @State private var portDraft = ""

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Use Besties from AI apps")
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.ink)
                Text("Lets an AI app on this Mac read your messages, so you can ask anything: “when did Sam mention Denver?”. Pair it with a local model and nothing ever leaves your Mac.")
                    .settingsCaption()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SettingsCard {
                HStack {
                    Text("Allow AI apps on this Mac to connect")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.ink)
                    Spacer()
                    Toggle("Allow AI apps on this Mac to connect", isOn: $mcp.enabled)
                        .toggleStyle(.switch)
                        .tint(Color.brandBlue)
                        .labelsHidden()
                }
                statusLine
            }

            if mcp.enabled {
                SettingsCard(title: "Connect an app") {
                    Text("Copy this and paste it into the AI app you want to use — it has everything the app needs.")
                        .settingsCaption()

                    snippetBox

                    HStack {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(snippet, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        } label: {
                            Text(copied ? "Copied ✓" : "Copy setup")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.ink)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 14)
                                .background(Color.sun, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button(showToken ? "Hide token" : "Show token") { showToken.toggle() }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.brandBlue)
                        Button("New token") { mcp.resetToken() }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.brandBlue)
                            .help("Apps using the old token stop working until you update them.")
                    }
                }

                HStack {
                    Text("Port")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.ink.opacity(0.55))
                    TextField("Port", text: $portDraft, prompt: Text(String(MCPController.defaultPort)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 76)
                        .onSubmit(applyPort)
                    Spacer()
                }
            }

            Text("Read-only. Only apps on this Mac with the token can connect, and only while Besties is open. Turn this off, or make a new token, to cut every app off.")
                .font(.caption)
                .foregroundStyle(Color.ink.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            portDraft = mcp.port == MCPController.defaultPort ? "" : String(mcp.port)
            if mcp.enabled { mcp.loadToken() }
        }
        .onChange(of: mcp.enabled) { if mcp.enabled { mcp.loadToken() } }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch mcp.state {
        case .off:
            EmptyView()
        case .starting:
            Label("Starting…", systemImage: "hourglass")
                .font(.callout).foregroundStyle(Color.ink.opacity(0.55))
        case .running:
            Label("Running at \(mcp.endpoint)", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
                .textSelection(.enabled)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var snippetBox: some View {
        Text(snippet.replacingOccurrences(of: mcp.token, with: showToken ? mcp.token : "•••your token•••"))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Color.ink.opacity(0.8))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.bubbleTan, in: RoundedRectangle(cornerRadius: 8))
    }

    private var serverName: String { appName.lowercased().replacingOccurrences(of: " ", with: "-") }

    /// The standard mcp.json shape — LM Studio, Cursor and most MCP apps take
    /// it as-is, and it carries the URL and token for any app that asks for
    /// them separately.
    private var snippet: String {
        """
        {
          "mcpServers": {
            "\(serverName)": {
              "url": "\(mcp.endpoint)",
              "headers": { "Authorization": "Bearer \(mcp.token)" }
            }
          }
        }
        """
    }

    private func applyPort() {
        let trimmed = portDraft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { mcp.port = MCPController.defaultPort; return }
        if let port = UInt16(trimmed), port >= 1024 { mcp.port = port } else { portDraft = String(mcp.port) }
    }
}
