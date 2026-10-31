import SwiftUI
import AppKit

/// The "Use an AI app on your Mac" setup, once the MCP server is on: its
/// status and the one snippet any MCP app takes.
struct MCPConnectPanel: View {
    @Bindable var mcp: MCPController
    @State private var showToken = false
    @State private var copied = false
    @State private var portDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine

            Text("Paste this into your AI app's MCP settings — it has everything the app needs.")
                .font(.callout)
                .foregroundStyle(Color.ink.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            Text(snippet.replacingOccurrences(of: mcp.token, with: showToken ? mcp.token : "•••your token•••"))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.ink.opacity(0.8))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.bubbleTan, in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 12) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Text(copied ? "Copied ✓" : "Copy setup")
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.sun, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                Spacer()
                link(showToken ? "Hide token" : "Show token") { showToken.toggle() }
                link("New token") { mcp.resetToken() }
                    .help("Apps using the old token stop working until you update them.")
                link("Turn off", color: .orange) { mcp.enabled = false }
            }

            HStack(spacing: 6) {
                Text("Read-only, this Mac only, while Besties is open. Port")
                    .foregroundStyle(Color.ink.opacity(0.45))
                TextField("Port", text: $portDraft, prompt: Text(String(MCPController.defaultPort)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .onSubmit(applyPort)
            }
            .font(.caption)
        }
        .onAppear {
            portDraft = mcp.port == MCPController.defaultPort ? "" : String(mcp.port)
            mcp.loadToken()
        }
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
            Label("Running", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium)).foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func link(_ title: String, color: Color = .brandBlue, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
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
