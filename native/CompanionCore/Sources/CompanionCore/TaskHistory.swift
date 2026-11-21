import SwiftUI

public struct TaskRevisionState: Codable, Equatable, Sendable {
    public let title: String
    public let notes: String
    public let definitionOfDone: String
    public let planMarkdown: String
    public let issueType: IssueType
    public let projectID: String
    public let projectName: String
    public let taskKey: String?
    public let status: PhoneTask.Status
    public let priority: PhoneTask.Priority
    public let dueDate: String?
    public let position: Int
    public let archived: Bool
    public let trashed: Bool

    public var restoredStatus: PhoneTask.Status { status == .sent ? .todo : status }
    public func edit(for field: PhoneTaskFieldEdit.Field) -> PhoneTaskFieldEdit {
        switch field {
        case .title: .title(title)
        case .notes: .notes(notes)
        case .definitionOfDone: .definitionOfDone(definitionOfDone)
        case .project: .project(projectID)
        case .status: .status(restoredStatus)
        case .priority: .priority(priority)
        case .dueDate: .dueDate(dueDate)
        case .issueType: .issueType(issueType)
        }
    }
}

public struct TaskRevision: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let version: Int
    public let savedAt: String
    public let action: String
    public let origin: String
    public let changedFields: [String]
    public let state: TaskRevisionState

    public var summary: String {
        if action == "create_task" || action == "capture_task" { return "Task created" }
        if action == "history_started" { return "History started with the current task" }
        if action == "restore_task_revision" { return "Restored a previous revision" }
        let labels = ["title": "Title", "notes": "Notes", "definitionOfDone": "Definition of done",
                      "planMarkdown": "Plan", "issueType": "Issue type", "projectID": "Project",
                      "projectName": "Project name", "taskKey": "Task ID", "status": "Status",
                      "priority": "Priority", "dueDate": "Due date", "position": "Order",
                      "archived": "Archive", "trashed": "Trash"]
        return changedFields.compactMap { labels[$0] }.joined(separator: ", ")
    }
    public var dateLabel: String {
        TaskCreationOrder.date(from: savedAt)?.formatted(date: .abbreviated, time: .shortened) ?? savedAt
    }
}

public struct TaskHistoryPage: Codable, Equatable, Sendable {
    public let taskID: String
    public let revision: Int
    public let entries: [TaskRevision]
    public let nextBefore: Int?

    public func merging(_ older: TaskHistoryPage) -> Self {
        guard taskID == older.taskID else { return self }
        let values = Dictionary((entries + older.entries).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Self(taskID: taskID, revision: max(revision, older.revision),
                    entries: values.values.sorted { $0.version > $1.version }, nextBefore: older.nextBefore)
    }
}

public struct TaskHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected: TaskRevision?
    @State private var confirming = false
    @State private var busy = false
    @State private var message: String?
    @State private var failure: String?
    let page: TaskHistoryPage?
    let colors: OpenTalonColors
    let waitingForMac: Bool
    let load: @MainActor (Int?) async throws -> Void
    let restore: @MainActor (TaskRevision) async throws -> String

    public init(page: TaskHistoryPage?, colors: OpenTalonColors, waitingForMac: Bool = false,
                load: @escaping @MainActor (Int?) async throws -> Void,
                restore: @escaping @MainActor (TaskRevision) async throws -> String) {
        self.page = page; self.colors = colors; self.waitingForMac = waitingForMac; self.load = load; self.restore = restore
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                if selected != nil {
                    Button("History", systemImage: "chevron.left") { selected = nil; confirming = false; failure = nil }
                } else { Text("Task history").font(.headline) }
                Spacer()
                Button("Close") { dismiss() }.accessibilityIdentifier("historyClose")
            }.padding(20)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if waitingForMac { Label("Waiting for your Mac to load older revisions…", systemImage: "clock").font(.footnote).foregroundStyle(colors.muted) }
                    if let failure { Text(failure).foregroundStyle(colors.danger) }
                    if let message { Label(message, systemImage: "checkmark.circle").foregroundStyle(colors.actionAccent) }
                    if let selected { revisionDetail(selected) }
                    else {
                        Text("Every saved change stays here. Restore an earlier version without losing newer history.")
                            .foregroundStyle(colors.muted)
                        if let page {
                            ForEach(page.entries) { entry in
                                Button {
                                    selected = entry; confirming = false; message = nil
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(colors.actionAccent)
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("Revision \(entry.version)").font(.headline)
                                            Text(entry.summary).font(.callout)
                                            Text(entry.dateLabel + " · " + entry.origin).font(.caption).foregroundStyle(colors.muted)
                                        }
                                        Spacer(minLength: 4)
                                        Image(systemName: "chevron.right").foregroundStyle(colors.muted)
                                    }.padding(16).background(colors.card, in: RoundedRectangle(cornerRadius: 18))
                                }.buttonStyle(.plain).accessibilityIdentifier("historyRevision\(entry.version)")
                            }
                            if let before = page.nextBefore {
                                Button("Load older revisions") { run { try await load(before) } }
                                    .accessibilityIdentifier("historyLoadOlder").disabled(waitingForMac)
                            }
                            if page.entries.isEmpty { Text("No saved revisions yet.").foregroundStyle(colors.muted) }
                        } else { ProgressView("Loading history…") }
                    }
                }.padding(20)
            }
        }
        .foregroundStyle(colors.text).background(colors.canvas)
        .buttonStyle(HistoryButtonStyle(colors: colors))
        .disabled(busy)
        .task { if page == nil { run { try await load(nil) } } }
    }

    @ViewBuilder private func revisionDetail(_ entry: TaskRevision) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Revision \(entry.version)").font(.title2.bold())
            Text(entry.dateLabel + " · " + entry.origin).foregroundStyle(colors.muted)
            Text(entry.state.title).font(.headline)
            LabeledContent("Task ID", value: entry.state.taskKey?.uppercased() ?? "Not assigned")
            LabeledContent("Project", value: entry.state.projectName)
            LabeledContent("Issue type", value: entry.state.issueType.rawValue)
            LabeledContent("Status", value: entry.state.status.rawValue)
            LabeledContent("Priority", value: entry.state.priority.rawValue)
            LabeledContent("Due date", value: entry.state.dueDate ?? "No due date")
            if entry.state.archived { Label("Archived at this revision", systemImage: "archivebox") }
            if entry.state.trashed { Label("In Trash at this revision", systemImage: "trash") }
        }.padding(16).background(colors.card, in: RoundedRectangle(cornerRadius: 18))
        document("Notes", entry.state.notes)
        document("Definition of done", entry.state.definitionOfDone)
        if !entry.state.planMarkdown.isEmpty {
            Text("Plan").font(.headline)
            MarkdownPlanPreview(entry.state.planMarkdown)
                .padding(16).background(colors.card, in: RoundedRectangle(cornerRadius: 18))
        }
        Text("Restores task fields, plan, project and status. Revision requests stay with the task. Active agent work stops. Sending to an agent requires a new Send action. Archived revisions reopen in the project.")
            .font(.footnote).foregroundStyle(colors.muted)
        if confirming {
            Text("Restore revision \(entry.version)? The current version will remain in history.").font(.headline)
            HStack {
                Button("Cancel") { confirming = false }
                Spacer()
                Button("Restore revision") { run { message = try await restore(entry); selected = nil; confirming = false } }
                    .accessibilityIdentifier("historyConfirmRestore")
            }
        } else {
            Button("Restore this revision", systemImage: "arrow.uturn.backward") { confirming = true }
                .accessibilityIdentifier("historyRestore")
        }
    }

    @ViewBuilder private func document(_ title: String, _ text: String) -> some View {
        if !text.isEmpty {
            Text(title).font(.headline)
            Text(text).textSelection(.enabled).padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colors.card, in: RoundedRectangle(cornerRadius: 18))
        }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true; failure = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() } catch { failure = error.localizedDescription }
        }
    }
}

private struct HistoryButtonStyle: ButtonStyle {
    let colors: OpenTalonColors
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.callout.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(colors.card.opacity(configuration.isPressed ? 0.65 : 1), in: Capsule())
            .overlay { Capsule().strokeBorder(colors.line, lineWidth: 1) }
    }
}
