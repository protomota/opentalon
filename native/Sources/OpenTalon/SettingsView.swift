import AppKit
import CompanionCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var busy = false
    @State private var error: String?
    @State private var note: String?
    @State private var pendingTheme: Theme?
    @State private var themeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetTitle(title: "Settings").padding(.horizontal, 24).padding(.vertical, 17)
            Divider()
            ThemedScrollView(track: palette.panel) {
                VStack(alignment: .leading, spacing: 24) {
                    appearance
                    Divider()
                    section("Task agent", "Choose who picks up tasks you move to Sent to agent.")
                    AgentControls()
                    Divider()
                    backupSection
                    DailyBackupView()
                    Divider()
                    PhoneCompanionSettings()
                    Divider()
                    ConnectionSetup()
                    Divider()
                    section("Support", "Get help with OpenTalon on Mac, iPhone, or iPad.")
                    WebLink(title: "Open a Support Ticket", url: OpenTalonCommunity.support.absoluteString,
                            symbol: "headphones")
                    WebLink(title: "Setup and Troubleshooting", url: OpenTalonCommunity.websiteHelp.absoluteString,
                            symbol: "book")
                }
                .padding(24)
            }
        }
        .frame(width: 690, height: 640)
        .toggleStyle(GlassToggleStyle())
        .disabled(busy)
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 11) {
            section("Make yourself at home", "Choose the canvas you like working in.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 0) {
                themeChoice(.graphite, "Quiet focus. A darker canvas.")
                themeChoice(.paper, "A softer place to get things done.")
                themeChoice(.light, "Crisp, clear, and familiar.")
            }
            Toggle("Follow macOS light/dark appearance", isOn: Binding(
                get: { (pendingTheme ?? model.workspace?.theme) == .system },
                set: { useTheme($0 ? .system : .light) }
            ))
            if let themeError { Text(themeError).font(.caption).foregroundStyle(palette.danger) }
        }
        .transaction { $0.animation = nil }
    }

    private func themeChoice(_ theme: Theme, _ description: String) -> some View {
        let swatch = Palette(theme: theme)
        let active = (pendingTheme ?? model.workspace?.theme) == theme
        return Button { useTheme(theme) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule().fill(swatch.accent).frame(width: 16, height: 2)
                        Capsule().fill(swatch.muted).frame(width: 13, height: 2)
                        Capsule().fill(swatch.muted).frame(width: 9, height: 2)
                    }
                    .frame(width: 37, height: 50)
                    .background(swatch.sidebar)
                    ForEach(0..<3) { column in
                        VStack(spacing: 3) {
                            ForEach(0..<(column == 0 ? 3 : 2), id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 2).fill(swatch.card).frame(height: 6)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(3)
                        .frame(maxWidth: .infinity)
                        .background(swatch.well, in: .rect(cornerRadius: 4))
                    }
                }
                .padding(.trailing, 6)
                .frame(height: 50)
                .background(swatch.canvas)
                .clipShape(.rect(cornerRadius: 5))
                HStack {
                    Text(theme.title).fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(palette.accent)
                        .frame(width: 16)
                        .opacity(active ? 1 : 0)
                        .accessibilityHidden(true)
                }
                Text(description).font(.caption2).foregroundStyle(palette.muted)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(8, fill: active ? palette.active : palette.card)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var backupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            section("Your data & backups", "Export everything to one readable JSON file. Keep a copy outside this Mac.")
            HStack {
                Button("Show data folder", systemImage: "folder") { NSWorkspace.shared.open(model.profile) }
                Button("Export Backup…", systemImage: "square.and.arrow.up", action: exportBackup)
                Button("Import / Restore…", systemImage: "square.and.arrow.down", action: importBackup)
            }
            if legacyWorkspaceAvailable {
                Button("Copy from the Electron app…", action: copyElectron)
            }
            Text("Backups include projects, tasks, Trash, appearance, revision requests, screenshots, and agent history. Restore saves a safety backup and never dispatches restored work.")
                .font(.caption).foregroundStyle(palette.muted)
            if let note { Text(note).font(.caption).textSelection(.enabled) }
            if let error { Text(error).font(.caption).foregroundStyle(palette.danger) }
        }
    }

    private func section(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 16, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(description).font(.system(size: 12)).foregroundStyle(palette.muted)
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

    private func useTheme(_ theme: Theme) {
        guard pendingTheme == nil, model.workspace?.theme != theme else { return }
        pendingTheme = theme
        themeError = nil
        Task {
            defer { pendingTheme = nil }
            do { try await model.preferences(["theme": theme.rawValue]) }
            catch { themeError = error.localizedDescription }
        }
    }

    private func exportBackup() {
        run {
            let panel = NSSavePanel()
            panel.title = "Export OpenTalon Backup"
            panel.nameFieldStringValue = "OpenTalon-\(CalendarDay.today).json"
            panel.allowedContentTypes = [.json]
            guard await panel.begin() == .OK, let url = panel.url else { return }
            let result: PathResponse = try await model.write("create_backup", ["destination": url.path, "format": "json"])
            note = "Backup saved: \(result.path)"
        }
    }

    private func importBackup() {
        guard model.canLeave() else { error = "Save or discard your task changes before restoring."; return }
        run {
            let panel = NSOpenPanel()
            panel.title = "Import / Restore OpenTalon Backup"
            panel.allowedContentTypes = [.json] + ["opentalon", "sqlite"].compactMap { UTType(filenameExtension: $0) }
            guard await panel.begin() == .OK, let url = panel.url else { return }
            try await model.preview("restore_backup", path: url.path)
        }
    }

    private var legacyWorkspaceAvailable: Bool {
        let url = model.profile.deletingLastPathComponent().appendingPathComponent("OpenTalon Prototype/opentalon.sqlite")
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        return (try? file.read(upToCount: 16)) == Data("SQLite format 3\0".utf8)
    }

    private func copyElectron() {
        guard model.canLeave() else { error = "Save or discard your task changes before importing."; return }
        run {
            let preview: Preview = try await model.service.call("native_preview_electron")
            model.sheet = .preview(preview)
        }
    }
}

struct RuntimeState: Decodable { let installed: Bool }

struct AgentControls: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var settings: AgentSettings?
    @State private var runtimes: [String: RuntimeState] = [:]
    @State private var connection: Connection?
    @State private var error: String?
    @State private var busy = false
    var settingUpSend = false

    private var onlyAvailableAgent: Agent? {
        let available = Agent.allCases.filter { runtimes[$0.rawValue]?.installed == true }
        return available.count == 1 ? available.first : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let settings {
                Group {
                    if settingUpSend, let onlyAvailableAgent {
                        AgentBrandLabel(agent: onlyAvailableAgent)
                    } else {
                        HStack(spacing: 10) {
                            Text("Default agent").foregroundStyle(palette.muted).accessibilityHidden(true)
                            BoardDropdown(selection: Binding(get: { settings.defaultAgent }, set: { agent in
                                var updated = settings
                                updated.defaultAgent = agent
                                save(updated)
                            }), title: "Default agent", symbol: "terminal", choices: Agent.allCases,
                                          compact: true, agentBrand: { $0 }, label: \.title)
                                .frame(width: 185)
                        }
                        if runtimes[settings.defaultAgent.rawValue]?.installed == false {
                            if let guide = URL(string: settings.defaultAgent.guide) {
                                Link(destination: guide) {
                                    AgentBrandLabel(agent: settings.defaultAgent, title: "Install \(settings.defaultAgent.title)")
                                }
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        Text("Permissions").foregroundStyle(palette.muted).accessibilityHidden(true)
                        BoardDropdown(selection: Binding(get: { settings.permissionMode }, set: { mode in
                            var updated = settings
                            updated.permissionMode = mode
                            save(updated)
                        }), title: "Permissions", symbol: "lock.shield", choices: AgentPermission.allCases,
                                      compact: true, label: \.title)
                            .frame(width: 185)
                    }
                    Text(settings.permissionMode.detail)
                        .font(.caption).foregroundStyle(palette.muted)
                    HStack {
                        Label(settings.workingFolder.isEmpty ? "No working folder selected" : settings.workingFolder,
                              systemImage: "folder")
                            .font(.caption).foregroundStyle(palette.muted).lineLimit(2)
                        Spacer(minLength: 4)
                        Button("Choose working folder…", systemImage: "folder") { chooseFolder(settings) }
                        if !settings.workingFolder.isEmpty {
                            Button("Clear") {
                                var updated = settings
                                updated.workingFolder = ""
                                save(updated)
                            }
                        }
                    }
                    Text("New Codex chats share one project for this folder and appear in Recents.")
                        .font(.caption).foregroundStyle(palette.muted)
                }
                .disabled(!model.canUseAgents)
                if let connection {
                    Toggle("Enable local agent connection", isOn: Binding(
                        get: { connection.enabled },
                        set: { enabled in
                            run {
                                self.connection = try await model.service.call("set_connection", ["enabled": enabled])
                                model.connectionSignal += 1
                            }
                        }
                    ))
                    if !connection.error.isEmpty { Text(connection.error).font(.caption).foregroundStyle(palette.danger) }
                }
            } else {
                ProgressView().controlSize(.small)
            }
            if let error { Text(error).font(.caption).foregroundStyle(palette.danger) }
        }
        .disabled(busy)
        .task(id: model.connectionSignal) { await load() }
        .onChange(of: model.workspace?.revision) { _, _ in
            Task { if !busy { await load() } }
        }
    }

    private func load() async {
        do {
            settings = try await model.service.call("get_agent_settings")
            runtimes = try await model.service.call("agent_runtime_status")
            connection = try await model.service.call("connection_status")
        } catch { self.error = error.localizedDescription }
    }

    private func save(_ settings: AgentSettings) {
        run { try await write(settings) }
    }

    private func write(_ settings: AgentSettings) async throws {
        try await model.mutate("set_agent_settings", [
            "defaultAgent": settings.defaultAgent.rawValue, "workingFolder": settings.workingFolder,
            "permissionMode": settings.permissionMode.rawValue
        ])
        self.settings = settings
    }

    private func chooseFolder(_ settings: AgentSettings) {
        run {
            guard let url = await chooseDirectory("Choose the working folder for agent tasks", prompt: "Use this folder") else { return }
            var updated = settings
            updated.workingFolder = url.path
            try await write(updated)
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await operation() }
            catch let failure { error = failure.localizedDescription }
        }
    }
}

@MainActor
func chooseDirectory(_ title: String, prompt: String) async -> URL? {
    let panel = NSOpenPanel()
    panel.title = title
    panel.prompt = prompt
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    return await panel.begin() == .OK ? panel.url : nil
}
