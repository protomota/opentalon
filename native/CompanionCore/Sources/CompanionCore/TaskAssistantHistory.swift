import Foundation
import Observation

@MainActor
@Observable
public final class TaskAssistantHistory {
    public struct Message: Codable, Identifiable {
        public let id: UUID
        public let role: String
        public let text: String
        public let taskID: String?
        public let planMarkdown: String?
        public let expectedMarkdown: String?
        public init(role: String, text: String, taskID: String? = nil, planMarkdown: String? = nil, expectedMarkdown: String? = nil) {
            id = UUID(); self.role = role; self.text = text; self.taskID = taskID
            self.planMarkdown = planMarkdown; self.expectedMarkdown = expectedMarkdown
        }
    }
    public struct Chat: Codable, Identifiable {
        public let id: UUID
        public var title: String
        public var messages: [Message]
    }
    private struct Saved: Codable { var chats: [Chat]; var selected: UUID? }
    public private(set) var chats: [Chat] = []
    public private(set) var selected: UUID?
    public private(set) var error: String?
    private let file: URL
    private var unreadable = false

    public convenience init(workspaceID: UUID) {
        self.init(file: URL.applicationSupportDirectory.appending(path: "OpenTalonCompanion/Assistant/\(workspaceID.uuidString).json"))
    }

    public init(file: URL) {
        self.file = file
        do {
            let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))
            chats = saved.chats; selected = saved.selected
        } catch let failure as CocoaError where failure.code == .fileReadNoSuchFile { }
        catch {
            unreadable = true
            self.error = "Couldn’t read saved chats. The original file has been preserved."
        }
    }

    public var current: Chat? { chats.first { $0.id == selected } }
    public var canWrite: Bool { !unreadable }

    public func select(_ id: UUID) throws { try update { $0.selected = id } }

    public func newChat() throws {
        let chat = Chat(id: UUID(), title: "New chat", messages: [])
        try update { $0.chats.insert(chat, at: 0); $0.selected = chat.id }
    }

    public func append(_ message: Message) throws {
        if current == nil { try newChat() }
        try update { saved in
            guard let index = saved.chats.firstIndex(where: { $0.id == saved.selected }) else { return }
            saved.chats[index].messages.append(message)
            if message.role == "user", saved.chats[index].title == "New chat" {
                saved.chats[index].title = String(message.text.prefix(60))
            }
        }
    }

    public func deleteChat(_ id: UUID) throws {
        try update {
            $0.chats.removeAll { $0.id == id }
            if $0.selected == id { $0.selected = $0.chats.first?.id }
        }
    }

    public func deleteAll() throws {
        // This is called only after the app's explicit Delete All Chats confirmation.
        try update(allowUnreadable: true) { $0.chats = []; $0.selected = nil }
    }

    private func update(allowUnreadable: Bool = false, _ change: (inout Saved) -> Void) throws {
        guard !unreadable || allowUnreadable else { throw CocoaError(.fileReadCorruptFile) }
        var saved = Saved(chats: chats, selected: selected)
        change(&saved)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: file, options: .atomic)
            chats = saved.chats; selected = saved.selected; error = nil; unreadable = false
        } catch {
            self.error = "Couldn’t save this chat. Try again before making more changes."
            throw error
        }
    }
}
