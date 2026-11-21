import CompanionCore
import SwiftUI

private enum Attention: String, CaseIterable, Identifiable {
    case urgent = "Urgent to-dos", all = "All to-dos", overdue = "Overdue", today = "Due today", done = "Done"
    var id: Self { self }
    func matches(_ item: WorkItem, today: String) -> Bool {
        switch self {
        case .all: item.status == .todo
        case .urgent: item.status == .todo && item.priority == .urgent
        case .overdue: item.dueDate.map { $0 < today } ?? false
        case .today: item.dueDate == today
        case .done: item.status == .done
        }
    }
}

private enum ProgressBucket: String, CaseIterable, Identifiable {
    case urgent = "Urgent to-dos", todo = "Other to-dos", sent = "Sent to agent", working = "In progress", done = "Done"
    var id: Self { self }

    init(_ item: WorkItem) {
        switch item.status {
        case .todo: self = item.priority == .urgent ? .urgent : .todo
        case .sent: self = .sent
        case .working: self = .working
        case .done: self = .done
        }
    }

    var columnWidth: CGFloat {
        switch self {
        case .urgent, .todo: 68
        case .sent, .working: 73
        case .done: 40
        }
    }

    func color(_ palette: Palette) -> Color {
        switch self {
        case .urgent: Priority.urgent.color(palette.dark)
        case .todo: palette.flow(.todo)
        case .sent: palette.flow(.sent)
        case .working: palette.flow(.working)
        case .done: palette.flow(.done)
        }
    }
}

struct DashboardView: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var scope = ""
    @State private var filter = Attention.urgent
    @State private var limit = 6

    private var projects: [Board] { model.boards.filter { scope.isEmpty || $0.id == scope } }
    private var active: [WorkItem] {
        model.tasks.filter { !$0.deleted && $0.archivedAt == nil && (scope.isEmpty || $0.boardId == scope) }
    }
    private var open: [WorkItem] { active.filter { $0.status != .done } }
    private var attention: [WorkItem] {
        if filter == .done {
            return DoneOrder.recent.ordered(active.filter { $0.status == .done },
                                          completionDate: \.completionDate, creationDate: \.creationDate)
        }
        let today = CalendarDay.today
        return open.filter { filter.matches($0, today: today) }.sorted {
            if $0.status == .todo || $1.status == .todo {
                if $0.status != $1.status { return $0.status == .todo }
                return TaskCreationOrder.precedes(urgent: $0.priority == .urgent, createdAt: $0.creationDate,
                                                  otherUrgent: $1.priority == .urgent, otherCreatedAt: $1.creationDate)
                    ?? ($0.id < $1.id)
            }
            return ($0.priority.rank, $0.dueDate ?? "9999", $0.position, $0.id) <
                ($1.priority.rank, $1.dueDate ?? "9999", $1.position, $1.id)
        }
    }

    var body: some View {
        ThemedScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                overview
                DashboardCapture(scope: scope)
                VStack(alignment: .leading, spacing: 15) {
                    sectionHeader("Task list")
                    attentionCard
                }
                VStack(alignment: .leading, spacing: 15) {
                    sectionHeader("Project overview", "\(active.count) current tasks · Completion is Done divided by total tasks.")
                    projectList
                }
                HStack {
                    Button("Archive", systemImage: "archivebox") { model.navigate(.archive) }
                    Button("Trash", systemImage: "trash") { model.navigate(.trash) }
                }
            }
            .padding(.horizontal, 35)
            .padding(.vertical, 31)
            .frame(maxWidth: 1540)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: scope) { _, _ in limit = 6 }
        .onChange(of: model.boards) { _, boards in
            if !scope.isEmpty && !boards.contains(where: { $0.id == scope }) { scope = "" }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 9) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                    .font(.system(size: 10)).tracking(0.9).foregroundStyle(palette.muted)
                Text("Your day, at a glance.")
                    .font(palette.display(40)).accessibilityAddTraits(.isHeader)
                Text(scope.isEmpty ? "What needs your attention across all your projects." :
                        "What needs your attention on \(model.projectName(scope)).")
                    .font(.system(size: 12)).foregroundStyle(palette.muted)
            }
            Spacer()
            BoardDropdown(selection: $scope, title: "Project", symbol: "folder",
                          choices: [""] + model.boards.map(\.id), compact: true) {
                $0.isEmpty ? "All projects" : model.projectName($0)
            }
            .frame(width: 190)
        }
    }

    private var overview: some View {
        let counts = progressCounts(active)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 37) {
                openCount
                VStack(alignment: .leading, spacing: 12) {
                    flowBar(counts)
                    HStack(spacing: 14) {
                        ForEach(ProgressBucket.allCases) { bucket in legend(bucket, counts[bucket, default: 0]) }
                        Spacer(minLength: 4)
                        completion(counts)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minWidth: 500)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack { openCount; Spacer(); completion(counts) }
                flowBar(counts)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), alignment: .leading)], spacing: 9) {
                    ForEach(ProgressBucket.allCases) { bucket in legend(bucket, counts[bucket, default: 0]) }
                }
            }
        }
        .padding(.vertical, 22)
        .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }

    private var openCount: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(open.count.formatted()).font(palette.display(54, weight: .medium)).monospacedDigit()
            Text("open \(open.count == 1 ? "task" : "tasks")").font(.system(size: 13)).foregroundStyle(palette.muted)
        }
        .fixedSize()
    }

    private func completion(_ counts: [ProgressBucket: Int]) -> some View {
        HStack(spacing: 8) {
            Text("Completion").foregroundStyle(palette.muted)
            Text("\(percent(counts[.done, default: 0], of: active.count))%").bold().monospacedDigit()
        }
        .font(.system(size: 12))
        .fixedSize()
    }

    private func show(_ option: Attention) {
        filter = option
        limit = 6
    }

    private var attentionCard: some View {
        LazyVStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Attention.allCases) { option in
                    let count = (option == .done ? active : open).filter { option.matches($0, today: CalendarDay.today) }.count
                    let selected = option == filter
                    let alert = (option == .overdue || option == .urgent) && count > 0
                    Button { show(option) } label: {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                filterCount(count, alert: alert)
                                filterLabel(option, alert: alert)
                            }
                            .fixedSize()
                            VStack(alignment: .leading, spacing: 2) {
                                filterCount(count, alert: alert)
                                filterLabel(option, alert: alert)
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                        .background(selected ? palette.card : palette.canvas)
                        .overlay(alignment: .top) {
                            if selected { Rectangle().fill(alert ? palette.danger : palette.accent).frame(height: 2) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(option.rawValue): \(count)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    if option != Attention.allCases.last { Rectangle().fill(palette.line).frame(width: 1) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(palette.line).frame(height: 1)
            if attention.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 25))
                    Text(filter == .done ? "No completed tasks yet." : "You’re all caught up.").fontWeight(.medium)
                    Text(filter == .done ? "Completed tasks appear here for seven days, then move to Archive." :
                            "Tasks that match this filter will appear here.").font(.caption)
                }
                .foregroundStyle(palette.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 31)
            }
            ForEach(attention.prefix(limit)) { item in
                DashboardTask(item: item)
                Rectangle().fill(palette.line).frame(height: 1)
            }
            if !attention.isEmpty {
                HStack {
                    if filter == .done {
                        Text("Recently completed first · Automatically archived after seven days.")
                            .font(.system(size: 11)).foregroundStyle(palette.muted)
                        Button("View Archive") { model.navigate(.archive) }
                    } else {
                        Text("Ignored tasks can be restored from Trash.")
                            .font(.system(size: 11)).foregroundStyle(palette.muted)
                    }
                    Spacer()
                    if attention.count > limit {
                        Button("Show more (\(attention.count - limit))") { limit += 6 }
                        if attention.count > limit + 6 {
                            Button("Show all \(attention.count)") { limit = attention.count }
                        }
                    } else if limit > 6 {
                        Button("Show fewer") { limit = 6 }
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
        }
        .clipShape(.rect(cornerRadius: 10))
        .surface(10)
    }

    private func filterCount(_ count: Int, alert: Bool) -> some View {
        Text(count.formatted())
            .font(palette.display(27, weight: .medium)).monospacedDigit()
            .foregroundStyle(alert ? palette.danger : palette.text)
    }

    private func filterLabel(_ option: Attention, alert: Bool) -> some View {
        Text(option.rawValue).font(.system(size: 11))
            .foregroundStyle(alert ? palette.danger : palette.muted)
    }

    private var projectList: some View {
        let columns = ProgressBucket.allCases.filter { $0 != .sent }
        return GeometryReader { geometry in
            ThemedScrollView(.horizontal, track: palette.card) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                    GridRow {
                        Text("Project").frame(minWidth: 125, maxWidth: .infinity, alignment: .leading)
                        Text("Tasks").frame(width: 38, alignment: .trailing)
                        Text("Status mix").frame(width: 86, alignment: .leading)
                        ForEach(columns) { bucket in
                            Text(bucket.rawValue)
                                .frame(width: bucket.columnWidth, alignment: .trailing)
                        }
                        Text("Completion").frame(width: 74, alignment: .trailing)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.muted)
                    .frame(height: 37)
                    Rectangle().fill(palette.line).frame(height: 1)
                    ForEach(projects) { board in
                        let items = active.filter { $0.boardId == board.id }
                        let counts = progressCounts(items)
                        GridRow {
                            Button {
                                model.navigate(.board(board.id))
                            } label: {
                                HStack(spacing: 7) {
                                    ProjectIcon(key: board.icon)
                                    Text(board.name).fontWeight(.semibold).lineLimit(1)
                                    Image(systemName: "arrow.up.right").font(.system(size: 8)).foregroundStyle(palette.muted)
                                }
                                .frame(minWidth: 125, maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open project \(board.name)")
                            tableCount(items.count).frame(width: 38, alignment: .trailing)
                            flowBar(counts, compact: true).frame(width: 86)
                            ForEach(columns) { bucket in
                                tableCount(counts[bucket, default: 0]).frame(width: bucket.columnWidth, alignment: .trailing)
                            }
                            Text("\(percent(counts[.done, default: 0], of: items.count))%")
                                .fontWeight(.semibold).frame(width: 74, alignment: .trailing)
                        }
                        .font(.system(size: 12)).monospacedDigit()
                        .frame(height: 41)
                        if board.id != projects.last?.id { Rectangle().fill(palette.line).frame(height: 1) }
                    }
                }
                .padding(.horizontal, 18)
                .frame(width: max(geometry.size.width, 682))
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(height: 37 + CGFloat(projects.count) * 42)
        .surface(10)
    }

    private func tableCount(_ count: Int) -> some View {
        Text(count.formatted()).foregroundStyle(count == 0 ? palette.muted : palette.text)
    }

    private func sectionHeader(_ title: String, _ description: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(palette.display(25)).accessibilityAddTraits(.isHeader)
            if let description {
                Text(description).font(.system(size: 12)).foregroundStyle(palette.muted)
            }
        }
    }

    private func progressCounts(_ tasks: [WorkItem]) -> [ProgressBucket: Int] {
        Dictionary(grouping: tasks, by: ProgressBucket.init).mapValues(\.count)
    }

    private func percent(_ done: Int, of total: Int) -> Int {
        total == 0 ? 0 : Int((Double(done) / Double(total) * 100).rounded())
    }

    @ViewBuilder
    private func legend(_ bucket: ProgressBucket, _ count: Int) -> some View {
        let item = HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(bucket.color(palette)).frame(width: 8, height: 8)
            Text(bucket.rawValue).foregroundStyle(bucket == .urgent && count > 0 ? bucket.color(palette) : palette.muted)
            Text(count.formatted()).fontWeight(.semibold).monospacedDigit()
        }
        .font(.system(size: 11))
        .fixedSize()
        if bucket == .urgent || bucket == .done {
            Button { show(bucket == .done ? .done : .urgent) } label: { item.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(bucket == .done ? "View Done tasks: \(count)" : "Filter Urgent to-dos: \(count)")
                .help(bucket == .done ? "View recently completed tasks" : "Show only Urgent tasks in To do")
        } else {
            item
        }
    }

    private func flowBar(_ counts: [ProgressBucket: Int], compact: Bool = false) -> some View {
        GeometryReader { geometry in
            let visible = ProgressBucket.allCases.filter { counts[$0, default: 0] > 0 }
            let total = counts.values.reduce(0, +)
            let gap: CGFloat = compact ? 1 : 2
            let minimum: CGFloat = compact ? 2 : 3
            let proportional = max(0, geometry.size.width - CGFloat(visible.count) * minimum - CGFloat(max(0, visible.count - 1)) * gap)
            HStack(spacing: gap) {
                ForEach(visible) { bucket in
                    let width = minimum + proportional * CGFloat(counts[bucket, default: 0]) / CGFloat(total)
                    if bucket == .urgent && !compact {
                        Button { show(.urgent) } label: {
                            Rectangle().fill(bucket.color(palette))
                        }
                        .buttonStyle(.plain)
                        .help("Show only Urgent to-dos")
                        .accessibilityHidden(true)
                        .frame(width: width)
                    } else {
                        Rectangle().fill(bucket.color(palette)).frame(width: width)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(palette.line.opacity(0.65))
        }
        .frame(height: compact ? 6 : 8)
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }

}

private struct DashboardCapture: View {
    private struct AgentDraft: Decodable {
        let details: SuggestedTaskDetails
        let projectId: String?
        let newProjectName: String?
        let priority: Priority?

        init(from decoder: Decoder) throws {
            details = try SuggestedTaskDetails(from: decoder)
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            projectId = try fields.decodeIfPresent(String.self, forKey: .projectId)
            newProjectName = try fields.decodeIfPresent(String.self, forKey: .newProjectName)
            priority = try? fields.decodeIfPresent(Priority.self, forKey: .priority)
        }

        private enum CodingKeys: String, CodingKey { case projectId, newProjectName, priority }
    }

    private struct PendingCapture {
        let details: SuggestedTaskDetails
        let project: String
        let newProjectName: String?
        let priority: Priority
        let drafted: Bool
    }

    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var idea = ""
    @State private var selectedProject: String?
    @State private var priority: Priority?
    @State private var saving = false
    @State private var feedback: String?
    @State private var failed = false
    @State private var requestKey = UUID()
    @State private var retryDraft: PendingCapture?

    let scope: String

    private var project: String? {
        let preferredProject = selectedProject ?? (scope.isEmpty ? model.selectedBoard : scope)
        return model.boards.first { $0.id == preferredProject }?.id ?? model.boards.first?.id
    }

    private var input: String { idea.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tooLong: Bool { input.utf16.count > SuggestedTaskDetails.captureLimit }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick add").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 10) {
                TextField("What needs doing?", text: $idea)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .surface(9)
                    .accessibilityLabel("To-do idea")
                    .onSubmit(add)
                BoardDropdown(selection: $selectedProject,
                              title: "Project for new task", symbol: "folder",
                              choices: [nil] + model.boards.map { Optional($0.id) }, compact: true) { id in
                    id.map(model.projectName) ?? "Auto"
                }
                    .frame(width: 176)
                BoardDropdown(selection: $priority, title: "Priority", symbol: "flag",
                              choices: [nil] + Priority.allCases.map(Optional.some), compact: true) {
                    $0?.label ?? "Auto"
                }
                    .frame(width: 158)
                Button(action: add) {
                    if saving {
                        ProgressView().controlSize(.small).accessibilityLabel("Adding to-do")
                    } else {
                        Label("Add to-do", systemImage: "plus")
                    }
                }
                .glassPrimary()
                .frame(minWidth: 96)
                .disabled(input.isEmpty || tooLong || project == nil || saving)
                .help(model.canUseAgents ? "Draft with your default task agent" : "Save your task")
            }
            .disabled(saving)
            if tooLong {
                Text("Keep your idea to 2,000 characters.").font(.caption).foregroundStyle(palette.danger)
            } else if let feedback {
                Text(feedback).font(.caption).foregroundStyle(failed ? palette.danger : palette.muted)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .onChange(of: idea) { resetRetry() }
        .onChange(of: priority) { resetRetry() }
        .onChange(of: selectedProject) { resetRetry() }
        .onChange(of: project) { resetRetry() }
        .onChange(of: scope) { selectedProject = nil }
        .onChange(of: model.boards.map(\.id)) { _, ids in
            if let selectedProject, !ids.contains(selectedProject) { self.selectedProject = nil }
        }
    }

    private func resetRetry() {
        requestKey = UUID()
        retryDraft = nil
        if failed { feedback = nil }
    }

    private func add() {
        guard !input.isEmpty, !tooLong, !saving, let fallbackProject = project else { return }
        let idea = input
        let autoProject = selectedProject == nil
        let selectedPriority = priority
        let key = requestKey
        let previousDraft = retryDraft
        saving = true
        model.isQuickAdding = true
        feedback = nil
        failed = false
        Task {
            defer {
                saving = false
                model.isQuickAdding = false
            }
            let capture: PendingCapture
            if let previousDraft {
                capture = previousDraft
            } else {
                let draft: AgentDraft?
                if model.canUseAgents {
                    draft = try? await model.service.call("native_draft_task", [
                        "idea": idea, "autoProject": autoProject, "autoPriority": selectedPriority == nil
                    ])
                } else { draft = nil }
                let details = draft.flatMap { $0.details.isUsableForCapture ? $0.details : nil }
                let suggestedProject = autoProject ? draft?.projectId : nil
                let newProjectName = autoProject ? draft?.newProjectName.flatMap { $0.isEmpty ? nil : $0 } : nil
                let destination = model.boards.first { $0.id == suggestedProject }?.id ?? fallbackProject
                capture = PendingCapture(details: details ?? .fromIdea(idea),
                                         project: destination, newProjectName: newProjectName,
                                         priority: selectedPriority ?? draft?.priority ?? .none,
                                         drafted: details != nil)
            }
            do {
                _ = try await model.saveNewTask([
                    "requestKey": key.uuidString, "boardId": capture.project, "status": WorkStatus.todo.rawValue,
                    "priority": capture.priority.rawValue, "title": capture.details.title,
                    "issueType": IssueType.inferred(from: idea).rawValue,
                    "notes": capture.details.notes, "definitionOfDone": capture.details.definitionOfDone
                ], newProjectName: capture.newProjectName)
                self.idea = ""
                selectedProject = nil
                priority = nil
                feedback = capture.drafted || !model.canUseAgents ? nil : "Agent drafting was unavailable. Your original idea was saved."
            } catch {
                if key == requestKey { retryDraft = capture }
                failed = true
                feedback = error.localizedDescription
            }
        }
    }
}

private struct DashboardTask: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    let item: WorkItem
    var assigned: Bool { model.workspace?.agentAssignments[item.id] != nil }

    var body: some View {
        HStack(spacing: 11) {
            Button { model.select(item) } label: {
                HStack(spacing: 11) {
                    Image(systemName: item.status.symbol).foregroundStyle(palette.muted)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            if item.kind == .bug { IssueTypeBadge(.bug, tint: palette.actionAccent) }
                            Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        }
                        Text([model.projectName(item.boardId), item.status.rawValue, assigned ? "Agent task" : nil]
                            .compactMap { $0 }.joined(separator: "  ·  "))
                            .font(.system(size: 10)).foregroundStyle(palette.muted).lineLimit(1)
                        if let date = item.status == .done ? item.completionDate : item.creationDate {
                            Text("\(item.status == .done ? "Completed" : "Created") \(date.formatted(date: .abbreviated, time: .omitted))")
                                .font(.system(size: 10)).foregroundStyle(palette.muted)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(item.title)")
            if item.status != .done, let label = item.dueLabel {
                Label(item.dueDate == CalendarDay.today ? "Due today" : item.late ? "Overdue · \(label)" : "Due \(label)",
                      systemImage: "calendar")
                    .font(.system(size: 10))
                    .foregroundStyle(item.late ? palette.danger : palette.muted)
                    .lineLimit(1)
            }
            if item.status != .done {
                BoardDropdown(selection: Binding(get: { item.priority }, set: { priority in
                    model.perform {
                        var input = item.write
                        input["priority"] = priority.rawValue
                        try await model.mutate("update_task", input)
                    }
                }), title: "Priority for \(item.title)", symbol: "chart.bar.fill", choices: Priority.allCases,
                              compact: true, symbolColor: item.priority.color(palette.dark), label: \.label)
                    .frame(width: 128)
            }
            Button {
                if item.status == .done { model.move(item, to: .todo) }
                else if assigned { model.select(item) }
                else { model.move(item, to: .done) }
            } label: {
                Label(item.status == .done ? "Reopen" : assigned ? "Review" : "Complete",
                      systemImage: item.status == .done ? "arrow.uturn.backward" : assigned ? "arrow.up.right" : "checkmark")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.muted)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(item.status == .done ? "Reopen \(item.title)" : assigned ? "Review \(item.title)" : "Complete \(item.title)")
            IconButton(symbol: "trash", label: "Move \(item.title) to Trash") { model.trash(item) }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 64)
    }
}
