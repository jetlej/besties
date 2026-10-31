import SwiftUI
import AppKit

/// Settings → AI Apps: turn on the MCP server and copy the setup for an app.
struct MCPSettingsView: View {
    @Bindable var mcp: MCPController
    @State private var showToken = false
    @State private var copied: String?
    @State private var portDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Use \(appName) from AI apps")
                    .font(.headline)
                Text("Lets an AI app on this Mac read your messages through MCP, so you can ask anything: “when did Sam mention Denver?”, “what did Mia and I do in 2021?”. Pair it with a local model (LM Studio, Ollama) and nothing ever leaves your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Allow AI apps on this Mac to connect", isOn: $mcp.enabled)
                .toggleStyle(.switch)
            statusLine

            if mcp.enabled {
                Divider()
                tokenRow
                setup(title: "LM Studio, Cursor, and other apps that take a URL",
                      note: "In LM Studio: Program → Install → Edit mcp.json, paste, save.",
                      snippet: urlConfig)
                setup(title: "Claude Desktop and other apps that only run commands",
                      note: "Needs Node.js. Claude Desktop sends what it reads to Anthropic. For full privacy use a local model.",
                      snippet: commandConfig)
                HStack {
                    Text("Port")
                    TextField("Port", text: $portDraft, prompt: Text(String(MCPController.defaultPort)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onSubmit(applyPort)
                    Spacer()
                }
                .font(.callout)
            }

            Text("Read-only. Only apps on this Mac that have the token can connect, and only while \(appName) is open. Turn this off, or make a new token, to cut every app off.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 480, alignment: .leading)
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
                .font(.callout).foregroundStyle(.secondary)
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

    private var tokenRow: some View {
        HStack {
            Text("Token")
            Text(showToken ? mcp.token : String(repeating: "•", count: 16))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(showToken ? "Hide" : "Show") { showToken.toggle() }
            Button("New token") { mcp.resetToken() }
                .help("Apps using the old token stop working until you update them.")
        }
        .controlSize(.small)
    }

    private func setup(title: String, note: String, snippet: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                Button(copied == title ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copied = title
                }
                .controlSize(.small)
            }
            Text(snippet.replacingOccurrences(of: mcp.token, with: showToken ? mcp.token : "…"))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.bubbleTan, in: RoundedRectangle(cornerRadius: 8))
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var serverName: String { appName.lowercased().replacingOccurrences(of: " ", with: "-") }

    private var urlConfig: String {
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

    private var commandConfig: String {
        """
        {
          "mcpServers": {
            "\(serverName)": {
              "command": "npx",
              "args": ["-y", "mcp-remote", "\(mcp.endpoint)", "--allow-http", "--header", "Authorization:${AUTH_HEADER}"],
              "env": { "AUTH_HEADER": "Bearer \(mcp.token)" }
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
