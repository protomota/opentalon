import AppKit
import CompanionCore
import SwiftUI

private struct TaskDraft: Equatable {
    var title: String
    var notes: String
    var criteria: String
    var priority: Priority
    var due: String?

    init(_ item: WorkItem) {
        title = item.title
        notes = item.notes
        criteria = item.definitionOfDone
        priority = item.priority
        due = item.dueDate
    }

    func changes(from saved: Self) -> [String: Any] {
        var fields: [String: Any] = [:]
        if title != saved.title { fields["title"] = title }
        if notes != saved.notes { fields["notes"] = notes }
        if criteria != saved.criteria { fields["definitionOfDone"] = criteria }
        if priority != saved.priority { fields["priority"] = priority.rawValue }
        if due != saved.due { fields["dueDate"] = due.map { $0 as Any } ?? NSNull() }
        return fields
    }
}

private struct DueDateControl: View {
    @Environment(\.palette) private var palette
    @Binding var due: String?
    @State private var date = Date()
    @State private var showingCalendar = false

    var body: some View {
        Button {
            date = due.flatMap(CalendarDay.date) ?? .now
            showingCalendar = true
        } label: {
            Label {
                Text(due.map(CalendarDay.label) ?? "Set due date")
            } icon: {
                Image(systemName: "calendar").foregroundStyle(palette.actionAccent)
            }
        }
        .accessibilityLabel("Due date")
        .accessibilityValue(due.map(CalendarDay.label) ?? "No due date")
        .accessibilityHint("Opens a calendar")
        .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
            VStack(alignment: .trailing, spacing: 10) {
                DatePicker("Due date", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .accessibilityLabel("Due date")
                HStack {
                    Button("Cancel") { showingCalendar = false }
                    Button("Save") {
                        due = CalendarDay.key(date)
                        showingCalendar = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .frame(width: 238)
            .padding(13)
            .background(palette.panel)
            .onExitCommand { showingCalendar = false }
        }
    }
}

struct TaskDetails: View {
    private struct PlanEdit: Identifiable {
        let id: String
        let markdown: String
        let reference: String
        let context: String
    }
    @State private var planEdit: PlanEdit?
    @State private var confirmForceComplete = false
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    let item: WorkItem
    @State private var draft: TaskDraft
    @State private var saved: TaskDraft
    @State private var revision: Int
    @State private var saving = false
    @State private var commentDirty = false
    @State private var error: String?
    @State private var conflict: WorkItem?
    @State private var autosave: Task<Void, Never>?
    @State private var copiedTaskID: UUID?

    init(item: WorkItem) {
        self.item = item
        _draft = State(initialValue: TaskDraft(item))
        _saved = State(initialValue: TaskDraft(item))
        _revision = State(initialValue: item.revision)
    }

    private var dirty: Bool { draft != saved }
    private var valid: Bool { !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Task details").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.muted)
                Spacer()
                Button(copiedTaskID == nil ? "Copy task ID" : "Copied",
                       systemImage: copiedTaskID == nil ? "doc.on.doc" : "checkmark") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    if pasteboard.setString(item.reference, forType: .string) { copiedTaskID = UUID() }
                }
                .help("Copy the full task ID to the clipboard")
                IconButton(symbol: "xmark", label: "Close task details") {
                    if model.canLeave() { model.selection = nil }
                }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 9)
            Rectangle().fill(palette.line).frame(height: 1)
            ThemedScrollView(track: palette.panel) {
                VStack(alignment: .leading, spacing: 16) {
                    editFields
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Plan").font(.headline)
                        Button {
                            planEdit = PlanEdit(id: item.id, markdown: item.planMarkdown ?? "", reference: item.reference,
                                                context: "\(draft.title)\n\(draft.notes)\nDefinition of done: \(draft.criteria)")
                        } label: {
                            Label((item.planMarkdown ?? "").isEmpty ? "Create plan" : "View plan", systemImage: "doc.text")
                        }
                        .accessibilityIdentifier("taskPlan")
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(palette.danger)
                    }
                    if let conflict {
                        HStack {
                            Button("Use saved text") { load(conflict) }
                            Button("Keep my edits") {
                                revision = conflict.revision
                                saved = TaskDraft(conflict)
                                self.conflict = nil
                                error = nil
                                beginSave()
                            }
                        }
                    } else if dirty || saving {
                        HStack {
                            Button(saving ? "Saving…" : "Save now") { beginSave() }
                                .disabled(saving || !valid)
                            Button("Use saved text") { load(item) }.disabled(saving)
                        }
                    } else {
                        Label("Saved", systemImage: "checkmark").font(.caption).foregroundStyle(palette.muted)
                    }
                    if let run = model.workspace?.agentRuns.first(where: { $0.taskId == item.id }) {
                        RunDetails(run: run)
                    }
                    if item.status != .done, item.status == .sent || model.workspace?.agentAssignments[item.id] != nil {
                        Button("Mark Done Anyway") { confirmForceComplete = true }
                            .disabled(dirty || saving || commentDirty)
                    }
                    TaskComments(item: item, dirty: $commentDirty)
                    Divider()
                    HStack {
                        Button("Move to Trash", role: .destructive) { model.trash(item) }
                            .disabled(dirty || saving || commentDirty)
                        Spacer()
                    }
                }
                .padding(17)
            }
        }
        .background(palette.panel)
        .sheet(item: $planEdit) { edit in
            PlanDocumentView(markdown: edit.markdown,
                             draft: UserDefaults.standard.string(forKey: "planDraft." + edit.id),
                             reference: edit.reference, context: edit.context,
                             colors: OpenTalonColors(theme: palette.theme)) { markdown in
                try await model.mutate("set_task_plan", ["id": edit.id, "expectedMarkdown": edit.markdown, "markdown": markdown])
            } persistDraft: { markdown in
                UserDefaults.standard.set(markdown, forKey: "planDraft." + edit.id)
            }
            .frame(minWidth: 600, minHeight: 650)
        }
        .alert("Mark this task done anyway?", isPresented: $confirmForceComplete) {
            Button("Cancel", role: .cancel) {}
            Button("Mark Done") {
                model.perform { try await model.mutate("force_complete_task", ["id": item.id]) }
            }
        } message: {
            Text("This stops any active agent run and moves the task to Done.")
        }
        .task(id: copiedTaskID) {
            guard let copiedTaskID else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if self.copiedTaskID == copiedTaskID { self.copiedTaskID = nil }
        }
        .onChange(of: draft) { _, _ in
            syncDirty()
            scheduleSave()
        }
        .onChange(of: saving) { _, _ in syncDirty() }
        .onChange(of: commentDirty) { _, _ in syncDirty() }
        .onChange(of: item.revision) { _, _ in
            guard !saving, revision != item.revision else { return }
            if !dirty || TaskDraft(item) == saved { revision = item.revision }
            if !dirty || TaskDraft(item) == draft { load(item) }
            else if TaskDraft(item) != saved {
                conflict = item
                error = "This task changed while you were editing it."
            }
        }
        .onDisappear {
            autosave?.cancel()
            model.draftDirty = false
        }
    }

    private var editFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Task title", text: $draft.title, axis: .vertical)
                .lineLimit(1...3).font(.system(size: 22, weight: .semibold))
                .textFieldStyle(.plain)
                .accessibilityLabel("Task title")
            VStack(alignment: .leading, spacing: 4) {
                Text("Task ID").font(.caption.weight(.semibold))
                Text(item.reference)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(palette.muted)
            Grid(alignment: .leading, horizontalSpacing: 9, verticalSpacing: 10) {
                GridRow {
                    property("Status")
                    BoardDropdown(selection: Binding(get: { item.status }, set: { model.move(item, to: $0) }),
                                  title: "Status", symbol: item.status.symbol, choices: WorkStatus.allCases,
                                  compact: true, label: \.rawValue)
                        .disabled(dirty || saving || commentDirty)
                }
                GridRow {
                    property("Project")
                    BoardDropdown(selection: Binding(get: { item.boardId }, set: { model.move(item, to: item.status, board: $0) }),
                                  title: "Project", symbol: "folder", choices: model.boards.map(\.id),
                                  compact: true, label: model.projectName)
                        .disabled(dirty || saving || commentDirty)
                }
                GridRow {
                    property("Priority")
                    BoardDropdown(selection: $draft.priority, title: "Priority", symbol: "flag",
                                  choices: Priority.allCases, compact: true, label: \.label)
                }
                GridRow {
                    property("Due date")
                    HStack(spacing: 5) {
                        DueDateControl(due: $draft.due)
                        if draft.due != nil {
                            IconButton(symbol: "xmark", label: "Clear due date") { draft.due = nil }
                        }
                    }
                }
                GridRow {
                    property("Order")
                    if item.status == .todo {
                        Text("Urgent first, newest first")
                            .font(.caption).foregroundStyle(palette.muted)
                    } else {
                        HStack(spacing: 5) {
                            let siblings = model.tasks.filter { !$0.deleted && $0.boardId == item.boardId && $0.status == item.status }
                                .sorted { $0.position < $1.position }
                            let index = siblings.firstIndex { $0.id == item.id } ?? 0
                            IconButton(symbol: "arrow.up", label: "Move task up") {
                                guard index > 0 else { return }
                                model.move(item, to: item.status, anchor: siblings[index - 1].id)
                            }.disabled(index == 0 || dirty || commentDirty)
                            IconButton(symbol: "arrow.down", label: "Move task down") {
                                guard index + 1 < siblings.count else { return }
                                model.move(item, to: item.status, anchor: siblings[index + 1].id, before: false)
                            }.disabled(index + 1 >= siblings.count || dirty || commentDirty)
                        }
                    }
                }
            }
            Divider()
            editor("Notes", text: $draft.notes, height: 130)
            editor("Definition of done", text: $draft.criteria, height: 68)
        }
        .disabled(saving)
    }

    private func property(_ title: String) -> some View {
        Text(title).foregroundStyle(palette.muted).font(.system(size: 12))
    }

    private func editor(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .semibold))
            TextEditor(text: text)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(5)
                .frame(height: height)
                .surface()
                .accessibilityLabel(title)
        }
    }

    private func syncDirty() {
        model.draftDirty = dirty || saving || commentDirty
        if !model.draftDirty && model.banner == "Save or discard your task changes before leaving." {
            model.banner = nil
        }
    }

    private func load(_ latest: WorkItem) {
        autosave?.cancel()
        draft = TaskDraft(latest)
        saved = draft
        revision = latest.revision
        conflict = nil
        error = nil
        syncDirty()
    }

    private func scheduleSave() {
        autosave?.cancel()
        guard dirty, valid, !saving, conflict == nil, error == nil else { return }
        autosave = Task {
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            beginSave()
        }
    }

    private func beginSave() {
        autosave?.cancel()
        guard dirty, valid, !saving, conflict == nil else { return }
        var fields = draft.changes(from: saved)
        fields["id"] = item.id
        fields["expectedRevision"] = revision
        saving = true
        error = nil
        syncDirty()
        Task {
            defer { saving = false; syncDirty() }
            do {
                let result: ItemResponse = try await model.write("update_task", fields)
                load(result.task)
            } catch let failure as ServiceFailure {
                conflict = failure.current
                error = failure.message
            } catch let failure {
                error = failure.localizedDescription
            }
        }
    }
}

private struct RunDetails: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    let run: AgentRun
    @State private var stopping = false
    @State private var opening = false
    @State private var resumeCommand: String?
    @State private var copied = false
    @State private var sessionInUse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                AgentBrandLabel(agent: run.agent).fontWeight(.semibold)
                Spacer()
                Text(run.statusLabel).foregroundStyle(palette.muted)
            }
            if !run.summary.isEmpty { Text(run.summary).textSelection(.enabled) }
            if let approval = run.approval {
                Divider()
                Text(approval.title).fontWeight(.semibold)
                ThemedScrollView(track: palette.panel) { Text(approval.details).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                    .frame(maxHeight: 135)
                HStack {
                    Button("Deny") { answer(approval, allow: false) }
                    if approval.canApprove { Button("Allow once") { answer(approval, allow: true) } }
                }
            }
            HStack {
                if run.threadId != nil && (run.agent == .codex || !run.active) {
                    Button(action: openConversation) {
                        AgentBrandLabel(agent: run.agent, title: run.agent == .claude ? "Open in Claude" : "Open conversation")
                    }
                        .disabled(opening)
                }
                if run.active {
                    Button("Stop run", role: .destructive) { stopping = true }
                }
            }
            if run.agent == .claude && run.threadId != nil && run.active {
                Text("Stop this run before opening it in Claude.")
                    .font(.caption).foregroundStyle(palette.muted)
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .surface()
        .confirmationDialog("Stop this agent run?", isPresented: $stopping, titleVisibility: .visible) {
            Button("Stop run", role: .destructive) { perform("stop_agent_run") }
        }
        .sheet(isPresented: Binding(
            get: { resumeCommand != nil },
            set: { if !$0 { resumeCommand = nil } }
        )) {
            if let resumeCommand {
                VStack(alignment: .leading, spacing: 14) {
                    SheetTitle(title: "Resume in Claude") { self.resumeCommand = nil }
                    Text("Open the Claude CLI in the folder below and paste the command into its prompt.")
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(run.workingFolder)
                        .font(.callout)
                        .textSelection(.enabled)
                    Text(resumeCommand)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .surface(9)
                    if sessionInUse {
                        Text("This session is already open. Run `/desktop` in that session to move it into Claude Desktop.")
                            .font(.callout)
                            .foregroundStyle(palette.muted)
                    }
                    HStack {
                        Spacer()
                        Button("Done") { self.resumeCommand = nil }
                            .keyboardShortcut(.cancelAction)
                        Button(copied ? "Copied" : "Copy Command",
                               systemImage: copied ? "checkmark" : "doc.on.doc") {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            copied = pasteboard.setString(resumeCommand, forType: .string)
                        }
                        .glassPrimary()
                    }
                }
                .padding(24)
                .frame(width: 510)
                .foregroundStyle(palette.text)
                .buttonStyle(GlassActionStyle())
                .background(palette.panel)
            }
        }
    }

    private func openConversation() {
        opening = true
        model.perform {
            defer { opening = false }
            do {
                let _: EmptyResponse = try await model.service.call("open_agent_thread", ["runId": run.id])
            } catch let failure as ServiceFailure where run.agent == .claude
                && ["THREAD_OPEN_FAILED", "THREAD_IN_USE"].contains(failure.code) {
                guard let threadId = run.threadId else { throw failure }
                copied = false
                sessionInUse = failure.code == "THREAD_IN_USE"
                resumeCommand = "/resume \(threadId)"
            }
        }
    }

    private func perform(_ name: String, fields: [String: Any] = [:]) {
        model.perform {
            var input = fields
            input["runId"] = run.id
            let _: EmptyResponse = try await model.service.call(name, input)
            try await model.refresh()
        }
    }

    private func answer(_ approval: AgentRun.Approval, allow: Bool) {
        perform("answer_agent_approval", fields: ["approvalId": approval.id, "allow": allow])
    }
}
