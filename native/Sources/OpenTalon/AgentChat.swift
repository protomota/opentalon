import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AgentChat {
    struct Entry: Identifiable, Codable {
        enum Kind: String, Codable { case user, reply, activity, failure }
        var id = UUID()
        var date = Date()
        let kind: Kind
        let text: String
    }

    struct Conversation: Identifiable, Codable {
        var id = UUID()
        let agent: Agent
        var entries: [Entry]
        var title: String { entries.first { $0.kind == .user }?.text ?? "New chat" }
    }

    private struct History: Codable {
        var conversations: [Conversation] = []
        var selectedID: UUID?
    }

    private struct Reply: Decodable { let text: String }

    static let examples = [
        "What are my urgent to-dos?",
        "What’s due this week?",
        "Which tasks are in progress?",
        "What did I finish this week?"
    ]

    private let historyFile: URL
    private var history: History
    private var historyReadable = true
    private(set) var agent: Agent?
    private(set) var storageError: String?
    private(set) var busy = false
    private(set) var stopping = false
    var draft = ""

    init(profile: URL) {
        historyFile = profile.appending(path: "agent-chat-history.json")
        history = History()
        do {
            history = try JSONDecoder().decode(History.self, from: Data(contentsOf: historyFile))
            agent = selected?.agent
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A workspace with no saved chats starts empty.
        } catch {
            historyReadable = false
            storageError = "OpenTalon couldn’t read your saved chats. New chats can still run, but won’t be saved."
        }
    }

    var conversations: [Conversation] { history.conversations }
    var selected: Conversation? { conversations.first { $0.id == history.selectedID } }
    var entries: [Entry] { selected?.entries ?? [] }
    var recentPrompts: [String] {
        let prompts = conversations.flatMap(\.entries).filter { $0.kind == .user }.sorted { $0.date > $1.date }
        var seen = Set<String>()
        return Array(prompts.filter { seen.insert($0.text).inserted }.prefix(5).map(\.text))
    }

    var canSend: Bool { canSend(draft.trimmingCharacters(in: .whitespacesAndNewlines)) }

    private func canSend(_ message: String) -> Bool {
        !busy && agent != nil && !message.isEmpty && message.utf16.count <= 4000
    }

    func selectAgent(_ agent: Agent) {
        guard !busy, self.agent != agent else { return }
        if selected != nil { newChat(keepDraft: true) }
        self.agent = agent
    }

    func send(_ prompt: String? = nil, using model: WorkspaceModel) {
        let message = (prompt ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend(message), let agent else { return }
        let history = Array(entries.compactMap { entry -> [String: String]? in
            switch entry.kind {
            case .user: ["role": "user", "text": entry.text]
            case .reply: ["role": "assistant", "text": entry.text]
            case .activity: ["role": "assistant", "text": "Confirmed workspace change: \(entry.text)"]
            case .failure: nil
            }
        }.suffix(16))
        var input: [String: Any] = ["message": message, "history": history, "agent": agent.rawValue]
        if let project = model.board?.id { input["projectId"] = project }
        if prompt == nil { draft = "" }
        busy = true
        if selected == nil {
            var next = self.history
            let conversation = Conversation(agent: agent, entries: [Entry(kind: .user, text: message)])
            next.conversations.insert(conversation, at: 0)
            next.selectedID = conversation.id
            save(next)
        } else {
            append(Entry(kind: .user, text: message))
        }
        Task {
            defer { busy = false; stopping = false }
            do {
                let reply: Reply = try await model.service.call("native_agent_chat", input)
                append(Entry(kind: .reply, text: reply.text))
            } catch {
                append(Entry(kind: .failure, text: stopping
                    ? "Stopped. Any changes already shown in the feed are saved."
                    : error.localizedDescription))
            }
        }
    }

    func stop(using model: WorkspaceModel) {
        guard busy, !stopping else { return }
        stopping = true
        Task {
            do {
                let _: EmptyResponse = try await model.service.call("native_stop_chat")
            } catch {
                stopping = false
                append(Entry(kind: .failure, text: error.localizedDescription))
            }
        }
    }

    func newChat(keepDraft: Bool = false) {
        guard !busy else { return }
        var next = history
        next.selectedID = nil
        save(next)
        if !keepDraft { draft = "" }
    }

    func reopen(_ conversation: Conversation) {
        guard !busy, conversations.contains(where: { $0.id == conversation.id }) else { return }
        var next = history
        next.selectedID = conversation.id
        save(next)
        agent = conversation.agent
        draft = ""
    }

    func delete(_ id: UUID) {
        guard !busy else { return }
        var next = history
        next.conversations.removeAll { $0.id == id }
        if next.selectedID == id { next.selectedID = nil }
        save(next, requireDisk: true)
    }

    func deleteAll() {
        guard !busy else { return }
        save(History(), requireDisk: true)
    }

    private func append(_ entry: Entry) {
        guard let id = history.selectedID,
              let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        var next = history
        var conversation = next.conversations.remove(at: index)
        conversation.entries.append(entry)
        next.conversations.insert(conversation, at: 0)
        save(next)
    }

    private func save(_ next: History, requireDisk: Bool = false) {
        guard historyReadable else {
            if !requireDisk { history = next }
            return
        }
        do {
            try JSONEncoder().encode(next).write(to: historyFile, options: .atomic)
            history = next
            storageError = nil
        } catch {
            if !requireDisk { history = next }
            storageError = requireDisk ? "Couldn’t delete saved chats. Try again." : "Couldn’t save your chats to this workspace."
        }
    }

    func record(_ action: String, title: String?) {
        let label: String
        switch action {
        case "create_task": label = "Added task"
        case "update_task": label = "Updated task"
        case "move_task": label = "Moved task"
        case "trash_task": label = "Moved task to Trash"
        case "restore_task": label = "Restored task"
        case "add_task_activity", "add_task_comment": label = "Added activity"
        case "create_board": label = "Created project"
        case "rename_board": label = "Renamed project"
        case "set_board_icon": label = "Updated project icon"
        default: return
        }
        append(Entry(kind: .activity, text: title.map { "\(label) · \($0)" } ?? label))
    }
}

struct AgentChatView: View {
    private enum Deletion {
        case one(UUID), all
    }

    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    @FocusState private var focused: Bool
    @State private var connection: Connection?
    @State private var availableAgents: [Agent] = []
    @State private var showingHistory = false
    @State private var confirmingDeletion = false
    @State private var deletion: Deletion?

    var body: some View {
        @Bindable var chat = model.agentChat
        VStack(alignment: .leading, spacing: 14) {
            SheetTitle(title: "Ask my agent")
            HStack {
                if let agent = chat.agent {
                    if availableAgents.contains(where: { $0 != agent }) {
                        Menu {
                            ForEach(availableAgents) { option in
                                Button {
                                    chat.selectAgent(option)
                                } label: {
                                    AgentBrandLabel(agent: option)
                                }
                            }
                        } label: { agentLabel(agent) }
                        .accessibilityLabel("Chat agent")
                        .accessibilityValue(agent.title)
                        .disabled(chat.busy)
                    } else {
                        agentLabel(agent)
                    }
                }
                Spacer()
                Button("History", systemImage: "clock") { showingHistory.toggle() }
                    .disabled(chat.busy || chat.conversations.isEmpty)
                    .popover(isPresented: $showingHistory, arrowEdge: .bottom) { historyList(chat) }
                Button("New chat", systemImage: "plus") { chat.newChat(); focused = true }
                    .disabled(chat.busy)
            }
            feed(chat)
            if !chat.recentPrompts.isEmpty { recentPrompts(chat) }
            if let storageError = chat.storageError {
                Text(storageError).font(.caption).foregroundStyle(palette.danger)
            }
            if let connection, !connection.running {
                HStack {
                    Text("Turn on the local agent connection to chat.").font(.caption)
                    Spacer()
                    Button("Open Settings") { model.sheet = .settings }
                }
            }
            TextField("Message your agent", text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...5)
                .padding(12)
                .surface(10)
                .focused($focused)
            HStack {
                if chat.draft.utf16.count > 4000 {
                    Text("Keep your message to 4,000 characters.")
                        .font(.caption).foregroundStyle(palette.danger)
                }
                Spacer()
                if chat.busy {
                    Button(chat.stopping ? "Stopping…" : "Stop", systemImage: "stop.fill") { chat.stop(using: model) }
                        .disabled(chat.stopping)
                } else {
                    Button("Send", systemImage: "arrow.up") { chat.send(using: model) }
                        .glassPrimary()
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!chat.canSend || !model.canUseAgents)
                }
            }
        }
        .padding(24)
        .frame(width: 600, height: 560)
        .task {
            let settings: AgentSettings? = try? await model.service.call("get_agent_settings")
            let runtimes: [String: RuntimeState]? = try? await model.service.call("agent_runtime_status")
            availableAgents = Agent.allCases.filter { runtimes?[$0.rawValue]?.installed == true }
            if chat.agent == nil {
                let preferred = settings?.defaultAgent ?? .claude
                chat.selectAgent(availableAgents.contains(preferred) ? preferred : availableAgents.first ?? preferred)
            }
            connection = try? await model.service.call("connection_status")
        }
        .alert(deletionTitle, isPresented: $confirmingDeletion) {
            Button("Cancel", role: .cancel) { deletion = nil }
            Button("Delete", role: .destructive) {
                switch deletion {
                case .one(let id): chat.delete(id)
                case .all: chat.deleteAll()
                case nil: break
                }
                deletion = nil
            }
        } message: {
            Text("This removes the saved conversation history from this OpenTalon workspace.")
        }
        .onAppear { focused = true }
    }

    private func agentLabel(_ agent: Agent) -> some View {
        AgentBrandLabel(agent: agent)
            .foregroundStyle(palette.muted)
            .font(.subheadline)
    }

    private func feed(_ chat: AgentChat) -> some View {
        ScrollViewReader { proxy in
            ThemedScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if chat.entries.isEmpty {
                        Text("Ask about your tasks or tell your agent what to change.")
                            .foregroundStyle(palette.muted)
                        if connection?.running == true {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(AgentChat.examples, id: \.self) { prompt in
                                    promptButton(prompt, chat: chat)
                                }
                            }
                        }
                    }
                    ForEach(chat.entries) { entry in row(entry) }
                    if chat.busy {
                        ProgressView("Waiting for your agent…").controlSize(.small)
                    }
                    Color.clear.frame(height: 1).id("chat-end")
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: chat.entries.count) { proxy.scrollTo("chat-end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("chat-end", anchor: .bottom) }
        }
        .surface(12)
    }

    private var deletionTitle: String {
        if case .all = deletion { return "Delete all chats?" }
        return "Delete this chat?"
    }

    private func requestDeletion(_ kind: Deletion) {
        deletion = kind
        showingHistory = false
        confirmingDeletion = true
    }

    private func historyList(_ chat: AgentChat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Chat history").font(.headline)
            ThemedScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(chat.conversations) { conversation in
                        HStack {
                            Button {
                                chat.reopen(conversation)
                                showingHistory = false
                            } label: {
                                HStack(spacing: 8) {
                                    AgentBrandIcon(agent: conversation.agent)
                                    Text(conversation.title).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if chat.selected?.id == conversation.id {
                                        Image(systemName: "checkmark").accessibilityHidden(true)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(conversation.title)
                            Button(role: .destructive) { requestDeletion(.one(conversation.id)) } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("Delete \(conversation.title)")
                        }
                        .padding(.vertical, 3)
                    }
                }
                .padding(3)
            }
            .frame(height: CGFloat(min(chat.conversations.count, 7) * 35))
            Divider()
            Button("Delete all chats…", role: .destructive) { requestDeletion(.all) }
        }
        .padding(14)
        .frame(width: 330)
    }

    private func recentPrompts(_ chat: AgentChat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent prompts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.muted)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(chat.recentPrompts, id: \.self) { prompt in
                        promptButton(prompt, chat: chat)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func promptButton(_ prompt: String, chat: AgentChat) -> some View {
        Button {
            chat.send(prompt, using: model)
        } label: {
            Text(prompt)
                .lineLimit(1)
                .frame(maxWidth: 260)
        }
        .help(prompt)
        .disabled(chat.busy || chat.agent == nil || connection?.running != true)
    }

    @ViewBuilder private func row(_ entry: AgentChat.Entry) -> some View {
        switch entry.kind {
        case .user, .reply:
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.kind == .user ? "You" : "Agent")
                    .font(.caption.weight(.semibold)).foregroundStyle(palette.muted)
                Text(entry.text).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(entry.kind == .user ? palette.active : palette.well, in: .rect(cornerRadius: 9))
        case .activity:
            Label(entry.text, systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(palette.muted)
        case .failure:
            Label(entry.text, systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(palette.danger)
        }
    }
}
