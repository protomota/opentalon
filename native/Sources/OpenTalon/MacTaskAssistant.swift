import CompanionCore
import Observation
import SwiftUI

@MainActor
@Observable
final class MacTaskAssistant {
    struct Review {
        let task: WorkItem
        let operation: String
    }

    let history: TaskAssistantHistory
    var draft = ""
    var error: String?
    var review: Review?
    private(set) var busy = false
    @ObservationIgnored private var generation: Task<Void, Never>?
    @ObservationIgnored private var results: [TaskAssistantCommand: String] = [:]

    static let examples = ["What are my urgent tasks?", "Which tasks are in progress?",
                           "Create a task with a plan to review my weekly goals", "What did I finish this week?"]

    init(profile: URL) {
        history = TaskAssistantHistory(file: profile.appending(path: "on-device-chat-history.json"))
    }

    func send(_ prompt: String? = nil, using model: WorkspaceModel) {
        let message = (prompt ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, review == nil, history.canWrite, !message.isEmpty, message.utf16.count <= 2_000 else { return }
        guard #available(macOS 26, *) else { error = "Apple Intelligence requires macOS 26 or later."; return }
        if let reason = TaskDrafting.unavailableReason { error = reason; return }
        error = nil
        do { try history.append(.init(role: "user", text: message)) }
        catch { self.error = error.localizedDescription; return }
        draft = ""
        let recent = (history.current?.messages.dropLast().suffix(6) ?? [])
            .map { "\($0.role): \($0.text)" }.joined(separator: "\n")
        busy = true
        results = [:]
        generation = Task {
            defer { busy = false; generation = nil }
            do {
                try await model.refresh()
                let response = try await OnDeviceTaskAssistant.respond(to: message, history: recent,
                    search: { try self.search($0, using: model) },
                    execute: { try await self.execute($0, requestedBy: message, using: model) })
                try Task.checkCancellation()
                if history.current?.messages.last?.text != response {
                    try history.append(.init(role: "assistant", text: response))
                }
            } catch is CancellationError {
                try? history.append(.init(role: "assistant", text: "Stopped. Any changes already listed in App activity remain saved."))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func stop() { generation?.cancel() }

    func search(_ query: String, using model: WorkspaceModel) throws -> String {
        let query = TaskReference.normalized(in: query) ?? query.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
            .filter { !["task", "tasks", "my", "the", "all"].contains($0.lowercased()) }
        let matches = model.tasks.filter { task in
            guard !task.deleted else { return false }
            if query.isEmpty { return task.archivedAt == nil && task.status != .done }
            let fields = [task.id, task.reference, task.title, model.projectName(task.boardId), task.notes,
                          task.status.rawValue, task.priority.rawValue, task.kind.rawValue,
                          task.priority == .urgent ? "critical" : "", task.archivedAt == nil ? "" : "archived"]
            return words.allSatisfy { word in fields.contains { $0.localizedStandardContains(word) } }
        }.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
        let records: [[String: Any]] = matches.prefix(8).map { task in
            ["id": task.id, "taskID": task.reference, "title": task.title,
             "projectID": task.boardId, "projectName": model.projectName(task.boardId),
             "status": task.status.rawValue, "priority": task.priority.rawValue, "issueType": task.kind.rawValue,
             "dueDate": task.dueDate ?? "", "archived": task.archivedAt != nil,
             "notes": matches.count == 1 ? String(task.notes.prefix(800)) : "Search by task ID to read notes.",
             "planMarkdown": matches.count == 1 ? String((task.planMarkdown ?? "").prefix(2_000)) : "Search by task ID to read the plan.",
             "planCharacters": (task.planMarkdown ?? "").utf16.count]
        }
        let data: [String: Any] = ["projects": model.boards.prefix(20).map { ["id": $0.id, "name": $0.name] },
                                  "tasks": records, "matchingCount": matches.count, "shownCount": records.count]
        return String(decoding: try JSONSerialization.data(withJSONObject: data), as: UTF8.self)
    }

    func execute(_ command: TaskAssistantCommand, requestedBy message: String, using model: WorkspaceModel) async throws -> String {
        try Task.checkCancellation()
        try command.validateIntent(message)
        guard model.canLeave(), review == nil, results.count < 8 else {
            throw Failure("Finish the current edit or review before making more changes.")
        }
        if let previous = results[command] { return previous }
        let result: String
        var taskID: String?
        if command.operation == "createProject" {
            let name = command.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.utf16.count <= 100, message.localizedStandardContains(name) else {
                throw Failure("Include the new project’s name in your request.")
            }
            let response: BoardResponse = try await model.write("create_board", ["name": name])
            result = "Created project \(response.board.name)."
        } else if command.operation == "create" {
            let title = command.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.utf16.count <= 500, let first = model.boards.first else {
                throw Failure("A task needs a title of up to 500 characters and an available project.")
            }
            let projectID = command.projectID(in: model.boards.map { PhoneProject(id: $0.id, name: $0.name) }, requestedBy: message)
            let project = model.boards.first { $0.id == projectID }
            let personal = model.boards.first { $0.name.caseInsensitiveCompare("Personal") == .orderedSame }
            var newProject: String?
            if project == nil && !command.project.isEmpty {
                guard command.project.utf16.count <= 100, message.localizedStandardContains(command.project) else {
                    throw Failure("Couldn’t match project “\(command.project)”. Use an existing project name or include the exact new name in your request.")
                }
                newProject = command.project
            } else if project == nil && personal == nil { newProject = "Personal" }
            var fields: [String: Any] = ["boardId": project?.id ?? personal?.id ?? first.id,
                "title": title, "notes": command.notes, "status": WorkStatus.todo.rawValue,
                "priority": TaskDrafting.capturePriority(in: message).rawValue,
                "issueType": IssueType.inferred(from: message).rawValue]
            if TaskPlan.requested(in: message), !command.planMarkdown.isEmpty {
                try TaskPlan.validate(command.planMarkdown)
                fields["planMarkdown"] = command.planMarkdown
            }
            let task = try await model.saveNewTask(fields, newProjectName: newProject)
            taskID = task.id
            result = "Created \(task.reference): \(task.title)."
        } else {
            guard let task = model.tasks.first(where: {
                $0.id == command.taskID || $0.reference.caseInsensitiveCompare(command.taskID) == .orderedSame
            }), !task.deleted else { throw Failure("That task isn’t available. Search again using its task ID.") }
            taskID = task.id
            var fields = task.write
            switch command.operation {
            case "project":
                guard model.boards.contains(where: { $0.id == command.value }) else { throw Failure("Choose an existing project returned by search.") }
                fields["boardId"] = command.value
                try await model.mutate("move_task", fields)
            case "priority":
                guard let priority = Priority(rawValue: command.value) else { throw Failure("Choose a valid priority.") }
                fields["priority"] = priority.rawValue
                try await model.mutate("update_task", fields)
            case "issueType":
                guard let type = IssueType(rawValue: command.value) else { throw Failure("Choose Issue or Bug.") }
                fields["issueType"] = type.rawValue
                try await model.mutate("update_task", fields)
            case "status":
                guard let status = WorkStatus(rawValue: command.value), status != .sent else { throw Failure("Use Send to agent to choose an agent and model.") }
                if status == .done && (task.status == .sent || model.workspace?.agentAssignments[task.id] != nil) {
                    review = Review(task: task, operation: "done")
                    return try record(command, "Review Mark Done for \(task.reference). Nothing has changed yet.", taskID: task.id)
                }
                fields["status"] = status.rawValue
                try await model.mutate("move_task", fields)
            case "dueDate":
                guard command.value.isEmpty || CalendarDay.date(command.value).map(CalendarDay.key) == command.value else { throw Failure("Choose a valid YYYY-MM-DD date.") }
                fields["dueDate"] = command.value.isEmpty ? NSNull() : command.value as Any
                try await model.mutate("update_task", fields)
            case "title", "notes", "definitionOfDone":
                if command.operation == "title" && (command.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || command.value.utf16.count > 500) {
                    throw Failure("Keep the title between 1 and 500 characters.")
                }
                if command.operation == "definitionOfDone" && command.value.utf16.count > 10_000 { throw Failure("Keep the definition of done to 10,000 characters.") }
                fields[command.operation] = command.value
                try await model.mutate("update_task", fields)
            case "plan":
                guard (task.planMarkdown ?? "").utf16.count <= 2_000 else { throw Failure("Open the task’s Plan editor to revise this complete, longer document.") }
                try TaskPlan.validate(command.planMarkdown)
                guard !command.planMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure("The proposed plan is empty. The saved plan is unchanged.") }
                try history.append(.init(role: "plan", text: "Review the proposed plan for \(task.reference). The saved plan is unchanged.",
                                         taskID: task.id, planMarkdown: command.planMarkdown, expectedMarkdown: task.planMarkdown ?? ""))
                result = "Plan proposal ready. Open Review plan to apply and save it."
                results[command] = result
                return result
            case "send":
                try model.requireAgentConnection()
                fields["status"] = WorkStatus.sent.rawValue
                fields["boardId"] = task.boardId
                fields["requestKey"] = "mac:" + UUID().uuidString
                model.pendingSend = (name: "move_task", input: fields, title: task.title)
                model.sheet = .send
                return try record(command, "Send dialog opened for \(task.reference). Choose the agent, model and optional revision request, then Send.", taskID: task.id)
            case "archive", "trash":
                review = Review(task: task, operation: command.operation)
                return try record(command, "Review \(command.operation) for \(task.reference). Nothing has changed yet.", taskID: task.id)
            default: throw Failure("That action isn’t supported.")
            }
            result = "\(task.reference): \(command.operation) saved."
        }
        return try record(command, result, taskID: taskID)
    }

    private func record(_ command: TaskAssistantCommand, _ result: String, taskID: String?) throws -> String {
        try history.append(.init(role: "action", text: result, taskID: taskID))
        results[command] = result
        return result
    }

    func confirmReview(using model: WorkspaceModel) async throws {
        guard let review else { return }
        guard model.tasks.first(where: { $0.id == review.task.id })?.revision == review.task.revision else {
            throw Failure("This task changed. Cancel this review and ask again using its current details.")
        }
        if review.operation == "done" {
            try await model.mutate("force_complete_task", ["id": review.task.id])
        } else {
            try await model.mutate("companion_organize_task", ["id": review.task.id, "destination": review.operation])
        }
        try history.append(.init(role: "action", text: "\(review.task.reference): \(review.operation) confirmed and saved.", taskID: review.task.id))
        self.review = nil
    }

    struct Failure: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }
}

struct MacTaskAssistantView: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var deletion: UUID?
    @State private var deletingAll = false
    @State private var confirmingDeletion = false
    @State private var proposal: TaskAssistantHistory.Message?
    @State private var reviewing = false
    @FocusState private var focused: Bool
    private var assistant: MacTaskAssistant { model.taskAssistant }

    var body: some View {
        @Bindable var assistant = assistant
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Back", systemImage: "chevron.left") { assistant.stop(); model.navigate(.dashboard) }
                Text("Ask OpenTalon").font(palette.display(28)).accessibilityAddTraits(.isHeader)
                Spacer()
                Menu("History") {
                    ForEach(assistant.history.chats) { chat in
                        Button(chat.title) { attempt { try assistant.history.select(chat.id) } }
                    }
                    Divider()
                    Button("Delete this chat…") { deletion = assistant.history.current?.id; deletingAll = false; confirmingDeletion = true }
                        .disabled(assistant.history.current == nil)
                    Button("Delete all chat history…") { deletingAll = true; confirmingDeletion = true }
                        .disabled(assistant.history.chats.isEmpty && assistant.history.error == nil)
                }
                .disabled(assistant.busy || assistant.review != nil)
                Button("New chat", systemImage: "plus") { attempt { try assistant.history.newChat(); assistant.draft = "" } }
                    .disabled(assistant.busy || assistant.review != nil || !assistant.history.canWrite)
            }
            Label("Apple Intelligence · On this device", systemImage: "sparkles")
                .font(.caption).foregroundStyle(palette.actionAccent)
            ScrollViewReader { scroll in
                ThemedScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if (assistant.history.current?.messages ?? []).isEmpty {
                            Text("Manage your tasks by chatting").font(.title3.bold())
                            Text("Find tasks, change priorities, move work between projects, or draft a plan.")
                                .foregroundStyle(palette.muted)
                            ForEach(MacTaskAssistant.examples, id: \.self) { example in
                                Button(example) { assistant.send(example, using: model) }
                                    .disabled(TaskDrafting.unavailableReason != nil || !assistant.history.canWrite)
                            }
                        }
                        ForEach(assistant.history.current?.messages ?? []) { entry in
                            message(entry).id(entry.id)
                        }
                        if assistant.busy { ProgressView("Working on this device…") }
                        Color.clear.frame(height: 1).id("end")
                    }.padding(2)
                }
                .onChange(of: assistant.history.current?.messages.count) { _, _ in scroll.scrollTo("end", anchor: .bottom) }
            }
            if let review = assistant.review {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(review.operation == "done" ? "Mark Done" : review.operation.capitalized): \(review.task.title)").fontWeight(.semibold)
                    Text("Any active agent run will stop. Your task remains recoverable.").font(.caption).foregroundStyle(palette.muted)
                    HStack {
                        Button("Cancel") { assistant.review = nil }
                        Button("Confirm \(review.operation == "done" ? "Mark Done" : review.operation.capitalized)") {
                            reviewing = true
                            Task { defer { reviewing = false }; do { try await assistant.confirmReview(using: model) } catch { assistant.error = error.localizedDescription } }
                        }
                    }.disabled(assistant.busy || reviewing)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).surface(12)
            }
            if let error = assistant.error ?? assistant.history.error {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.bubble").foregroundStyle(palette.actionAccent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Request needs attention").font(.callout.weight(.semibold))
                        Text(error).font(.callout).foregroundStyle(palette.muted).textSelection(.enabled)
                        if let request = assistant.history.current?.messages.last(where: { $0.role == "user" })?.text {
                            Button("Edit request") { assistant.draft = request; assistant.error = nil; focused = true }
                        }
                    }
                    Spacer()
                    Button("Dismiss") { assistant.error = nil }
                        .disabled(assistant.error == nil)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).surface(12)
            }
            if let reason = TaskDrafting.unavailableReason { Text(reason).font(.callout).foregroundStyle(palette.muted) }
            TextField("Ask about your tasks or request an edit", text: $assistant.draft, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(2...5).padding(12).surface(12).focused($focused)
                .accessibilityIdentifier("assistant.message")
            HStack {
                Text("Your tasks stay on this device for AI processing.").font(.caption).foregroundStyle(palette.muted)
                Spacer()
                if assistant.busy { Button("Stop") { assistant.stop() } }
                else {
                    Button("Send", systemImage: "arrow.up") { assistant.send(using: model) }
                        .disabled(assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assistant.draft.utf16.count > 2_000 ||
                                  TaskDrafting.unavailableReason != nil || !assistant.history.canWrite || assistant.review != nil)
                        .keyboardShortcut(.return, modifiers: .command).accessibilityIdentifier("assistant.send")
                }
            }
        }
        .padding(26).frame(maxWidth: 980).frame(maxWidth: .infinity).background(palette.canvas)
        .onDisappear { assistant.stop() }
        .alert(deletingAll ? "Delete all chat history?" : "Delete this chat?", isPresented: $confirmingDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                attempt { if deletingAll { try assistant.history.deleteAll() } else if let deletion { try assistant.history.deleteChat(deletion) } }
            }
        } message: { Text("Only this workspace’s on-device chats are deleted. Your tasks and plans stay unchanged.") }
        .sheet(item: $proposal) { entry in
            if let id = entry.taskID, let task = model.tasks.first(where: { $0.id == id }),
               let original = entry.expectedMarkdown, let candidate = entry.planMarkdown {
                PlanDocumentView(markdown: original, proposal: candidate, reference: task.reference,
                                 context: task.title + "\n" + task.notes, colors: OpenTalonColors(theme: palette.theme)) { markdown in
                    try await model.mutate("set_task_plan", ["id": id, "expectedMarkdown": original, "markdown": markdown])
                    try assistant.history.append(.init(role: "action", text: "\(task.reference): plan saved.", taskID: id))
                }.frame(width: 680, height: 720)
            }
        }
    }

    private func attempt(_ action: () throws -> Void) {
        do { try action() } catch { assistant.error = error.localizedDescription }
    }

    private func message(_ entry: TaskAssistantHistory.Message) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.role == "user" ? "You" : entry.role == "action" ? "App activity" : "OpenTalon")
                .font(.caption.bold()).foregroundStyle(palette.muted)
            Text(entry.text).textSelection(.enabled).accessibilityIdentifier("assistantMessage-" + entry.role)
            if let id = entry.taskID, let task = model.tasks.first(where: { $0.id == id && !$0.deleted }) {
                HStack {
                    Button("Open task", systemImage: "arrow.right") { model.navigate(.board(task.boardId)); model.select(task) }
                    if entry.planMarkdown != nil {
                        Button("Review plan") {
                            if (task.planMarkdown ?? "") == entry.expectedMarkdown { proposal = entry }
                            else { assistant.error = "The saved plan changed. Ask for a fresh revision; this proposal remains in your chat." }
                        }
                    }
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).surface(12)
    }
}
