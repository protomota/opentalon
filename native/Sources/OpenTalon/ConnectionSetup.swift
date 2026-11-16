import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum Client: String, CaseIterable, Identifiable {
    case claudeCode = "claude-code", codex, claude
    var id: Self { self }
    var title: String {
        switch self {
        case .claudeCode: "Claude"
        case .codex: "Codex"
        case .claude: "Claude chat"
        }
    }
    var agent: Agent { self == .codex ? .codex : .claude }
    var guide: String {
        switch self {
        case .claudeCode: "https://code.claude.com/docs/en/desktop#connect-external-tools"
        case .codex: "https://learn.chatgpt.com/docs/extend/mcp?surface=desktop"
        case .claude: "https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop"
        }
    }
}

private struct SetupField: Decodable, Identifiable {
    let id: String
    let label: String
    let value: String
}

private struct ProjectSetup: Decodable {
    let id: String
    let replacing: Bool
}

struct ConnectionSetup: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var client = Client.claudeCode
    @State private var terminalClient = Client.claudeCode
    @State private var connection: Connection?
    @State private var fields: [SetupField] = []
    @State private var error: String?
    @State private var note: String?
    @State private var testResult: Result<Void, Error>?
    @State private var busy = false
    @State private var confirmReset = false
    @State private var replacement: ProjectSetup?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Agent connection").font(.system(size: 16, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text("Connect an agent to your local boards and tasks. OpenTalon stays available when you close its window.")
                .font(.system(size: 12)).foregroundStyle(palette.muted)
            if let connection {
                HStack {
                    Toggle("Enable MCP connection", isOn: Binding(get: { connection.enabled }, set: toggle))
                    Spacer()
                    Button("Test connection", systemImage: "checkmark.shield", action: testConnection)
                        .disabled(!connection.running)
                }
                if let testResult {
                    switch testResult {
                    case .success:
                        Label("MCP connection works. OpenTalon answered a read-only request.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(palette.text).font(.caption)
                    case .failure(let failure):
                        Label(failure.localizedDescription, systemImage: "exclamationmark.circle")
                            .foregroundStyle(palette.danger).font(.caption)
                    }
                }
                if connection.running {
                    Label("Running locally", systemImage: "checkmark.circle").font(.caption).foregroundStyle(palette.muted)
                    HStack(spacing: 8) {
                        ForEach(Client.allCases) { option in
                            Button { client = option } label: { AgentBrandLabel(agent: option.agent, title: option.title) }
                                .buttonStyle(GlassActionStyle(prominent: option == client))
                                .accessibilityAddTraits(option == client ? .isSelected : [])
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Client")
                    instructions
                    DisclosureGroup("Advanced setup") { advanced.padding(.top, 8) }
                }
                if !connection.error.isEmpty { Text(connection.error).foregroundStyle(palette.danger).font(.caption) }
            } else {
                ProgressView().controlSize(.small)
            }
            if let error { Text(error).foregroundStyle(palette.danger).font(.caption) }
            if let note { Text(note).foregroundStyle(palette.muted).font(.caption).textSelection(.enabled) }
        }
        .disabled(busy)
        .task(id: model.connectionSignal) {
            do { try await reload() }
            catch { self.error = error.localizedDescription }
        }
        .alert("Reset the connection key?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset key", role: .destructive) {
                run {
                    connection = try await model.service.call("reset_connection_key")
                    try await reload()
                    note = "Connection key reset. Refresh any direct HTTP configuration."
                }
            }
        } message: { Text("Clients with the old direct HTTP key will lose access.") }
        .alert("Replace this project’s OpenTalon connection?", isPresented: Binding(
            get: { replacement != nil }, set: { if !$0 { replacement = nil } }
        )) {
            Button("Cancel", role: .cancel) { replacement = nil }
            Button("Replace OpenTalon connection") {
                if let setup = replacement {
                    replacement = nil
                    run { try await writeProject(setup) }
                }
            }
        } message: { Text("Other servers and settings in this folder will be preserved.") }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch client {
            case .claudeCode:
                Text("1. Save the connection in your Claude working folder.")
                Text("2. Open Claude, select Code, and open that folder. Approve the project’s OpenTalon connection when prompted.")
                HStack {
                    Button("Save project connection…", action: saveProject)
                    Button { openApp("com.anthropic.claudefordesktop") } label: { AgentBrandLabel(agent: .claude, title: "Open Claude") }
                }
            case .codex:
                Text("1. In Codex, open Settings → MCP servers and add a server.")
                Text("2. Choose STDIO and copy the fields below. Save, then reload the MCP connection.")
                ForEach(fields) { field in
                    HStack {
                        Text(field.label).fontWeight(.medium)
                        Spacer()
                        Text(field.value).lineLimit(1).truncationMode(.middle).foregroundStyle(palette.muted)
                        Button("Copy") { copy(field.value, message: "Copied \(field.label).") }
                            .accessibilityLabel("Copy \(field.label)")
                    }
                }
                Button { openApp("com.openai.codex") } label: { AgentBrandLabel(agent: .codex, title: "Open Codex") }
            case .claude:
                Text("1. Save the OpenTalon extension.")
                Text("2. Open Claude Settings → Extensions and install the local .mcpb file.")
                HStack {
                    Button(action: saveExtension) { AgentBrandLabel(agent: .claude, title: "Save Claude extension…") }
                    Button { openApp("com.anthropic.claudefordesktop") } label: { AgentBrandLabel(agent: .claude, title: "Open Claude") }
                }
            }
            WebLink(title: "Official setup guide", url: client.guide, symbol: "arrow.up.right")
        }
        .font(.system(size: 12))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Button("Copy STDIO JSON") { configuration("stdio") }
                Button("Copy HTTP JSON") { configuration("http") }
                Button("Reset connection key…") { confirmReset = true }
            }
            HStack {
                BoardDropdown(selection: $terminalClient, title: "Terminal setup", symbol: "terminal",
                              choices: [.claudeCode, .codex], compact: true, agentBrand: \.agent, label: \.title)
                    .frame(width: 170)
                Button("Copy command") {
                    run {
                        let result: ValueResponse = try await model.service.call("copy_terminal_setup", ["client": terminalClient.rawValue])
                        copy(result.value, message: "Terminal command copied.")
                    }
                }
                Button("Open Terminal") { openApp("com.apple.Terminal") }
            }
            if let endpoint = connection?.endpoint {
                Text(endpoint).font(.caption2.monospaced()).foregroundStyle(palette.muted).textSelection(.enabled)
            }
        }
    }

    private func toggle(_ enabled: Bool) {
        run {
            connection = try await model.service.call("set_connection", ["enabled": enabled])
            model.connectionSignal += 1
        }
    }

    private func testConnection() {
        testResult = nil
        run {
            do {
                let _: EmptyResponse = try await model.service.call("native_test_connection")
                testResult = .success(())
            } catch {
                testResult = .failure(error)
            }
        }
    }

    private func reload() async throws {
        testResult = nil
        let current: Connection = try await model.service.call("connection_status")
        connection = current
        fields = current.running ? try await model.service.call("agent_setup_fields") : []
    }

    private func copy(_ value: String, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        note = message
    }

    private func configuration(_ transport: String) {
        run {
            let result: ValueResponse = try await model.service.call("client_configuration", ["transport": transport])
            copy(result.value, message: "Configuration copied.")
        }
    }

    private func saveProject() {
        run {
            guard let folder = await chooseDirectory("Choose your Claude working folder", prompt: "Save project connection") else { return }
            let setup: ProjectSetup = try await model.service.call("native_prepare_project", ["path": folder.path])
            if setup.replacing { replacement = setup }
            else { try await writeProject(setup) }
        }
    }

    private func writeProject(_ setup: ProjectSetup) async throws {
        let _: EmptyResponse = try await model.service.call("native_write_project", ["id": setup.id])
        note = "Project connection saved."
    }

    private func saveExtension() {
        run {
            let panel = NSSavePanel()
            panel.title = "Save Claude Desktop extension"
            panel.nameFieldStringValue = "OpenTalon.mcpb"
            if let type = UTType(filenameExtension: "mcpb") { panel.allowedContentTypes = [type] }
            guard await panel.begin() == .OK, let url = panel.url else { return }
            let result: PathResponse = try await model.service.call("native_save_extension", ["path": url.path])
            note = "Extension saved."
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.path)])
        }
    }

    private func openApp(_ id: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { Task { @MainActor in self.error = error.localizedDescription } }
            }
        } else {
            error = "This app could not be opened. Check that it’s installed."
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        note = nil
        Task {
            defer { busy = false }
            do { try await operation() }
            catch let failure { error = failure.localizedDescription }
        }
    }
}
