import SwiftUI

struct WorkspaceView: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.colorScheme) private var systemScheme
    private var theme: Theme { model.workspace?.theme ?? .system }
    private var palette: Palette {
        Palette(theme: theme == .system ? (systemScheme == .dark ? .graphite : .light) : theme)
    }

    private var canPresentReview: Bool {
        model.isWorkspaceWindowKey && !model.isolatedProfile && model.workspace != nil &&
            model.startupError == nil && model.sheet == nil && model.notice == nil &&
            !model.draftDirty && !model.isQuickAdding && !model.agentChat.busy &&
            model.createdTask == nil && model.reviewMilestone.isDue
    }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            if model.showsSidebar {
                sidebar
                Rectangle().fill(palette.line).frame(width: 1)
            }
            VStack(spacing: 0) {
                if model.workspaceLocked {
                    ContentUnavailableView {
                        Label("Workspace already open", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("Quit the other copy, then click Retry.\nIf it’s running in the background, find it in\nActivity Monitor and choose Quit.")
                    } actions: {
                        Button("Retry") { model.retryWorkspace?() }
                            .glassPrimary()
                    }
                } else if let error = model.startupError {
                    ContentUnavailableView("Could not open the workspace", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if model.workspace == nil {
                    ProgressView("Opening OpenTalon…")
                } else {
                    HStack {
                        if model.page == .about {
                            HStack(spacing: 9) {
                                Button("Workspace") { model.navigate(.dashboard) }
                                    .buttonStyle(.plain)
                                    .fontWeight(.semibold)
                                Image(systemName: "chevron.right").font(.system(size: 8))
                                    .accessibilityHidden(true)
                                Text("About OpenTalon").foregroundStyle(palette.muted)
                            }
                            .font(.system(size: 12))
                            .padding(.leading, 12)
                        }
                        Spacer()
                        Button("Ask my agent", systemImage: "bubble.left.and.text.bubble.right") {
                            model.sheet = .agentChat
                        }
                        .keyboardShortcut("k", modifiers: [.command, .shift])
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
                    if let banner = model.banner { bannerView(banner) }
                    HStack(spacing: 0) {
                        switch model.page {
                        case .dashboard: DashboardView()
                        case .all, .board: KanbanView()
                        case .archive: ArchiveView()
                        case .trash: TrashView()
                        case .about: AboutView()
                        }
                        if let task = model.selected {
                            Rectangle().fill(palette.line).frame(width: 1)
                            TaskDetails(item: task).id(task.id).frame(width: 346)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 980, minHeight: 640)
        .background(palette.canvas)
        .foregroundStyle(palette.text)
        .tint(palette.accent)
        .overlay(alignment: .bottomTrailing) {
            if let task = model.createdTask, model.sheet == nil {
                TaskCreatedToast(task: task)
                    .id(task.id)
                    .padding(20)
            }
        }
        .buttonStyle(GlassActionStyle())
        .environment(\.palette, palette)
        .environment(\.colorScheme, palette.dark ? .dark : .light)
        .sheet(isPresented: Binding(get: { model.sheet != nil }, set: { if !$0 { model.sheet = nil; model.pendingSend = nil } })) {
            SheetContent()
                .environment(\.palette, palette)
                .environment(\.colorScheme, palette.dark ? .dark : .light)
                .environment(model)
        }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
        .task(id: canPresentReview) {
            guard canPresentReview else { return }
            do { try await Task.sleep(for: .seconds(11)) } catch { return }
            guard !Task.isCancelled, canPresentReview, model.reviewMilestone.takeRequest() else { return }
            model.sheet = .review
        }
        .onExitCommand {
            if model.selection != nil && model.canLeave() { model.selection = nil }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            nav("Dashboard", "square.grid.2x2", .dashboard)
            nav("All tasks", "list.bullet.rectangle", .all)
            HStack {
                Text("Projects").font(.system(size: 12)).foregroundStyle(palette.muted)
                Spacer()
                IconButton(symbol: "plus", label: "New project") { model.sheet = .project(nil) }
                    .disabled(model.workspace == nil)
            }
            .padding(.leading, 14)
            .padding(.trailing, 5)
            .padding(.top, 8)
            ThemedScrollView(track: palette.sidebar) {
                LazyVStack(spacing: 3) {
                    ForEach(model.boards) { board in
                        SidebarButton(title: board.name, symbol: "", selected: model.page == .board(board.id), project: board) {
                            model.navigate(.board(board.id))
                        }
                        .contextMenu { ProjectActions(board: board) }
                    }
                    SidebarButton(title: "New project", symbol: "plus", selected: false) {
                        model.sheet = .project(nil)
                    }
                    .disabled(model.workspace == nil)
                }
            }
            Rectangle().fill(palette.line).frame(height: 1).padding(.vertical, 8)
            nav("Archive", "archivebox", .archive)
            nav("Trash", "trash", .trash)
            nav("About OpenTalon", "info.circle", .about)
            SidebarButton(title: "Settings", symbol: "gearshape", selected: false) {
                model.sheet = .settings
            }
            .disabled(model.workspace == nil)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .frame(width: 234)
        .frame(maxHeight: .infinity)
        .background(palette.sidebar)
    }

    private func nav(_ title: String, _ icon: String, _ page: WorkspacePage) -> some View {
        SidebarButton(title: title, symbol: icon, selected: model.page == page) { model.navigate(page) }
    }

    private func bannerView(_ title: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            if let task = model.undoTrash {
                Button("Undo") { model.restore(task) }.buttonStyle(.link)
            }
            Spacer()
            IconButton(symbol: "xmark", label: "Dismiss message") {
                model.banner = nil
                model.undoTrash = nil
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 3)
        .background(palette.active)
    }
}

private struct TaskCreatedToast: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var hovered = false
    let task: WorkItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(palette.flow(.done))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Task created").font(.system(size: 13, weight: .semibold))
                Text(task.title).font(.caption).foregroundStyle(palette.muted).lineLimit(1)
                Text("\(model.projectName(task.boardId)) · \(task.priority.label)")
                    .font(.caption).foregroundStyle(palette.muted).lineLimit(1)
            }
            .frame(maxWidth: 250, alignment: .leading)
            Button("Open task") { model.openCreatedTask(task.id) }
            IconButton(symbol: "xmark", label: "Dismiss notification") { model.createdTask = nil }
        }
        .padding(12)
        .surface(12, fill: palette.panel)
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .onHover { hovered = $0 }
        .task(id: hovered) {
            guard !hovered else { return }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            if model.createdTask?.id == task.id { model.createdTask = nil }
        }
    }
}

private struct SidebarButton: View {
    @Environment(\.palette) private var palette
    @State private var hovered = false
    let title: String
    let symbol: String
    let selected: Bool
    var project: Board? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Group {
                    if let project { ProjectIcon(key: project.icon, size: 13) }
                    else { Image(systemName: symbol).accessibilityHidden(true) }
                }
                .frame(width: 16)
                .foregroundStyle(selected ? palette.text : palette.muted)
                Text(title).fontWeight(selected ? .semibold : .regular).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .frame(height: 39)
            .background(selected ? palette.active : hovered ? palette.hover : .clear, in: .rect(cornerRadius: 7))
            .overlay(alignment: .leading) {
                if selected { RoundedRectangle(cornerRadius: 2).fill(palette.accent).frame(width: 3, height: 23) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(title)
    }
}

struct ProjectActions: View {
    @Environment(WorkspaceModel.self) private var model
    let board: Board
    var body: some View {
        Button("Rename project") { model.sheet = .project(board) }
        Button("Change icon") { model.sheet = .icon(board) }
        if model.boards.count > 1 {
            Divider()
            Button("Delete empty project", role: .destructive) {
                model.perform {
                    try await model.mutate("delete_board", ["id": board.id, "expectedRevision": board.revision])
                }
            }
            .disabled(model.tasks.contains { $0.boardId == board.id })
        }
    }
}

struct SearchField: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    @FocusState private var focused: Bool
    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
            TextField("Search tasks", text: $model.search)
                .textFieldStyle(.plain)
                .focused($focused)
                .accessibilityLabel("Search tasks")
            if !model.search.isEmpty {
                Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .frame(width: 175)
        .glassSearchSurface()
        .onChange(of: model.searchSignal) { _, _ in focused = true }
        .onAppear { if model.searchSignal > 0 { focused = true } }
    }
}

private struct ArchiveView: View {
    private struct BulkMove {
        let ids: [String]
        let revision: Int
    }

    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var movePreview: BulkMove?
    @State private var confirmMove = false

    private var archived: [WorkItem] {
        model.tasks.filter { !$0.deleted && $0.archivedAt != nil }
    }

    private var items: [WorkItem] {
        archived.filter { model.matches($0, filterPriority: false) }
            .sorted { ($0.archivedAt ?? "") > ($1.archivedAt ?? "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Archive").font(palette.display(35))
                    Text("Completed tasks move here after seven days.")
                        .font(.system(size: 12)).foregroundStyle(palette.muted)
                }
                Spacer()
                SearchField()
                Menu("Archive actions") {
                    Button("Move All to Trash") {
                        guard model.canLeave(), let revision = model.workspace?.revision else { return }
                        movePreview = BulkMove(ids: archived.map(\.id), revision: revision)
                        confirmMove = true
                    }
                    Button("Delete All Permanently…", role: .destructive) {
                        guard model.canLeave() else { return }
                        let ids = archived.map(\.id)
                        model.perform { try await model.preview("purge_archived_tasks", taskIds: ids) }
                    }
                }
                .disabled(archived.isEmpty)
            }
            if items.isEmpty {
                ContentUnavailableView("No archived tasks", systemImage: "archivebox",
                                       description: model.search.isEmpty ? nil : Text("Try a different search."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ThemedScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(items) { item in
                            HStack {
                                Button { model.select(item) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.title).fontWeight(.medium)
                                        Text(model.projectName(item.boardId))
                                            .font(.caption).foregroundStyle(palette.muted)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Button("Reopen") { model.move(item, to: .todo) }
                                Menu {
                                    Button("Move to Trash", role: .destructive) { model.trash(item) }
                                    Button("Delete permanently", role: .destructive) {
                                        guard model.canLeave() else { return }
                                        model.perform { try await model.preview("purge_archived_tasks", taskIds: [item.id]) }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                }
                                .accessibilityLabel("More actions for \(item.title)")
                            }
                            .padding(13)
                            .surface()
                        }
                    }
                }
            }
        }
        .padding(35)
        .alert("Move all archived tasks to Trash?", isPresented: $confirmMove, presenting: movePreview) { move in
            Button("Cancel", role: .cancel) {}
            Button("Move All to Trash") {
                model.perform {
                    try await model.mutate("manage_archived_tasks", [
                        "taskIds": move.ids, "expectedRevision": move.revision, "permanently": false,
                    ])
                    model.banner = "Archived tasks moved to Trash"
                }
            }
        } message: { move in
            Text("You can restore these \(move.ids.count) archived items from Trash.")
        }
    }
}

struct TrashView: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    var items: [WorkItem] {
        model.tasks.filter { $0.deleted && model.matches($0, filterPriority: false) }
            .sorted { ($0.deletedAt ?? "") > ($1.deletedAt ?? "") }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Trash").font(palette.display(35))
                    Text("Restore a task or permanently remove it.").font(.system(size: 12)).foregroundStyle(palette.muted)
                }
                Spacer()
                SearchField()
                Button("Empty Trash", role: .destructive) {
                    model.perform { try await model.preview("empty_trash") }
                }
                .disabled(!model.tasks.contains(where: \.deleted))
            }
            if items.isEmpty {
                ContentUnavailableView("No tasks in Trash", systemImage: "trash",
                                       description: Text(model.search.isEmpty ? "Deleted tasks appear here." : "Try a different search."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ThemedScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(items) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.title).fontWeight(.medium)
                                    Text(model.projectName(item.boardId)).font(.caption).foregroundStyle(palette.muted)
                                }
                                Spacer()
                                Button("Restore") { model.restore(item) }
                                IconButton(symbol: "trash", label: "Permanently delete \(item.title)") {
                                    model.perform { try await model.preview("purge_tasks", taskIds: [item.id]) }
                                }.foregroundStyle(palette.danger)
                            }
                            .padding(13)
                            .surface()
                        }
                    }
                }
            }
        }
        .padding(35)
    }
}
