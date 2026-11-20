import Foundation
import Testing
@testable import CompanionCore

@Test func assistantCommandsRequireMatchingExplicitIntent() throws {
    #expect(TaskPlan.requested(in: "Create a task with a Markdown plan to check downloads"))
    #expect(TaskPlan.requested(in: "Add a task with a detailed plan"))
    #expect(!TaskPlan.requested(in: "Create a task to review planet illustrations"))
    try TaskAssistantCommand(operation: "priority", value: "High").validateIntent("Set INK-001 priority to High")
    try TaskAssistantCommand(operation: "create", value: "Review release").validateIntent("Create a task to review the release")
    try TaskAssistantCommand(operation: "send").validateIntent("Send INK-001 to my agent")
    #expect(throws: TaskPlan.PlanError.self) { try TaskAssistantCommand(operation: "trash").validateIntent("What are my urgent tasks?") }
    #expect(throws: TaskPlan.PlanError.self) { try TaskAssistantCommand(operation: "status").validateIntent("Do not mark INK-001 done") }
    #expect(throws: TaskPlan.PlanError.self) { try TaskAssistantCommand(operation: "shell", value: "echo unexpected").validateIntent("Run a command") }
    #expect(throws: TaskPlan.PlanError.self) { try TaskAssistantCommand(operation: "notes", value: "a\0b").validateIntent("Update notes") }
    #expect(throws: TaskPlan.PlanError.self) { try TaskAssistantCommand(operation: "notes", value: "unexpected").validateIntent("Revise TAS-004 plan to add a checklist") }
}

@Test func assistantEditsResolveOnlyKnownTaskReferences() {
    let references = ["lowercase-uuid": "TAS-004"]
    #expect(TaskAssistantCommand(operation: "plan", taskID: "TAS-004").canonicalTaskID(in: references, requestedBy: "Revise TAS-004 plan") == "lowercase-uuid")
    #expect(TaskAssistantCommand(operation: "priority", taskID: "LOWERCASE-UUID").canonicalTaskID(in: references, requestedBy: "Set TAS-004 priority") == "lowercase-uuid")
    #expect(TaskAssistantCommand(operation: "plan").canonicalTaskID(in: references, requestedBy: "Revise TAS-004 plan") == "lowercase-uuid")
    #expect(TaskAssistantCommand(operation: "plan", taskID: "made-up-id").canonicalTaskID(in: references, requestedBy: "Revise TAS-004 plan") == nil)
}

@MainActor @Test func assistantHistoryPersistsChatsAndDeletesOnlySelectedHistory() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "chats.json")
    let history = TaskAssistantHistory(file: file)
    try history.append(.init(role: "user", text: "Find urgent tasks"))
    let firstID = try #require(history.current?.id)
    try history.append(.init(role: "plan", text: "Review plan", taskID: "one", planMarkdown: "# New", expectedMarkdown: "# Old"))
    try history.newChat()
    try history.append(.init(role: "user", text: "Review my projects"))
    let secondID = try #require(history.current?.id)
    let reopened = TaskAssistantHistory(file: file)
    #expect(reopened.chats.count == 2)
    #expect(reopened.current?.id == secondID)
    try reopened.select(firstID)
    #expect(reopened.current?.messages.last?.planMarkdown == "# New")
    #expect(reopened.current?.messages.last?.expectedMarkdown == "# Old")
    try reopened.deleteChat(secondID)
    #expect(reopened.current?.id == firstID)
    #expect(TaskAssistantHistory(file: file).chats.count == 1)
    try reopened.deleteAll()
    #expect(TaskAssistantHistory(file: file).chats.isEmpty)
}

@Test func assistantCreationResolvesExplicitProjectAndCanonicalIdentifiers() {
    let projects = [PhoneProject(id: "a-b-c", name: "Studio Launch"), PhoneProject(id: "personal", name: "Personal")]
    #expect(TaskAssistantCommand(operation: "create", project: "wrong generated ID").projectID(in: projects, requestedBy: "Create a task in Studio Launch") == "a-b-c")
    #expect(TaskAssistantCommand(operation: "create", project: " A-B-C ").projectID(in: projects, requestedBy: "Create a task") == "a-b-c")
    #expect(TaskAssistantCommand(operation: "create").projectID(in: projects, requestedBy: "Create a task to personally review the work") == nil)
}

@MainActor @Test func assistantHistoryPreservesUnreadableFileUntilExplicitReset() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "chats.json")
    let original = Data("unreadable prior history".utf8)
    try original.write(to: file)
    let history = TaskAssistantHistory(file: file)
    #expect(!history.canWrite)
    #expect(throws: CocoaError.self) { try history.append(.init(role: "user", text: "New question")) }
    #expect(try Data(contentsOf: file) == original)
    try history.deleteAll()
    #expect(history.canWrite)
    try history.append(.init(role: "user", text: "Start over"))
    #expect(TaskAssistantHistory(file: file).current?.title == "Start over")
}
