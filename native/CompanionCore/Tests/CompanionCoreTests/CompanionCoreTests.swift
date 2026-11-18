import Foundation
import Testing
@testable import CompanionCore

@Test func taskOrganizationCapabilityAndRequestsRoundTrip() throws {
    let workspace = UUID()
    let legacy = PhoneSnapshot(workspaceID: workspace, revision: 7, projects: [], tasks: [])
    let current = PhoneSnapshot(workspaceID: workspace, revision: 7, projects: [], tasks: [],
                                supportsTaskOrganization: true)
    #expect(!legacy.supportsTaskOrganization)
    #expect(current.shouldReplace(legacy))
    #expect(try JSONDecoder().decode(PhoneSnapshot.self, from: JSONEncoder().encode(current)).supportsTaskOrganization)
    for destination: PhoneRequest.TaskDestination in [.archive, .trash, .active] {
        let request = PhoneRequest(workspaceID: workspace, action: .organizeTask(taskID: "task", destination: destination))
        let restored = try JSONDecoder().decode(PhoneRequest.self, from: JSONEncoder().encode(request))
        #expect(restored.id == request.id)
        #expect(restored.taskID == "task")
        #expect(restored.changesTask)
        guard case .organizeTask(_, let decoded) = restored.action else {
            Issue.record("Organization request did not round-trip")
            return
        }
        #expect(decoded == destination)
    }
}

@MainActor
@Test func reviewInvitationCanBeRequestedOnceAfterThreeActivities() throws {
    let suite = "OpenTalonReviewTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let initial = OpenTalonReviewMilestone(defaults: defaults)
    initial.recordActivity()
    initial.recordActivity()
    #expect(!initial.takeRequest())

    let resumed = OpenTalonReviewMilestone(defaults: defaults)
    resumed.recordActivity()
    #expect(resumed.isDue)
    #expect(resumed.takeRequest())
    #expect(!resumed.takeRequest())

    let afterDismissal = OpenTalonReviewMilestone(defaults: defaults)
    afterDismissal.recordActivity()
    #expect(!afterDismissal.takeRequest())
}

@Test func retriesKeepRequestIdentityAndWaitForTheAppliedRevision() throws {
    let workspace = UUID()
    let request = PhoneRequest(workspaceID: workspace, action: .create(
        projectID: "work", title: "Private task", notes: "Do the work", priority: .urgent, sendToAgent: true
    ))
    let bytes = try JSONEncoder().encode(request)
    let replay = try JSONDecoder().decode(PhoneRequest.self, from: bytes)
    #expect(replay.id == request.id)
    #expect(replay.workspaceID == workspace)

    let waiting = PhoneReceipt(requestID: request.id, outcome: .waiting, message: "Configure an agent.")
    #expect(!waiting.isSettled(at: 3))

    let applied = PhoneReceipt(requestID: request.id, outcome: .applied, revision: 2)
    #expect(!applied.isSettled(at: 1))
    #expect(applied.isSettled(at: 2))
}

@Test func queuedTicketsRetainCompletionCriteriaAndOlderRequestsStillDecode() throws {
    let request = PhoneRequest(workspaceID: UUID(), action: .create(
        projectID: "work", title: "Verify the handoff", notes: "Review the checklist.", priority: .high,
        sendToAgent: false, definitionOfDone: "Checklist reviewed and signed off."
    ))
    let data = try JSONEncoder().encode(request)
    let restored = try JSONDecoder().decode(PhoneRequest.self, from: data)
    guard case .create(_, _, _, _, _, let criteria, _, _, _, _) = restored.action else {
        Issue.record("The queued ticket did not decode as a creation request.")
        return
    }
    #expect(criteria == "Checklist reviewed and signed off.")

    let legacy = """
    {
      "id": "\(request.id.uuidString)",
      "workspaceID": "\(request.workspaceID.uuidString)",
      "createdAt": 0,
      "action": {"create": {
        "projectID": "work", "title": "Legacy task", "notes": "", "priority": "High", "sendToAgent": false
      }}
    }
    """
    let previous = try JSONDecoder().decode(PhoneRequest.self, from: Data(legacy.utf8))
    guard case .create(_, let title, _, _, _, let legacyCriteria, _, _, let legacyComment, let newProject) = previous.action else {
        Issue.record("The older creation request did not decode.")
        return
    }
    #expect(title == "Legacy task")
    #expect(legacyCriteria == nil)
    #expect(legacyComment == nil)
    #expect(newProject == nil)
}

#if DEBUG && os(macOS)
@MainActor
@Test func modelCatalogChangesSyncAtTheSameWorkspaceRevision() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = LocalCompanionTransport(directory: directory)
    try await transport.prepare(account: transport.accountKey())
    let id = UUID()
    var cached = PhoneSnapshot(workspaceID: id, revision: 7, projects: [], tasks: [], availableAgents: [.codex])
    try await transport.publish(cached)
    let example = AgentModelChoice(agent: .codex, id: "provider-next-model", title: "New Model")
    for catalog: [AgentModelChoice] in [[example], []] {
        try await transport.publish(PhoneSnapshot(workspaceID: id, revision: 7, projects: [], tasks: [],
                                                  availableAgents: [.codex], agentModels: catalog))
        guard case .updated(let latest) = try await transport.snapshot(newerThan: cached) else {
            Issue.record("The phone did not receive the changed model catalog.")
            return
        }
        #expect(latest.agentModels == catalog)
        cached = latest
    }
}

@MainActor
@Test func upgradedMacEnablesEditingWithoutRequiringATaskChange() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = LocalCompanionTransport(directory: directory)
    try await transport.prepare(account: transport.accountKey())

    let id = UUID()
    let previous = PhoneSnapshot(workspaceID: id, revision: 7, projects: [], tasks: [], commentsByTask: [:])
    try await transport.publish(previous)
    let upgraded = PhoneSnapshot(workspaceID: id, revision: 7, projects: [], tasks: [],
                                 commentsByTask: [:], supportsNoteEditing: true)
    try await transport.publish(upgraded)

    guard case .updated(let refreshed) = try await transport.snapshot(newerThan: previous) else {
        Issue.record("The phone did not see the capability change at the same workspace revision.")
        return
    }
    #expect(refreshed.supportsNoteEditing)
    #expect(!refreshed.supportsFieldEditing)

    let fieldEditing = PhoneSnapshot(workspaceID: id, revision: 7, projects: [], tasks: [],
                                     commentsByTask: [:], supportsNoteEditing: true, supportsFieldEditing: true)
    try await transport.publish(fieldEditing)
    guard case .updated(let latest) = try await transport.snapshot(newerThan: refreshed) else {
        Issue.record("The phone did not see the ticket fields capability at the same revision.")
        return
    }
    #expect(latest.supportsFieldEditing)
}
#endif

@Test func urgentToDosLeadAndEachGroupIsNewestFirst() throws {
    let older = try #require(TaskCreationOrder.date(from: "2026-11-13T22:00:00Z"))
    let newer = try #require(TaskCreationOrder.date(from: "2026-11-14T01:00:00.123Z"))
    #expect(TaskCreationOrder.precedes(urgent: true, createdAt: older, otherUrgent: false, otherCreatedAt: newer) == true)
    #expect(TaskCreationOrder.precedes(urgent: true, createdAt: newer, otherUrgent: true, otherCreatedAt: older) == true)
    #expect(TaskCreationOrder.precedes(urgent: false, createdAt: older, otherUrgent: false, otherCreatedAt: newer) == false)
    #expect(TaskCreationOrder.precedes(urgent: false, createdAt: nil, otherUrgent: false, otherCreatedAt: newer) == false)
}

@Test func phoneDisplaysOnlyCanonicalTaskIDs() {
    let uuid = UUID().uuidString
    func ticket(_ key: String?) -> PhoneTask {
        PhoneTask(id: uuid, projectID: "jotley", title: "Check task ID", notes: "", definitionOfDone: "",
                  status: .todo, priority: .medium, dueDate: nil, revision: 1, assigned: false, taskKey: key)
    }
    #expect(ticket("JOT-004").displayTaskID == "JOT-004")
    #expect(ticket("ink-1").displayTaskID == "INK-001")
    #expect(ticket("int-1435").displayTaskID == "INT-1435")
    #expect(ticket(nil).displayTaskID == nil)
    #expect(ticket(uuid).displayTaskID == nil)
}

@Test func quickAddRoutesNamedProjectsAndDefaultsToPersonalAndMedium() {
    let studio = PhoneProject(id: "studio", name: "Studio Launch")
    let personal = PhoneProject(id: "personal", name: "Personal")
    let projects = [studio, personal]
    let named = TaskDrafting.captureDestination(in: "For project studio launch verify the download button.",
                                               projects: projects, suggestedName: nil)
    #expect(named.projectID == studio.id)
    #expect(named.newProjectName == nil)

    let newProject = TaskDrafting.captureDestination(in: "For a new project called Harbor Launch, write the brief.",
                                                     projects: projects, suggestedName: studio.name)
    #expect(newProject.newProjectName == "Harbor Launch")

    let fallback = TaskDrafting.captureDestination(in: "Call the plumber.", projects: projects, suggestedName: studio.name)
    #expect(fallback.projectID == personal.id)
    let missingPersonal = TaskDrafting.captureDestination(in: "Call the plumber.", projects: [studio], suggestedName: nil)
    #expect(missingPersonal.newProjectName == "Personal")

    #expect(TaskDrafting.capturePriority(in: "Make this a critical task.") == .urgent)
    #expect(TaskDrafting.capturePriority(in: "Set this task as high priority.") == .high)
    #expect(TaskDrafting.capturePriority(in: "Call the plumber.") == .medium)
}

#if DEBUG && os(macOS)
@MainActor
@Test func agentAvailabilityRefreshesWithoutATaskChange() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = LocalCompanionTransport(directory: directory)
    try await transport.prepare(account: transport.accountKey())
    let id = UUID()
    var cached = PhoneSnapshot(workspaceID: id, revision: 7, projects: [], tasks: [],
                               includesCardMetadata: true)
    try await transport.publish(cached)
    for agents: [PhoneAgent] in [[.codex], [.codex, .claude], []] {
        try await transport.publish(PhoneSnapshot(workspaceID: id, revision: 7, projects: [], tasks: [],
                                                  includesCardMetadata: true, availableAgents: agents))
        guard case .updated(let latest) = try await transport.snapshot(newerThan: cached) else {
            Issue.record("The phone did not receive updated agent availability.")
            return
        }
        #expect(latest.availableAgents == agents)
        cached = latest
    }
}

@MainActor
@Test func sameRevisionSnapshotRefreshAddsCardMetadata() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = LocalCompanionTransport(directory: directory)
    try await transport.prepare(account: transport.accountKey())
    let workspaceID = UUID()
    let legacyTask = PhoneTask(id: "test", projectID: "project", title: "Task", notes: "", definitionOfDone: "",
                              status: .todo, priority: .urgent, dueDate: nil, revision: 7, assigned: false)
    let legacy = PhoneSnapshot(workspaceID: workspaceID, revision: 7, projects: [], tasks: [legacyTask],
                               supportsFieldEditing: true)
    try await transport.publish(legacy)
    guard case .updated(let cached) = try await transport.snapshot(newerThan: nil) else {
        Issue.record("The old snapshot did not decode.")
        return
    }
    #expect(cached.tasks.first?.createdAt == nil)
    #expect(cached.tasks.first?.position == nil)
    #expect(!cached.supportsTaskReordering)
    let createdAt = Date(timeIntervalSinceReferenceDate: 123)
    let newTask = PhoneTask(id: "test", projectID: "project", title: "Task", notes: "", definitionOfDone: "",
                            status: .todo, priority: .urgent, dueDate: nil, revision: 7, assigned: false,
                            taskKey: "PRO-001", createdAt: createdAt)
    let upgraded = PhoneSnapshot(workspaceID: workspaceID, revision: 7, projects: [], tasks: [newTask],
                                 supportsFieldEditing: true, includesCardMetadata: true)
    try await transport.publish(upgraded)
    guard case .updated(let refreshed) = try await transport.snapshot(newerThan: cached) else {
        Issue.record("An unchanged workspace revision suppressed the new metadata.")
        return
    }
    #expect(refreshed.tasks.first?.taskKey == "PRO-001")
    #expect(refreshed.tasks.first?.createdAt == createdAt)
    let positioned = PhoneTask(id: "test", projectID: "project", title: "Task", notes: "", definitionOfDone: "",
                               status: .todo, priority: .urgent, dueDate: nil, revision: 7, assigned: false,
                               taskKey: "PRO-001", createdAt: createdAt, position: 2)
    let withOrder = PhoneSnapshot(workspaceID: workspaceID, revision: 7, projects: [], tasks: [positioned],
                                  supportsFieldEditing: true, includesCardMetadata: true, supportsTaskReordering: true)
    try await transport.publish(withOrder)
    guard case .updated(let current) = try await transport.snapshot(newerThan: refreshed) else {
        Issue.record("The phone did not receive manual positions when the Mac was upgraded.")
        return
    }
    #expect(current.tasks.first?.position == 2)
    #expect(current.supportsTaskReordering)
}
#endif
