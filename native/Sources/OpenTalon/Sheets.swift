import AppKit
import CompanionCore
import SwiftUI

struct SheetContent: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch model.sheet {
            case .settings: SettingsView()
            case .review: ReviewInvitation()
            case .agentChat: AgentChatView()
            case .project(let board): ProjectEditor(board: board)
            case .task(let status): NewTaskView(status: status, board: model.board?.id ?? model.selectedBoard)
            case .send: SendView()
            case .icon(let board): IconPicker(board: board)
            case .preview(let preview): PreviewView(preview: preview)
            case nil: EmptyView()
            }
        }
        .id(model.sheet?.id)
        .foregroundStyle(palette.text)
        .tint(palette.accent)
        .buttonStyle(GlassActionStyle())
        .background(palette.panel)
    }
}

private struct ReviewInvitation: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.palette) private var palette
    @State private var opened: Set<String> = []
    @State private var sharePicker = SupportSharePicker()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 58, height: 58)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Free software.\nSupported by people.")
                        .font(.system(size: 26, weight: .semibold, design: .serif))
                        .accessibilityAddTraits(.isHeader)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Help more people discover OpenTalon and tell us what we can improve.")
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 8) {
                Button { visit("tip", url: OpenTalonCommunity.websiteTip) } label: {
                    row("Buy me a coffee", detail: "Leave an optional tip", symbol: "cup.and.saucer", action: "tip")
                }
                Button { visit("feedback", url: OpenTalonCommunity.feedback) } label: {
                    row("Send feedback", detail: "Tell us what’s working and what could be better",
                        symbol: "bubble.left.and.bubble.right", action: "feedback")
                }
                Button {
                    if sharePicker.show() { opened.insert("share") }
                } label: {
                    row("Share OpenTalon", detail: "Send someone a link to the app",
                        symbol: "square.and.arrow.up", action: "share")
                }
                .background(SupportShareAnchor(view: sharePicker.anchor).allowsHitTesting(false))
                Button { visit("support", url: OpenTalonCommunity.support) } label: {
                    row("Open a Support Ticket", detail: "Create a ticket or follow replies on the Protomota website",
                        symbol: "headphones", action: "support")
                }
                Button { visit("apps", url: OpenTalonCommunity.protomotaApps) } label: {
                    row("More Free Apps by Protomota", detail: "Explore more free apps from our studio",
                        symbol: "arrow.up.right.square", action: "apps")
                }
            }
            .buttonStyle(.plain)
            Text("Checkmarks show which buttons you’ve opened.")
                .font(.caption).foregroundStyle(palette.muted)
            Divider()
            HStack {
                Spacer()
                Button("Done") { model.sheet = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func visit(_ action: String, url: URL) {
        openURL(url) { accepted in
            if accepted { opened.insert(action) }
        }
    }

    private func row(_ title: String, detail: String, symbol: String, action: String) -> some View {
        let visited = opened.contains(action)
        return HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(palette.actionAccent)
                .frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(palette.muted)
            }
            Spacer(minLength: 8)
            Image(systemName: visited ? "checkmark.circle.fill" : "arrow.up.right")
                .foregroundStyle(palette.actionAccent)
                .accessibilityLabel(visited ? "Previously opened" : "Open")
        }
        .padding(12)
        .background(palette.card, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(palette.actionAccent.opacity(palette.dark ? 0.48 : 0.42))
                .allowsHitTesting(false)
        }
        .contentShape(.rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

private struct SupportShareAnchor: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
private final class SupportSharePicker: NSObject, NSSharingServicePickerDelegate {
    let anchor = NSView()
    private var picker: NSSharingServicePicker?

    func show() -> Bool {
        guard picker == nil, anchor.window != nil else { return false }
        let picker = NSSharingServicePicker(items: [OpenTalonCommunity.website])
        self.picker = picker
        picker.delegate = self
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        return true
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        Task { @MainActor in self.picker = nil }
    }
}

struct SheetTitle: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    let title: String
    var close: (() -> Void)?
    var body: some View {
        HStack {
            Text(title).font(palette.display(27)).accessibilityAddTraits(.isHeader)
            Spacer()
            IconButton(symbol: "xmark", label: "Close \(title)") {
                if let close { close() }
                else { model.sheet = nil }
            }
        }
    }
}

private struct ProjectEditor: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var name: String
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Bool
    let board: Board?

    init(board: Board?) {
        self.board = board
        _name = State(initialValue: board?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            SheetTitle(title: board == nil ? "New project" : "Rename project")
            Text(board == nil ? "Give your next project a little space." : "Choose a new name for this project.")
                .foregroundStyle(palette.muted)
            TextField("Project name", text: $name)
                .textFieldStyle(.plain)
                .padding(.horizontal, 11)
                .frame(height: 35)
                .surface(9)
                .focused($focus)
            if let error { Text(error).font(.caption).foregroundStyle(palette.danger) }
            HStack {
                Spacer()
                Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button(board == nil ? "Create project" : "Save", action: save)
                    .glassPrimary()
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .disabled(busy)
        .padding(24)
        .frame(width: 410)
        .onAppear { focus = true }
    }

    private func save() {
        busy = true
        Task {
            defer { busy = false }
            do {
                if let board {
                    try await model.mutate("rename_board", ["id": board.id, "expectedRevision": board.revision, "name": name])
                } else {
                    let result: BoardResponse = try await model.write("create_board", ["name": name])
                    model.navigate(.board(result.board.id))
                }
                model.sheet = nil
            } catch let failure { error = failure.localizedDescription }
        }
    }
}

private struct NewTaskView: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var idea = ""
    @State private var notes = ""
    @State private var definitionOfDone = ""
    @State private var includePlan = false
    @State private var issueType: IssueType?
    @State private var detailsExpanded = false
    @State private var draftRequest: Task<Void, Never>?
    @State private var draftError: String?
    @State private var board: String
    @State private var priority = Priority.none
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Bool
    let status: WorkStatus

    init(status: WorkStatus, board: String?) {
        self.status = status
        _board = State(initialValue: board ?? "")
    }

    private var taskTitle: String {
        idea.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var canSave: Bool { !board.isEmpty && !taskTitle.isEmpty && taskTitle.utf16.count <= 500 }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                SheetTitle(title: "New task")
                HStack(spacing: 8) {
                    Text("Status").foregroundStyle(palette.muted)
                    Text(status.rawValue).fontWeight(.semibold)
                }
                .font(.system(size: 13))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Status")
                .accessibilityValue(status.rawValue)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Task description").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if draftRequest != nil {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Drafting task details")
                    }
                    Button(action: draftDetails) {
                        Label(draftRequest == nil ? "Draft with AI" : "Drafting…", systemImage: "sparkles")
                    }
                    .buttonStyle(GlassActionStyle())
                    .disabled(!canSave || draftRequest != nil || (!notes.isEmpty && !definitionOfDone.isEmpty))
                    .help("Draft empty detail fields on this Mac with Apple Intelligence")
                }
                TextField("What needs doing?", text: $idea, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .lineLimit(2...3)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 12)
                    .surface(10)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(palette.accent.opacity(focus ? 0.75 : 0), lineWidth: 1.5)
                            .allowsHitTesting(false)
                    }
                    .accessibilityLabel("Task description")
                    .focused($focus)
                    .disabled(draftRequest != nil)
                if taskTitle.utf16.count > 500 {
                    Text("Keep the description to 500 characters. You can add more context in Task details.")
                        .font(.caption).foregroundStyle(palette.danger)
                }
                if let draftError { Text(draftError).font(.caption).foregroundStyle(palette.danger) }
            }

            HStack(spacing: 10) {
                BoardDropdown(selection: $board, title: "Project", symbol: "folder",
                              choices: model.boards.map(\.id), label: model.projectName)
                BoardDropdown(selection: $priority, title: "Priority", symbol: "flag",
                              choices: Priority.allCases, label: \.label)
            }

            BoardDropdown(selection: Binding(get: { issueType ?? .inferred(from: idea) }, set: { issueType = $0 }),
                          title: "Issue type", symbol: (issueType ?? .inferred(from: idea)).symbol,
                          choices: IssueType.allCases, label: \.rawValue)

            DisclosureGroup("Task details", isExpanded: $detailsExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    detailField("Description and steps", text: $notes, height: 92)
                    detailField("Definition of done", text: $definitionOfDone, height: 62)
                    Toggle("Include a plan", isOn: $includePlan).tint(palette.actionAccent)
                }
                .padding(.top, 10)
                .disabled(draftRequest != nil)
            }
            .font(.system(size: 12, weight: .semibold))

            if let error { Text(error).font(.caption).foregroundStyle(palette.danger) }
            Rectangle().fill(palette.line).frame(height: 1)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { model.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(status == .sent ? "Create and send" : "Create task", action: save)
                    .glassPrimary()
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSave || draftRequest != nil)
            }
        }
        .disabled(busy)
        .padding(27)
        .frame(width: 492)
        .onAppear { focus = true }
        .onDisappear { draftRequest?.cancel() }
    }

    private func detailField(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.muted)
            TextEditor(text: text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(height: height)
                .surface(8)
                .accessibilityLabel(title)
        }
    }

    private func draftDetails() {
        guard draftRequest == nil, canSave else { return }
        let request = idea
        draftError = nil
        draftRequest = Task {
            defer { draftRequest = nil }
            do {
                let draft = try await TaskDrafting.expand(request)
                try Task.checkCancellation()
                if notes.isEmpty { notes = draft.notes }
                if definitionOfDone.isEmpty { definitionOfDone = draft.definitionOfDone }
                detailsExpanded = true
            } catch is CancellationError {
                return
            } catch {
                draftError = error.localizedDescription
                detailsExpanded = true
            }
        }
    }

    private func save() {
        guard canSave, !busy, draftRequest == nil else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let plan: String?
                if includePlan || TaskPlan.requested(in: idea) {
                    if TaskDrafting.unavailableReason == nil {
                        plan = try await TaskPlan.revise("", instruction: "Draft a Markdown plan with actionable steps and verification checks.",
                                                         context: "\(taskTitle)\n\(notes)\nDefinition of done: \(definitionOfDone)")
                    } else {
                        plan = TaskPlan.starter(title: taskTitle, notes: notes, definitionOfDone: definitionOfDone)
                    }
                } else { plan = nil }
                try await model.createItem(title: taskTitle, notes: notes, definitionOfDone: definitionOfDone,
                                           project: board, status: status, priority: priority, planMarkdown: plan, issueType: issueType ?? .inferred(from: idea))
                if model.pendingSend == nil { model.sheet = nil }
            } catch let failure { error = failure.localizedDescription }
        }
    }
}

private struct IconPicker: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var selected: String?
    @State private var busy = false
    @State private var error: String?
    let board: Board

    init(board: Board) {
        self.board = board
        _selected = State(initialValue: board.icon)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: "Change project icon")
            Text(board.name).foregroundStyle(palette.muted)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 6), count: 10), spacing: 6) {
                choice(nil)
                ForEach(BoardIcons.entries.map(\.0), id: \.self) { choice($0) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(palette.danger) }
            HStack {
                Spacer()
                Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Save icon", action: save).glassPrimary().keyboardShortcut(.defaultAction).disabled(selected == board.icon)
            }
        }
        .disabled(busy)
        .padding(23)
        .frame(width: 465)
    }

    private func choice(_ key: String?) -> some View {
        Button { selected = key } label: {
            ProjectIcon(key: key, size: 14)
                .frame(width: 36, height: 33)
                .surface(6, fill: selected == key ? palette.active : palette.card)
        }
        .buttonStyle(.plain)
        .help(key ?? "Default project icon")
        .accessibilityLabel(key ?? "Default project icon")
        .accessibilityAddTraits(selected == key ? .isSelected : [])
    }

    private func save() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.mutate("set_board_icon", [
                    "id": board.id, "expectedRevision": board.revision,
                    "icon": selected.map { $0 as Any } ?? NSNull()
                ])
                model.sheet = nil
            } catch let failure { error = failure.localizedDescription }
        }
    }
}

private struct RestoreResponse: Decodable { let safetyBackup: String? }

private struct PreviewView: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var busy = false
    @State private var error: String?
    @State private var requestKey = UUID().uuidString
    let preview: Preview

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            SheetTitle(title: preview.title, close: cancel)
            Text(preview.detail).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
            if !preview.summary.taskNames.isEmpty {
                let names = preview.summary.taskNames
                Text(names.prefix(4).joined(separator: " · ") + (names.count > 4 ? " and \(names.count - 4) more" : ""))
                    .font(.caption).textSelection(.enabled).lineLimit(3)
            }
            if let path = preview.summary.path, !path.contains("/.native-import-") {
                Text(path).font(.caption).textSelection(.enabled)
            }
            if let error { Text(error).foregroundStyle(palette.danger).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(preview.restoring ? "Restore workspace" : "Delete permanently", role: .destructive, action: confirm)
            }
        }
        .disabled(busy)
        .padding(24)
        .frame(width: 475)
    }

    private func cancel() {
        model.sheet = preview.restoring ? .settings : nil
        if preview.restoring {
            model.perform { let _: EmptyResponse = try await model.service.call("native_cancel_restore") }
        }
    }

    private func confirm() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let result: RestoreResponse = try await model.write("confirm_destructive_action",
                    ["token": preview.token, "requestKey": requestKey])
                model.sheet = nil
                model.undoTrash = nil
                if preview.restoring {
                    model.navigate(.dashboard)
                    model.banner = result.safetyBackup == nil ? "Workspace restored" : "Workspace restored. A safety backup was saved."
                } else { model.banner = "Tasks permanently deleted" }
            } catch let failure { error = failure.localizedDescription }
        }
    }
}

private struct SendView: View {
    private struct AgentOptions: Decodable {
        let defaultAgent: PhoneAgent
        let availableAgents: [PhoneAgent]
        let agentModels: [AgentModelChoice]
        let needsSetup: Bool
    }

    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var options: AgentOptions?
    @State private var agent: PhoneAgent?
    @State private var selectedModel: String?
    @State private var dispatchComment = ""
    @State private var showSetup = false
    @State private var busy = false
    @State private var error: String?

    private var models: [AgentModelChoice] {
        options?.agentModels.filter { $0.agent == agent } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: "Send to agent", close: cancel)
            Text(model.pendingSend?.title ?? "New task").fontWeight(.semibold)
            if let options, !options.availableAgents.isEmpty {
                if options.availableAgents.count > 1 {
                    BoardDropdown(selection: $agent, title: "Agent", symbol: "terminal",
                                  choices: options.availableAgents.map(Optional.some), compact: true,
                                  agentBrand: { Agent(rawValue: $0?.rawValue ?? "") ?? .claude },
                                  label: { $0?.title ?? "Default" })
                } else if let agent, let brand = Agent(rawValue: agent.rawValue) {
                    AgentBrandLabel(agent: brand)
                }
                if !models.isEmpty {
                    BoardDropdown(selection: $selectedModel, title: "Model", symbol: "cpu",
                                  choices: [nil] + models.map { Optional($0.id) }, compact: true,
                                  label: { id in models.first(where: { $0.id == id })?.title ?? "Agent default" })
                }
            } else if options == nil && error == nil {
                ProgressView().controlSize(.small)
            }
            TextField("Extra direction (optional)", text: $dispatchComment, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(2...4).padding(12).surface(10)
                .accessibilityIdentifier("agentDispatchComment")
            DisclosureGroup("Agent setup", isExpanded: $showSetup) {
                AgentControls(settingUpSend: true)
                    .padding(.top, 8)
                Button("Refresh agents", action: { Task { await load() } })
            }
            if let error { Text(error).foregroundStyle(palette.danger).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Send to agent", action: send).glassPrimary()
                    .disabled(options == nil || dispatchComment.utf16.count > 10_000)
            }
        }
        .disabled(busy)
        .padding(24)
        .frame(width: 530)
        .task { await load() }
        .onChange(of: agent) { selectedModel = nil }
        .onChange(of: model.connectionSignal) { Task { await load() } }
    }

    private func cancel() {
        model.pendingSend = nil
        model.sheet = nil
    }

    private func send() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.finishSend(agent: agent, model: models.first(where: { $0.id == selectedModel })?.id,
                                           comment: dispatchComment)
            } catch let failure {
                error = failure.localizedDescription
                if let serviceFailure = failure as? ServiceFailure,
                   ["AGENT_SETUP_REQUIRED", "AGENT_NOT_INSTALLED", "MCP_DISABLED"].contains(serviceFailure.code) {
                    showSetup = true
                }
            }
        }
    }

    private func load() async {
        do {
            let loaded: AgentOptions = try await model.service.call("native_agent_options")
            options = loaded
            if !loaded.availableAgents.contains(where: { $0 == agent }) {
                agent = loaded.availableAgents.first(where: { $0 == loaded.defaultAgent }) ?? loaded.availableAgents.first
            }
            if loaded.needsSetup { showSetup = true }
            error = nil
        } catch let failure {
            error = failure.localizedDescription
        }
    }
}

struct AboutView: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        ThemedScrollView {
            VStack(alignment: .leading, spacing: 24) {
                masthead
                HStack {
                    Link(destination: OpenTalonCommunity.support) { Label("Get App Help", systemImage: "headphones") }
                    Link(destination: OpenTalonCommunity.websiteHelp) { Label("Setup and Troubleshooting", systemImage: "book") }
                    Button("Tip, share, or send feedback", systemImage: "heart") { model.sheet = .review }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 195), spacing: 14, alignment: .top)],
                          alignment: .leading, spacing: 14) {
                    support("Support OpenTalon", "Leave an optional tip to support development.",
                            "Buy me a coffee", OpenTalonCommunity.websiteTip, "cup.and.saucer")
                    support("Feedback", "Tell us what works and what could be better.",
                            "Send Feedback", OpenTalonCommunity.feedback, "bubble.left.and.bubble.right")
                    support("Personal Technical Support", "$9.99 USD per ticket for one setup or troubleshooting issue.",
                            "Open a support ticket", OpenTalonCommunity.support, "headphones")
                    support("Protomota newsletter", "Get new releases and notes from the studio.",
                            "Get product updates", OpenTalonCommunity.newsletter, "envelope")
                }
                VStack(alignment: .leading, spacing: 16) {
                    Divider()
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            siteLinks
                            Spacer(minLength: 16)
                            copyright
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            siteLinks
                            copyright
                        }
                    }
                }
            }
            .frame(maxWidth: 980)
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var masthead: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"

        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 24) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().scaledToFit()
                    .frame(width: 100, height: 88)
                    .shadow(color: .black.opacity(palette.dark ? 0 : 0.18), radius: 8, y: 4)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("OpenTalon")
                        .font(.system(size: 48, weight: .semibold, design: .serif))
                        .accessibilityAddTraits(.isHeader)
                    Text("A little room for the things you’re working on.")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.muted)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Version")
                    Text(version).foregroundStyle(palette.muted)
                }
                GridRow {
                    Text("Build")
                    Text(build).foregroundStyle(palette.muted)
                }
            }
            .font(.system(size: 12, weight: .medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(25)
        .surface(22, fill: palette.panel)
    }

    private var siteLinks: some View {
        HStack(spacing: 8) {
            ProtomotaProductPill()
            Link(destination: OpenTalonCommunity.website) { Label("OpenTalon website", systemImage: "globe") }
            Link(destination: URL(string: "https://github.com/protomota/opentalon")!) {
                Label("View source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var copyright: some View {
        Text("© 2026 Protomota").font(.system(size: 12)).foregroundStyle(palette.muted).fixedSize()
    }

    private func support(_ title: String, _ detail: String, _ label: String, _ url: URL, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.system(size: 16, weight: .medium))
                .foregroundStyle(palette.actionAccent)
                .frame(width: 36, height: 36)
                .background(palette.well, in: .rect(cornerRadius: 11))
                .accessibilityHidden(true)
            Text(title).font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(detail).font(.system(size: 13)).foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Link(destination: url) {
                HStack(spacing: 5) {
                    Text(label)
                    Image(systemName: "arrow.up.right").font(.system(size: 9)).accessibilityHidden(true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 192, alignment: .topLeading)
        .surface(18)
    }
}

private struct ProtomotaProductPill: View {
    var body: some View {
        Link(destination: OpenTalonCommunity.protomota) {
            HStack(spacing: 10) {
                if let logo = Artwork.protomota {
                    Image(nsImage: logo).renderingMode(.original).resizable().scaledToFit()
                        .frame(width: 22, height: 22)
                        .clipShape(.rect(cornerRadius: 6))
                        .accessibilityHidden(true)
                }
                Text("A Protomota Product").font(.system(size: 13.5, weight: .semibold))
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.medium))
                    .accessibilityHidden(true)
            }
            .padding(.leading, 10)
            .padding(.trailing, 16)
            .padding(.vertical, 9)
            .foregroundStyle(.white)
            .background(.black, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("A Protomota Product")
        .help("Visit protomota.com")
    }
}

struct WebLink: View {
    let title: String
    let url: String
    let symbol: String

    var body: some View {
        if let destination = URL(string: url) {
            Link(destination: destination) { Label(title, systemImage: symbol) }.font(.system(size: 12))
        }
    }
}
