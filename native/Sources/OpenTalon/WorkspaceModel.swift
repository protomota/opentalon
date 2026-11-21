import AppKit
import CompanionCore
import Observation
import SwiftUI

enum WorkspaceSheet: Identifiable {
    case settings, review, agentChat, project(Board?), task(WorkStatus), send, icon(Board), preview(Preview)
    var id: String {
        switch self {
        case .settings: "settings"
        case .review: "review"
        case .agentChat: "agent-chat"
        case .project: "project"
        case .task: "task"
        case .send: "send"
        case .icon: "icon"
        case .preview: "preview"
        }
    }
}

struct ViewOptions: Codable {
    var priority: Priority?
    var sort: String = BoardSort.manual.rawValue
    var doneOrder: DoneOrder?
}

struct Notice: Identifiable {
    var id = UUID()
    var title: String
    var message: String
}

@MainActor
@Observable
final class WorkspaceModel {
    @ObservationIgnored let service = Service()
    @ObservationIgnored let profile: URL
    @ObservationIgnored let phoneCompanion: PhoneCompanion
    let reviewMilestone: OpenTalonReviewMilestone
    let agentChat: AgentChat
    let taskAssistant: MacTaskAssistant
    @ObservationIgnored var appearanceChanged: ((Theme) -> Void)?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults?
    var workspace: Workspace?
    var page: WorkspacePage = .dashboard
    var showsSidebar = true
    var sheet: WorkspaceSheet?
    var selection: String?
    var search = ""
    var searchSignal = 0
    var notice: Notice?
    var startupError: String?
    var workspaceLocked = false
    @ObservationIgnored var retryWorkspace: (() -> Void)?
    var banner: String?
    var createdTask: WorkItem?
    var isQuickAdding = false
    var isWorkspaceWindowKey = false
    var draftDirty = false
    var pendingSend: (name: String, input: [String: Any], title: String)?
    var options: [String: ViewOptions] = [:]
    var undoTrash: WorkItem?
    var connectionSignal = 0
    var backupSignal = 0
    var isolatedProfile: Bool { defaults == nil }

    init(profile: URL, useDefaults: Bool) {
        self.profile = profile
        agentChat = AgentChat(profile: profile)
        taskAssistant = MacTaskAssistant(profile: profile)
        phoneCompanion = PhoneCompanion(profile: profile, isolated: !useDefaults)
        defaults = useDefaults ? .standard : nil
        reviewMilestone = OpenTalonReviewMilestone(defaults: defaults)
        if let data = defaults?.data(forKey: "BoardOptions"),
           let saved = try? JSONDecoder().decode([String: ViewOptions].self, from: data) {
            options = saved
        }
        service.onReady = { [weak self] in
            guard let self else { return }
            self.scheduleRefresh()
            if useDefaults || self.phoneCompanion.usesLocalTransport { self.phoneCompanion.start(service: self.service) }
        }
        service.onChange = { [weak self] in self?.scheduleRefresh() }
        service.onBackupChange = { [weak self] in self?.backupSignal += 1 }
        service.onChatActivity = { [weak self] name, title in self?.agentChat.record(name, title: title) }
        service.onFailure = { [weak self] error in
            if self?.startupError == nil { self?.startupError = error.message }
        }
    }

    var boards: [Board] { workspace?.boards ?? [] }
    var canUseAgents: Bool { workspace?.agentConnectionReady == true }
    var editableStatuses: [WorkStatus] { WorkStatus.allCases.filter { $0 != .sent || canUseAgents } }

    func requireAgentConnection() throws {
        guard canUseAgents else {
            throw ServiceFailure(code: "MCP_DISABLED", message: "Connect MCP in Settings on your Mac to use agents.")
        }
    }
    var tasks: [WorkItem] { workspace?.tasks ?? [] }
    var board: Board? {
        guard case .board(let id) = page else { return nil }
        return boards.first { $0.id == id }
    }
    var selected: WorkItem? {
        tasks.first { $0.id == selection && !$0.deleted }
    }
    var selectedBoard: String? { workspace?.selectedBoard ?? boards.first?.id }
    var sort: BoardSort {
        get { BoardSort(rawValue: options[page.storageKey]?.sort ?? "") ?? .manual }
        set { updateOptions { $0.sort = newValue.rawValue } }
    }
    var doneOrder: DoneOrder {
        get { options[page.storageKey]?.doneOrder ?? .recent }
        set { updateOptions { $0.doneOrder = newValue } }
    }
    var priority: Priority? {
        get { options[page.storageKey]?.priority }
        set { updateOptions { $0.priority = newValue } }
    }

    private func updateOptions(_ change: (inout ViewOptions) -> Void) {
        change(&options[page.storageKey, default: ViewOptions()])
        defaults?.set(try? JSONEncoder().encode(options), forKey: "BoardOptions")
    }

    func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(55))
            guard let self else { return }
            refreshTask = nil
            do { try await refresh() }
            catch { if workspace == nil { startupError = error.localizedDescription } }
        }
    }

    func refresh() async throws {
        let previousTheme = workspace?.theme
        workspace = try await service.call("snapshot")
        if !canUseAgents {
            if case .agentChat = sheet { sheet = nil }
            if case .send = sheet { sheet = nil; pendingSend = nil }
        }
        if let theme = workspace?.theme, theme != previousTheme { appearanceChanged?(theme) }
        if case .board(let id) = page, !boards.contains(where: { $0.id == id }) {
            page = .dashboard
        }
        if selection != nil && selected == nil { selection = nil }
    }

    func write<Response: Decodable>(_ action: String, _ input: [String: Any]) async throws -> Response {
        var fields = input
        if fields["requestKey"] == nil { fields["requestKey"] = "mac:" + UUID().uuidString }
        let result: Response = try await service.call(action, fields)
        try await refresh()
        return result
    }

    func mutate(_ action: String, _ input: [String: Any]) async throws {
        if action == "create_task" {
            _ = try await saveNewTask(input)
        } else {
            let _: EmptyResponse = try await write(action, input)
        }
    }

    func saveNewTask(_ input: [String: Any], newProjectName: String? = nil) async throws -> WorkItem {
        var fields = input
        if fields["requestKey"] == nil { fields["requestKey"] = "mac:" + UUID().uuidString }
        fields["newProjectName"] = newProjectName
        let result: ItemResponse = try await service.call(newProjectName == nil ? "create_task" : "capture_task", fields)
        scheduleRefresh()
        reviewMilestone.recordActivity()
        createdTask = result.task
        return result.task
    }

    func openCreatedTask(_ id: String) {
        guard canLeave() else { return }
        perform {
            try await self.refresh()
            guard self.canLeave() else { return }
            if self.createdTask?.id == id { self.createdTask = nil }
            guard let item = self.tasks.first(where: { $0.id == id && !$0.deleted }) else {
                self.banner = "This task is no longer available."
                return
            }
            self.navigate(.board(item.boardId))
            self.select(item)
        }
    }

    func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await operation() }
            catch { show(error) }
        }
    }

    func show(_ error: Error) {
        notice = Notice(title: "OpenTalon", message: error.localizedDescription)
    }

    func canLeave() -> Bool {
        guard draftDirty else {
            return true
        }
        banner = "Save or discard your task changes before leaving."
        return false
    }

    func navigate(_ destination: WorkspacePage) {
        guard canLeave() else { return }
        page = destination
        selection = nil
        search = ""
        banner = nil
        if case .board(let id) = destination, id != selectedBoard {
            perform { try await self.preferences(["selectedBoard": id]) }
        }
    }

    func preferences(_ fields: [String: Any]) async throws {
        guard let revision = workspace?.preferencesRevision else { return }
        var input = fields
        input["expectedRevision"] = revision
        try await mutate("set_preferences", input)
    }

    func select(_ item: WorkItem) {
        guard selection == item.id || canLeave() else { return }
        selection = item.id
        banner = nil
    }

    func findTasks() {
        if page == .dashboard || page == .about || page == .assistant { navigate(.all) }
        searchSignal += 1
    }

    func newTask(_ status: WorkStatus = .todo) {
        guard canLeave(), workspace != nil, status != .sent || canUseAgents else { return }
        sheet = .task(status)
    }

    func projectName(_ id: String) -> String {
        boards.first { $0.id == id }?.name ?? "Project"
    }

    func column(_ status: WorkStatus, filtered: Bool = true, sorting: BoardSort? = nil) -> [WorkItem] {
        let boardId = board?.id
        let base = tasks.filter {
            !$0.deleted && $0.archivedAt == nil && $0.status == status && (boardId == nil || $0.boardId == boardId)
        }
        if status == .done, sorting == nil, doneOrder != .manual {
            return doneOrder.ordered(base.filter { !filtered || matches($0) },
                                     completionDate: \.completionDate, creationDate: \.creationDate)
        }
        let selectedSort = sorting ?? (status == .done ? .manual : sort)
        if selectedSort == .newest {
            return newestFirst(base.filter { !filtered || matches($0) })
        }
        if status == .todo && sorting == nil {
            let visible = base.filter { !filtered || matches($0) }
            let dated = visible.map { (item: $0, date: $0.creationDate) }
            let newestFirst = dated.sorted { first, second in
                let order = TaskCreationOrder.precedes(urgent: first.item.priority == .urgent, createdAt: first.date,
                                                       otherUrgent: second.item.priority == .urgent, otherCreatedAt: second.date)
                return order ?? (first.item.id < second.item.id)
            }
            return newestFirst.map(\.item)
        }
        let boardOrder = base.sorted {
            ($0.position, $0.id) < ($1.position, $1.id)
        }
        let ordered = page == .all ? orderAcrossProjects(boardOrder) : boardOrder
        return ordered.enumerated()
            .filter { !filtered || matches($0.element) }
            .sorted {
                let first = selectedSort.rank($0.element.priority)
                let second = selectedSort.rank($1.element.priority)
                return selectedSort != .manual && first != second ? first < second : $0.offset < $1.offset
            }
            .map(\.element)
    }

    var recentTasks: [WorkItem] {
        newestFirst(tasks.filter { !$0.deleted && $0.archivedAt == nil && matches($0, filterPriority: false) })
    }

    private func newestFirst(_ tasks: [WorkItem]) -> [WorkItem] {
        tasks.map { (task: $0, date: $0.creationDate ?? .distantPast) }
            .sorted { ($0.date, $0.task.id) > ($1.date, $1.task.id) }
            .map(\.task)
    }

    private func orderAcrossProjects(_ column: [WorkItem]) -> [WorkItem] {
        let byId = Dictionary(uniqueKeysWithValues: column.map { ($0.id, $0) })
        let queues = Dictionary(grouping: column, by: \.boardId)
        var placed: Set<String> = []
        var slots = (workspace?.allTasksOrder ?? []).compactMap { id -> String? in
            guard let item = byId[id], placed.insert(id).inserted else { return nil }
            return item.boardId
        }
        for board in boards {
            slots.append(contentsOf: (queues[board.id] ?? []).filter { !placed.contains($0.id) }.map(\.boardId))
        }
        var offsets: [String: Int] = [:]
        return slots.compactMap { id in
            let index = offsets[id, default: 0]
            offsets[id] = index + 1
            return queues[id]?[index]
        }
    }

    func matches(_ item: WorkItem, filterPriority: Bool = true) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (!filterPriority || priority == nil || item.priority == priority) &&
            (query.isEmpty || item.reference.localizedCaseInsensitiveContains(query) ||
             item.kind.rawValue.localizedCaseInsensitiveContains(query) ||
             item.title.localizedCaseInsensitiveContains(query) || item.notes.localizedCaseInsensitiveContains(query))
    }

    func createItem(title: String, notes: String, definitionOfDone: String, project: String,
                    status: WorkStatus, priority: Priority, planMarkdown: String? = nil, issueType: IssueType = .issue) async throws {
        var fields: [String: Any] = [
            "boardId": project, "title": title, "notes": notes, "definitionOfDone": definitionOfDone,
            "status": status.rawValue, "priority": priority.rawValue, "issueType": issueType.rawValue
        ]
        fields["planMarkdown"] = planMarkdown
        try await sendable("create_task", fields, title: title, choosingModel: status == .sent)
    }

    func move(_ item: WorkItem, to status: WorkStatus, board boardId: String? = nil,
              anchor: String? = nil, before: Bool = true) {
        guard canLeave(), anchor != item.id else { return }
        perform {
            var fields = item.write
            fields["status"] = status.rawValue
            fields["boardId"] = boardId ?? item.boardId
            if let anchor { fields[before ? "beforeId" : "afterId"] = anchor }
            try await self.sendable("move_task", fields, title: item.title, choosingModel: status == .sent && item.status != .sent)
            if item.status != .done && status == .done { self.reviewMilestone.recordActivity() }
            if let boardId, case .board = self.page, self.board?.id != boardId, self.pendingSend == nil {
                self.navigate(.board(boardId))
            }
        }
    }

    func drop(_ id: String, in status: WorkStatus, anchor: String?, before: Bool) -> Bool {
        guard status != .sent || canUseAgents, canLeave(), id != anchor, let item = tasks.first(where: { $0.id == id && !$0.deleted }),
              let workspace else { return false }
        if status == .todo {
            guard item.status != .todo else { return false }
            move(item, to: status)
            return true
        }
        if status == .done, doneOrder != .manual {
            guard item.status != .done else { return false }
            move(item, to: .done)
            return true
        }
        let selectedSort = status == .done ? .manual : sort
        let sorted = selectedSort != .manual && item.status == status
        let all = page == .all
        guard all || sorted else {
            move(item, to: status, anchor: selectedSort == .manual ? anchor : nil, before: before)
            return true
        }
        let key = page.storageKey
        let useAnchor = sorted || selectedSort == .manual ? anchor : nil
        var ids = column(status, filtered: false, sorting: sorted ? selectedSort : .manual).map(\.id).filter { $0 != id }
        let index = useAnchor.flatMap { ids.firstIndex(of: $0) }.map { $0 + (before ? 0 : 1) } ?? ids.endIndex
        ids.insert(id, at: index)
        var fields: [String: Any] = ["status": status.rawValue, "expectedRevision": workspace.revision, "taskIds": ids]
        if !all { fields["boardId"] = item.boardId }
        if all && status == .sent && item.status != .sent {
            stageSend("reorder_all_tasks", fields, title: item.title)
            return true
        }
        perform {
            do {
                try await self.mutate(all ? "reorder_all_tasks" : "reorder_tasks", fields)
                if item.status != .done && status == .done { self.reviewMilestone.recordActivity() }
                if sorted {
                    self.options[key, default: ViewOptions()].sort = BoardSort.manual.rawValue
                    self.defaults?.set(try? JSONEncoder().encode(self.options), forKey: "BoardOptions")
                    self.banner = "Manual order saved"
                }
            } catch let failure as ServiceFailure where self.isSetup(failure) {
                var move = item.write
                move["status"] = status.rawValue
                move["boardId"] = item.boardId
                self.stageSend("move_task", move, title: item.title)
            }
        }
        return true
    }

    private func isSetup(_ error: ServiceFailure) -> Bool {
        ["AGENT_SETUP_REQUIRED", "AGENT_NOT_INSTALLED", "MCP_DISABLED"].contains(error.code)
    }

    private func stageSend(_ name: String, _ fields: [String: Any], title: String) {
        guard canUseAgents else { return }
        var fields = fields
        if fields["requestKey"] == nil { fields["requestKey"] = "mac:" + UUID().uuidString }
        pendingSend = (name, fields, title)
        sheet = .send
    }

    private func sendable(_ name: String, _ fields: [String: Any], title: String, choosingModel: Bool) async throws {
        if choosingModel {
            try requireAgentConnection()
            stageSend(name, fields, title: title)
            return
        }
        var fields = fields
        fields["requestKey"] = "mac:" + UUID().uuidString
        do { try await mutate(name, fields) }
        catch let failure as ServiceFailure where isSetup(failure) { stageSend(name, fields, title: title) }
    }

    func finishSend(agent: PhoneAgent?, model: String?, comment: String = "") async throws {
        try requireAgentConnection()
        guard let intent = pendingSend else { return }
        var input = intent.input
        input["agent"] = agent?.rawValue
        input["model"] = model
        let comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !comment.isEmpty { input["dispatchComment"] = comment }
        if let id = input["id"] as? String {
            let current: ItemResponse = try await service.call("get_task", ["id": id])
            guard !current.task.deleted else {
                throw ServiceFailure(code: "NOT_FOUND", message: "This task is in Trash.")
            }
            input["expectedRevision"] = current.task.revision
        }
        try await mutate(intent.name, input)
        pendingSend = nil
        sheet = nil
    }

    func trash(_ item: WorkItem) {
        guard canLeave() else { return }
        perform {
            let result: ItemResponse = try await self.write("trash_task", item.write)
            self.undoTrash = result.task
            self.banner = "Task moved to Trash"
        }
    }

    func restore(_ item: WorkItem) {
        perform {
            try await self.mutate("restore_task", item.write)
            self.undoTrash = nil
            self.banner = "Task restored"
        }
    }

    func preview(_ action: String, path: String? = nil, taskIds: [String]? = nil) async throws {
        var input: [String: Any] = ["action": action]
        input["path"] = path
        input["taskIds"] = taskIds
        let result: Preview = try await service.call("preview_destructive_action", input)
        sheet = .preview(result)
    }
}
