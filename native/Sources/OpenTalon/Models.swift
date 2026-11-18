import CompanionCore
import SwiftUI

enum WorkStatus: String, CaseIterable, Codable, Identifiable {
    case todo = "To do", sent = "Sent to agent", working = "In progress", done = "Done"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .todo: "circle"
        case .sent: "paperplane"
        case .working: "circle.dashed"
        case .done: "checkmark"
        }
    }

}

enum Priority: String, CaseIterable, Codable, Identifiable {
    case urgent = "Urgent", high = "High", medium = "Medium", low = "Low", none = "None"
    var id: Self { self }
    var rank: Int { Self.allCases.firstIndex(of: self) ?? 4 }
    var label: String { self == .none ? "No priority" : rawValue }
    func color(_ dark: Bool) -> Color {
        switch self {
        case .urgent: Color(hex: dark ? 0xffa2aa : 0xb52b3e)
        case .high: Color(hex: dark ? 0xf7ad90 : 0xaa431d)
        case .medium: Color(hex: dark ? 0xdfc780 : 0x756019)
        case .low: Color(hex: dark ? 0x9bc5a4 : 0x3f6953)
        case .none: .secondary
        }
    }
}

enum BoardSort: String, CaseIterable, Identifiable {
    case manual, high = "priority-desc", low = "priority-asc", newest
    var id: Self { self }
    var title: String {
        switch self {
        case .manual: "Manual order"
        case .high: "Highest priority first"
        case .low: "Lowest priority first"
        case .newest: "Newest first"
        }
    }
    func rank(_ priority: Priority) -> Int {
        priority == .none || self != .low ? priority.rank : 3 - priority.rank
    }
}

typealias Theme = OpenTalonTheme

struct Board: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String?
    let position: Int
    let revision: Int
}

struct WorkItem: Codable, Identifiable, Equatable {
    let id: String
    let taskKey: String?
    let boardId: String
    let title: String
    let notes: String
    let planMarkdown: String?
    let status: WorkStatus
    let priority: Priority
    let definitionOfDone: String
    let dueDate: String?
    let commentCount: Int
    let imageCount: Int
    let position: Int
    let deleted: Bool
    let deletedAt: String?
    let archivedAt: String?
    let revision: Int
    let createdAt: String
    let updatedAt: String

    var write: [String: Any] { ["id": id, "expectedRevision": revision] }
    var reference: String { taskKey ?? id }
    var creationDate: Date? { TaskCreationOrder.date(from: createdAt) }
    var late: Bool { dueDate.map { $0 <= CalendarDay.today } ?? false }
    var dueLabel: String? { dueDate.map(CalendarDay.label) }
}

struct Workspace: Decodable {
    let theme: Theme
    let selectedBoard: String
    let preferencesRevision: Int
    let revision: Int
    let boards: [Board]
    let tasks: [WorkItem]
    let agentRuns: [AgentRun]
    let agentAssignments: [String: String]
    let allTasksOrder: [String]
}

enum Agent: String, Codable, CaseIterable, Identifiable {
    case claude = "claude-code", codex
    var id: Self { self }
    var title: String { self == .claude ? "Claude" : "Codex" }
    var guide: String {
        self == .claude ? "https://code.claude.com/docs/en/quickstart" : "https://learn.chatgpt.com/docs/codex/cli"
    }
}

enum AgentPermission: String, Codable, CaseIterable {
    case auto, manual
    case fullAccess = "full-access"

    var title: String {
        switch self {
        case .auto: "Automatic"
        case .manual: "Manual"
        case .fullAccess: "Full access"
        }
    }

    var detail: String {
        switch self {
        case .auto: "The agent reviews permission requests automatically when supported."
        case .manual: "You review permission requests as they come up."
        case .fullAccess: "The agent can act outside the working folder without asking for approval."
        }
    }
}

struct AgentSettings: Codable, Equatable {
    var defaultAgent: Agent = .claude
    var workingFolder = ""
    var permissionMode: AgentPermission = .auto
}

struct AgentRun: Decodable, Identifiable {
    struct Approval: Decodable {
        let id: String
        let title: String
        let details: String
        let canApprove: Bool
    }
    let id: String
    let taskId: String
    let agent: Agent
    let workingFolder: String
    let state: String
    let threadId: String?
    let pickedUpAt: String?
    let summary: String
    let approval: Approval?
    var active: Bool { ["queued", "starting", "working", "needs-input"].contains(state) }
    var statusLabel: String { state.replacingOccurrences(of: "-", with: " ").capitalized }
}

struct CommentImage: Codable, Identifiable {
    let id: String
    let name: String
    let mimeType: String
}

struct DraftImage: Decodable, Identifiable {
    var id = UUID()
    let name: String
    let mimeType: String
    let data: String
    enum CodingKeys: String, CodingKey { case name, mimeType, data }
    var fields: [String: String] { ["name": name, "mimeType": mimeType, "data": data] }
    var image: NSImage? { Data(base64Encoded: data).flatMap(NSImage.init(data:)) }
}

struct WorkComment: Decodable, Identifiable {
    let id: String
    let text: String
    let createdAt: String
    let delivery: String
    let agent: Agent?
    let images: [CommentImage]
}

struct Connection: Decodable {
    let enabled: Bool
    let running: Bool
    let endpoint: String?
    let error: String
    let configFile: String
}

struct Preview: Decodable, Identifiable {
    struct Summary: Decodable {
        let count: Int?
        let boards: Int?
        let tasks: Int?
        let trash: Int?
        let path: String?
        let taskNames: [String]

        private struct TrashedTask: Decodable { let title: String }
        private enum CodingKeys: String, CodingKey { case count, boards, tasks, trash, path }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            count = try fields.decodeIfPresent(Int.self, forKey: .count)
            boards = try fields.decodeIfPresent(Int.self, forKey: .boards)
            tasks = try? fields.decode(Int.self, forKey: .tasks)
            trash = try fields.decodeIfPresent(Int.self, forKey: .trash)
            path = try fields.decodeIfPresent(String.self, forKey: .path)
            taskNames = (try? fields.decode([TrashedTask].self, forKey: .tasks))?.map(\.title) ?? []
        }
    }
    let token: String
    let action: String
    let summary: Summary
    var id: String { token }
    var restoring: Bool { action == "restore_backup" }
    var title: String { restoring ? "Restore backup?" : "Permanently delete tasks?" }
    var detail: String {
        if restoring {
            return "Restore \(summary.boards ?? 0) projects, \(summary.tasks ?? 0) tasks, and \(summary.trash ?? 0) items in Trash. This replaces the current native workspace after saving a safety backup. Restored tasks will not be sent to an agent."
        }
        return "\(summary.count ?? 0) items will be permanently removed. This cannot be undone."
    }
}

enum WorkspacePage: Hashable {
    case dashboard, all, recent, board(String), archive, trash, about
    var storageKey: String {
        switch self {
        case .dashboard: "dashboard"
        case .all: "all"
        case .recent: "recent"
        case .board(let id): "project.\(id)"
        case .archive: "archive"
        case .trash: "trash"
        case .about: "about"
        }
    }
}

typealias CalendarDay = CompanionCore.CalendarDay

enum BoardIcons {
    static let entries: [(String, String)] = [
        ("activity", "waveform.path.ecg"), ("bird", "bird"), ("book-open", "book"), ("bot", "cpu"),
        ("briefcase", "briefcase"), ("brush", "paintbrush"), ("building", "building.2"), ("calendar", "calendar"),
        ("camera", "camera"), ("car", "car"), ("chart-column", "chart.bar"), ("chart-line", "chart.xyaxis.line"),
        ("cloud", "cloud"), ("code", "chevron.left.forwardslash.chevron.right"), ("coffee", "cup.and.saucer"), ("compass", "safari"),
        ("cpu", "cpu"), ("database", "cylinder"), ("dollar-sign", "dollarsign.circle"), ("dumbbell", "dumbbell"),
        ("feather", "pencil.line"), ("flag", "flag"), ("flask", "flask"), ("gamepad", "gamecontroller"),
        ("gift", "gift"), ("globe", "globe"), ("graduation-cap", "graduationcap"), ("hammer", "hammer"),
        ("heart", "heart"), ("house", "house"), ("image", "photo"), ("inbox", "tray"),
        ("leaf", "leaf"), ("lightbulb", "lightbulb"), ("lock", "lock"), ("mail", "envelope"),
        ("map", "map"), ("megaphone", "megaphone"), ("mic", "mic"), ("moon", "moon"),
        ("music", "music.note"), ("newspaper", "newspaper"), ("notebook-pen", "square.and.pencil"),
        ("package", "shippingbox"), ("palette", "paintpalette"), ("pen-tool", "pencil.tip"),
        ("plane", "airplane"), ("plug", "powerplug"), ("rocket", "paperplane"), ("server", "server.rack"),
        ("shield", "shield"), ("shopping-cart", "cart"), ("smartphone", "iphone"), ("sparkles", "sparkles"),
        ("star", "star"), ("sun", "sun.max"), ("target", "target"), ("terminal", "terminal"),
        ("trophy", "trophy"), ("user", "person"), ("users", "person.2"), ("utensils", "fork.knife"),
        ("video", "video"), ("wallet", "wallet.bifold"), ("workflow", "point.3.connected.trianglepath.dotted"),
        ("wrench", "wrench"), ("zap", "bolt"),
    ]

    static func symbol(_ key: String?) -> String {
        entries.first(where: { $0.0 == key })?.1 ?? "rectangle.split.3x1"
    }
}

struct AgentBrandIcon: View {
    @Environment(\.palette) private var palette
    let agent: Agent
    var size: CGFloat = 16

    var body: some View {
        let name = agent == .claude ? "claude-mark" : "openai-mark"
        let mark = Bundle.main.url(forResource: name, withExtension: "png").flatMap { NSImage(contentsOf: $0) }
        OpenTalonAgentMark(
            image: mark.map { Image(nsImage: $0) } ?? Image(systemName: "terminal"),
            isClaude: agent == .claude,
            darkSurface: palette.dark,
            size: size
        )
    }
}

struct AgentBrandLabel: View {
    let agent: Agent
    var title: String? = nil
    var iconSize: CGFloat = 16

    var body: some View {
        Label {
            Text(title ?? agent.title).lineLimit(1)
        } icon: {
            AgentBrandIcon(agent: agent, size: iconSize)
        }
    }
}
