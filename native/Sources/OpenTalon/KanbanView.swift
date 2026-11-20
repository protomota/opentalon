import CompanionCore
import SwiftUI

struct KanbanView: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var drag = BoardDrag()
    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                if let board = model.board {
                    ProjectIcon(key: board.icon, size: 23).foregroundStyle(palette.muted)
                }
                Text(model.board?.name ?? "All tasks")
                    .font(palette.display(35))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
                if let board = model.board {
                    Menu { ProjectActions(board: board) } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .glassControl(in: Circle(), fill: palette.card)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Project options")
                }
                Spacer()
                GlassCommandGroup {
                    HStack(spacing: 9) {
                        SearchField()
                        Button { model.newTask() } label: { Label("New task", systemImage: "plus") }
                            .glassPrimary()
                    }
                }
            }
            .padding(.horizontal, 27)
            .padding(.top, 28)
            .padding(.bottom, 22)

            HStack(spacing: 10) {
                BoardDropdown(selection: $model.priority, title: "Priority", symbol: "line.3.horizontal.decrease",
                              choices: [nil] + Priority.allCases.map(Optional.some)) {
                    $0?.label ?? "All priorities"
                }
                .frame(idealWidth: 176, maxWidth: 176)

                BoardDropdown(selection: $model.sort, title: "Order", symbol: "arrow.up.arrow.down",
                              choices: BoardSort.allCases, label: \.title)
                    .frame(idealWidth: 207, maxWidth: 207)

                Spacer(minLength: 4)
                let count = WorkStatus.allCases.reduce(0) { $0 + model.column($1).count }
                Text("\(count) \(count == 1 ? "task" : "tasks")")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.muted)
                    .monospacedDigit()
                    .fixedSize()
            }
            .padding(.horizontal, 27)
            .padding(.bottom, 18)

            GeometryReader { geometry in
                let width = max(177, (geometry.size.width - 54 - 3 * 15) / 4)
                ThemedScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 15) {
                        ForEach(WorkStatus.allCases) { status in
                            ColumnView(status: status, drag: drag)
                                .frame(width: width)
                                .frame(height: max(220, geometry.size.height - 23))
                        }
                    }
                    .padding(.horizontal, 27)
                    .padding(.bottom, 23)
                }
                .dragFrame(.viewport)
            }
        }
        .coordinateSpace(name: BoardDrag.space)
        .onPreferenceChange(DragFrames.self) { frames in
            drag.setFrames(frames)
        }
    }
}

@Observable
private final class BoardDrag {
    static let space = "OpenTalonBoardDrag"
    @ObservationIgnored private var frames: [DragArea: CGRect] = [:]
    private(set) var source: String?
    private(set) var target: WorkStatus?
    private(set) var anchor: String?
    private(set) var before = true
    private(set) var point: CGPoint?

    func setFrames(_ frames: [DragArea: CGRect]) {
        self.frames = frames
        if let source, let point { update(id: source, at: point) }
    }

    func update(id: String, at point: CGPoint) {
        source = id
        self.point = point
        guard let viewport = frames[.viewport], viewport.contains(point) else {
            target = nil
            anchor = nil
            return
        }
        target = WorkStatus.allCases.first { frames[.column($0)]?.contains(point) == true }
        guard let target, let well = frames[.well(target)], well.contains(point) else {
            anchor = nil
            return
        }
        let visibleCards = frames.compactMap { area, rect -> (String, CGRect)? in
            guard case .card(target, let id) = area, well.intersects(rect) else { return nil }
            return (id, rect)
        }.sorted { $0.1.minY < $1.1.minY }
        if let (id, rect) = visibleCards.first(where: { $0.1.maxY >= point.y - 4 }) {
            anchor = id
            before = point.y < rect.midY
        } else {
            anchor = nil
        }
    }

    func edgeDirection(_ status: WorkStatus) -> Int {
        guard target == status, let point, let frame = frames[.well(status)], frame.contains(point) else { return 0 }
        if point.y - frame.minY < 34 { return -1 }
        if frame.maxY - point.y < 34 { return 1 }
        return 0
    }

    func reset() {
        source = nil
        target = nil
        anchor = nil
        point = nil
    }
}

private enum DragArea: Hashable {
    case viewport, column(WorkStatus), well(WorkStatus), card(WorkStatus, String)
}

private struct DragFrames: PreferenceKey {
    static let defaultValue: [DragArea: CGRect] = [:]
    static func reduce(value: inout [DragArea: CGRect], nextValue: () -> [DragArea: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, last in last })
    }
}

private extension View {
    func dragFrame(_ area: DragArea) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: DragFrames.self, value: [area: geometry.frame(in: .named(BoardDrag.space))])
            }
        }
    }
}

private struct ColumnView: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    let status: WorkStatus
    let drag: BoardDrag

    @State private var scrollID: String?

    private var usesCompletionOrder: Bool { status == .done && model.doneOrder != .manual }

    var body: some View {
        let items = model.column(status)
        VStack(spacing: 0) {
            heading(items.count)
            ThemedScrollView(track: palette.well) {
                LazyVStack(spacing: 9) {
                    ForEach(items) { item in
                        TaskCard(item: item, includeProject: model.page == .all)
                            .dragFrame(.card(status, item.id))
                            .opacity(drag.source == item.id ? 0.48 : 1)
                            .overlay(alignment: drag.before ? .top : .bottom) {
                                if !usesCompletionOrder && drag.anchor == item.id && drag.source != item.id {
                                    Capsule().fill(palette.accent).frame(height: 3)
                                        .offset(y: drag.before ? -4 : 4).allowsHitTesting(false)
                                }
                            }
                            .gesture(cardDrag(item))
                    }
                    endOfColumn(isEmpty: items.isEmpty)
                }
                .scrollTargetLayout()
                .padding(.horizontal, 9)
                .padding(.bottom, 10)
                .frame(minHeight: 165, alignment: .top)
            }
            .scrollPosition(id: $scrollID, anchor: .top)
            .defaultScrollAnchor(.top)
            .onChange(of: items.first?.id) { previous, next in
                if usesCompletionOrder, scrollID == previous { scrollID = next }
            }
            .dragFrame(.well(status))
            .task(id: drag.edgeDirection(status)) {
                let direction = drag.edgeDirection(status)
                guard direction != 0, items.count > 1 else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(180)) }
                    catch { return }
                    let current = items.firstIndex { $0.id == scrollID } ?? 0
                    let next = min(items.count - 1, max(0, current + direction))
                    guard next != current else { return }
                    withAnimation(.easeOut(duration: 0.15)) { scrollID = items[next].id }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette.well, in: .rect(cornerRadius: 12))
        .dragFrame(.column(status))
        .overlay {
            if drag.target == status {
                RoundedRectangle(cornerRadius: 12).strokeBorder(palette.accent, lineWidth: 2).allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(status.rawValue)
    }

    private func cardDrag(_ item: WorkItem) -> some Gesture {
        DragGesture(minimumDistance: 7, coordinateSpace: .named(BoardDrag.space))
            .onChanged { value in
                guard !model.draftDirty else { return }
                drag.update(id: item.id, at: value.location)
            }
            .onEnded { value in
                guard drag.source == item.id else { return }
                drag.update(id: item.id, at: value.location)
                let destination = drag.target
                let anchor = drag.anchor
                let before = drag.before
                drag.reset()
                if let destination {
                    _ = model.drop(item.id, in: destination, anchor: anchor, before: before)
                }
            }
    }

    private func heading(_ count: Int) -> some View {
        @Bindable var model = model
        return HStack(spacing: 7) {
            Image(systemName: status.symbol).foregroundStyle(status == .working ? palette.accent : palette.muted)
            Text(drag.target == status ? "Drop in \(status.rawValue)" : status.rawValue)
                .fontWeight(.semibold)
                .lineLimit(1)
            Text(count.formatted()).font(.system(size: 11)).foregroundStyle(palette.muted)
            Spacer(minLength: 0)
            if status == .done {
                Menu {
                    Picker("Sort completed tasks", selection: $model.doneOrder) {
                        ForEach(DoneOrder.allCases) { order in Text(order.title).tag(order) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundStyle(palette.muted)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(model.doneOrder.title)
                .accessibilityLabel("Sort completed tasks")
                .accessibilityValue(model.doneOrder.title)
                .accessibilityIdentifier("doneColumnSort")
                .onChange(of: model.doneOrder) { scrollID = model.column(.done).first?.id }
            }
            IconButton(symbol: "plus", label: "Add task in \(status.rawValue)") { model.newTask(status) }
                .foregroundStyle(palette.muted)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 13)
        .frame(height: 50)
        .contentShape(Rectangle())
        .background(drag.target == status ? palette.active : .clear)
    }

    private func endOfColumn(isEmpty: Bool) -> some View {
        VStack {
            if isEmpty {
                Button {
                    model.newTask(status)
                } label: {
                    Label("Add a task", systemImage: "plus")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.muted)
                        .padding(10)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, minHeight: isEmpty ? 147 : 34)
        .background(drag.target == status && drag.anchor == nil ? palette.active.opacity(0.7) : Color.clear)
        .contentShape(Rectangle())
    }
}

struct TaskCard: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var hovered = false
    let item: WorkItem
    let includeProject: Bool

    private var notesPreview: String {
        let text = item.notes.hasPrefix("Imported from Daily Brief\n")
            ? item.notes.components(separatedBy: "\n\n").dropFirst().joined(separator: " ")
                .components(separatedBy: "Original Daily Brief action (complete source record):")[0]
            : item.notes
        return String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(220))
    }

    private var run: AgentRun? {
        guard let id = model.workspace?.agentAssignments[item.id] else { return nil }
        return model.workspace?.agentRuns.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if item.kind == .bug { IssueTypeBadge(.bug, tint: palette.actionAccent) }
                PriorityBadge(priority: item.priority)
            }
            if let key = item.taskKey {
                Text(key).font(.system(.caption2, design: .monospaced)).foregroundStyle(palette.muted)
            }
            Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(3)
            Text(notesPreview.isEmpty ? "No notes yet" : notesPreview)
                .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(2)
            if includeProject {
                Label(model.projectName(item.boardId), systemImage: "rectangle.split.3x1")
                    .font(.system(size: 10)).foregroundStyle(palette.muted).lineLimit(1)
            }
            HStack(spacing: 6) {
                Image(systemName: "circle.grid.2x2.fill").font(.system(size: 8))
                Label(item.dueLabel ?? "No due date", systemImage: "calendar")
                    .foregroundStyle(item.late ? palette.danger : palette.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let agent = run?.agent {
                    AgentBrandLabel(agent: agent, iconSize: 11)
                } else {
                    Text("Manual")
                }
            }
            .font(.system(size: 10)).foregroundStyle(palette.muted)
            if let date = item.creationDate {
                Text("Created \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 10)).foregroundStyle(palette.muted)
            }
            if item.commentCount > 0 || item.imageCount > 0 || run != nil {
                HStack(spacing: 8) {
                    if item.commentCount > 0 { Label("\(item.commentCount)", systemImage: "bubble") }
                    if item.imageCount > 0 { Label("\(item.imageCount)", systemImage: "photo") }
                    if let run { Text(run.statusLabel) }
                }
                .font(.system(size: 10)).foregroundStyle(palette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .surface(8, fill: model.selection == item.id ? palette.active : palette.card)
        .shadow(color: .black.opacity(hovered ? 0.11 : 0.05), radius: hovered ? 4 : 2, y: 2)
        .contentShape(Rectangle())
        .onTapGesture { model.select(item) }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.select(item) }
        .onHover { hovered = $0 }
        .accessibilityLabel(item.taskKey.map { "\($0), \(item.title)" } ?? item.title)
        .accessibilityHint([item.status.rawValue, item.priority.label,
                            item.creationDate.map { "Created \($0.formatted(date: .abbreviated, time: .omitted))" }]
            .compactMap { $0 }.joined(separator: ", "))
        .contextMenu {
            Button("Open task") { model.select(item) }
            Menu("Move to") {
                ForEach(WorkStatus.allCases.filter { $0 != item.status }) { status in
                    Button(status.rawValue) { model.move(item, to: status) }
                }
            }
            Divider()
            Button("Move to Trash", role: .destructive) { model.trash(item) }
        }
    }
}
