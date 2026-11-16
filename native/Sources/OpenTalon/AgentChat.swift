import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AgentChat {
    struct Entry: Identifiable {
        enum Kind { case user, reply, activity, failure }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    private struct Reply: Decodable { let text: String }

    private(set) var entries: [Entry] = []
    private(set) var busy = false
    private(set) var stopping = false
    var draft = ""

    var canSend: Bool {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !busy && !message.isEmpty && message.utf16.count <= 4000
    }

    func send(using model: WorkspaceModel) {
        guard canSend else { return }
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let history = Array(entries.compactMap { entry -> [String: String]? in
            switch entry.kind {
            case .user: ["role": "user", "text": entry.text]
            case .reply: ["role": "assistant", "text": entry.text]
            case .activity: ["role": "assistant", "text": "Confirmed workspace change: \(entry.text)"]
            case .failure: nil
            }
        }.suffix(16))
        var input: [String: Any] = ["message": message, "history": history]
        if let project = model.board?.id { input["projectId"] = project }
        draft = ""
        busy = true
        entries.append(Entry(kind: .user, text: message))
        Task {
            defer { busy = false; stopping = false }
            do {
                let reply: Reply = try await model.service.call("native_agent_chat", input)
                entries.append(Entry(kind: .reply, text: reply.text))
            } catch {
                entries.append(Entry(kind: .failure, text: stopping
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
                entries.append(Entry(kind: .failure, text: error.localizedDescription))
            }
        }
    }

    func clear() {
        guard !busy else { return }
        entries = []
        draft = ""
    }

    func record(_ action: String, title: String?) {
        let label: String
        switch action {
        case "create_task": label = "Added task"
        case "update_task": label = "Updated task"
        case "move_task": label = "Moved task"
        case "trash_task": label = "Moved task to Trash"
        case "restore_task": label = "Restored task"
        case "add_task_comment": label = "Added comment"
        case "create_board": label = "Created project"
        case "rename_board": label = "Renamed project"
        case "set_board_icon": label = "Updated project icon"
        default: return
        }
        entries.append(Entry(kind: .activity, text: title.map { "\(label) · \($0)" } ?? label))
    }
}

struct AgentChatView: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    @FocusState private var focused: Bool
    @State private var settings: AgentSettings?
    @State private var connection: Connection?

    var body: some View {
        @Bindable var chat = model.agentChat
        VStack(alignment: .leading, spacing: 14) {
            SheetTitle(title: "Ask my agent")
            HStack {
                if let settings {
                    agentLabel(settings.defaultAgent)
                }
                Spacer()
                if !chat.entries.isEmpty {
                    Button("New chat", systemImage: "plus") { chat.clear(); focused = true }
                        .disabled(chat.busy)
                }
            }
            feed(chat)
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
                        .disabled(!chat.canSend || connection?.running == false)
                }
            }
        }
        .padding(24)
        .frame(width: 600, height: 560)
        .task {
            settings = try? await model.service.call("get_agent_settings")
            connection = try? await model.service.call("connection_status")
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
                            Button("What are my urgent to-dos?") {
                                model.agentChat.draft = "What are my urgent to-dos?"
                                focused = true
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
