import CompanionCore
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class PhoneCompanion {
    private struct Identity: Codable {
        var workspaceID = UUID()
        var account: String?
    }

    private struct TicketSnapshot: Decodable {
        let workspace: Workspace
        let defaultAgent: PhoneAgent
        let availableAgents: [PhoneAgent]
        let agentModels: [AgentModelChoice]
        let commentsByTask: [String: [PhoneComment]]
        let historyByTask: [String: TaskHistoryPage]
        let activityByTask: [String: TaskActivityPage]
    }

    private struct MutationRevision: Decodable {
        struct TaskIdentity: Decodable { let id: String }
        let revision: Int
        let task: TaskIdentity?
    }

    @ObservationIgnored private let file: URL
    @ObservationIgnored private let cloud: any CompanionTransport
    @ObservationIgnored private var polling: Task<Void, Never>?
    private var identity: Identity
    private(set) var lastSync: Date?
    private(set) var error: String?
    private(set) var syncing = false

    init(profile: URL, isolated: Bool) {
        #if DEBUG
        if isolated, let path = ProcessInfo.processInfo.environment["OPENTALON_LOCAL_SYNC_DIRECTORY"], !path.isEmpty {
            cloud = LocalCompanionTransport(directory: URL(fileURLWithPath: path, isDirectory: true))
        } else {
            cloud = CompanionCloud()
        }
        #else
        cloud = CompanionCloud()
        #endif
        // Read the old workspace ID so queued requests retain their original identity.
        file = profile.appendingPathComponent("phone-cloud.json")
        let legacy = profile.appendingPathComponent("phone-companion.json")
        identity = [file, legacy].compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Identity.self, from: data)
        }.first ?? Identity()
    }

    var usesLocalTransport: Bool {
        #if DEBUG
        return cloud is LocalCompanionTransport
        #else
        return false
        #endif
    }

    func start(service: Service) {
        guard polling == nil else { return }
        polling = Task { [weak self, weak service] in
            while let self, let service, !Task.isCancelled {
                await sync(service: service)
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
            }
        }
    }

    func sync(service: Service) async {
        guard service.ready, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            let account = try await cloud.accountKey()
            if let original = identity.account, original != account {
                throw CompanionCloudError.accountChanged
            }
            if identity.account == nil {
                var updated = identity
                updated.account = account
                try JSONEncoder().encode(updated).write(to: file, options: .atomic)
                identity = updated
            }
            try await cloud.prepare(account: account)
            let snapshot: TicketSnapshot = try await service.call("native_phone_snapshot")
            try await cloud.publish(projection(snapshot))
            let requests = try await cloud.pendingRequests(for: identity.workspaceID)
            for request in requests {
                let receipt = try await apply(request, service: service)
                try await cloud.acknowledge(receipt)
            }
            if !requests.isEmpty {
                let updated: TicketSnapshot = try await service.call("native_phone_snapshot")
                try await cloud.publish(projection(updated))
            }
            lastSync = .now
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func projection(_ snapshot: TicketSnapshot) -> PhoneSnapshot {
        let workspace = snapshot.workspace
        let projects = workspace.boards.map { PhoneProject(id: $0.id, name: $0.name) }
        let pickups = Dictionary(uniqueKeysWithValues: workspace.agentRuns.compactMap { run in
            run.pickedUpAt.flatMap(TaskCreationOrder.date(from:)).map { (run.id, PhoneAgentPickup(id: run.id, at: $0)) }
        })
        let latestRuns = Dictionary(workspace.agentRuns.map { ($0.taskId, $0) }, uniquingKeysWith: { latest, _ in latest })
        let tasks = workspace.tasks.compactMap { item -> PhoneTask? in
            guard !item.deleted, let status = PhoneTask.Status(rawValue: item.status.rawValue),
                  let priority = PhoneTask.Priority(rawValue: item.priority.rawValue) else { return nil }
            let error: String? = if status == .todo, let run = latestRuns[item.id],
                                    run.pickedUpAt == nil, ["failed", "interrupted"].contains(run.state) {
                run.summary
            } else { nil }
            return PhoneTask(
                id: item.id, projectID: item.boardId, title: item.title,
                notes: item.notes, definitionOfDone: item.definitionOfDone,
                status: status, priority: priority, dueDate: item.dueDate, revision: item.revision,
                assigned: workspace.agentAssignments[item.id] != nil,
                taskKey: item.taskKey, createdAt: item.creationDate,
                archivedAt: item.archivedAt.flatMap(TaskCreationOrder.date(from:)),
                agentPickup: workspace.agentAssignments[item.id].flatMap { pickups[$0] },
                agentDispatchError: error, position: item.position, planMarkdown: item.planMarkdown, issueType: item.kind
            )
        }
        return PhoneSnapshot(workspaceID: identity.workspaceID, revision: workspace.revision,
                             projects: projects, tasks: tasks, defaultAgent: snapshot.defaultAgent,
                             commentsByTask: snapshot.commentsByTask, supportsNoteEditing: true,
                             supportsFieldEditing: true, includesCardMetadata: true,
                             availableAgents: snapshot.availableAgents, agentModels: snapshot.agentModels,
                             supportsDispatchComments: true,
                             trashedTasks: workspace.tasks.filter(\.deleted)
                                .sorted { ($0.deletedAt ?? "") > ($1.deletedAt ?? "") }
                                .map { PhoneTrashedTask(id: $0.id, projectID: $0.boardId,
                                                       title: $0.title, revision: $0.revision) },
                             captureProjectID: workspace.selectedBoard, macName: Host.current().localizedName ?? "Mac",
                             supportsTaskOverrides: true, supportsBulkArchive: true, supportsTaskReordering: true,
                             supportsTaskOrganization: true, supportsTaskPlans: true, supportsTaskTypes: true, historyByTask: snapshot.historyByTask, activityByTask: snapshot.activityByTask)
    }

    private func apply(_ request: PhoneRequest, service: Service) async throws -> PhoneReceipt {
        let action: String
        var input: [String: Any] = ["requestKey": "phone:" + request.id.uuidString]
        switch request.action {
        case .loadActivity(let id, let before):
            var fields: [String: Any] = ["taskId": id, "limit": 20]
            fields["beforeSequence"] = before
            do {
                let page: TaskActivityPage = try await service.call("list_task_activity", fields)
                return PhoneReceipt(requestID: request.id, outcome: .applied, revision: page.revision, activity: page)
            } catch let failure as ServiceFailure where failure.code == "NOT_FOUND" {
                return PhoneReceipt(requestID: request.id, outcome: .rejected, message: failure.message)
            }
        case .loadHistory(let id, let before):
            var fields: [String: Any] = ["id": id, "limit": 20]
            fields["beforeVersion"] = before
            do {
                let page: TaskHistoryPage = try await service.call("get_task_history", fields)
                return PhoneReceipt(requestID: request.id, outcome: .applied, revision: page.revision, history: page)
            } catch let failure as ServiceFailure where failure.code == "NOT_FOUND" {
                return PhoneReceipt(requestID: request.id, outcome: .rejected, message: failure.message)
            }
        case .restoreRevision(let id, let historyID, let revision):
            action = "restore_task_revision"
            input["id"] = id
            input["historyID"] = historyID
            input["expectedRevision"] = revision
        case .createProject(let name):
            action = "create_board"
            input["name"] = name
        case .savePlan(let id, let expected, let markdown):
            action = "set_task_plan"
            input["id"] = id
            input["expectedMarkdown"] = expected
            input["markdown"] = markdown
        case .organizeTask(let id, let destination):
            action = "companion_organize_task"
            input["id"] = id
            input["destination"] = destination.rawValue
        case .create(let project, let title, let notes, let priority, let send, let definitionOfDone, let agent, let model,
                     let dispatchComment, let newProjectName, let planMarkdown, let issueType):
            action = newProjectName == nil ? "create_task" : "capture_task"
            input["boardId"] = project
            input["newProjectName"] = newProjectName
            input["title"] = title
            input["notes"] = notes
            input["planMarkdown"] = planMarkdown
            input["issueType"] = issueType?.rawValue
            input["definitionOfDone"] = definitionOfDone
            input["priority"] = priority.rawValue
            input["status"] = send ? WorkStatus.sent.rawValue : WorkStatus.todo.rawValue
            input["agent"] = agent?.rawValue
            input["model"] = model
            input["dispatchComment"] = dispatchComment
        case .comment(let id, let text):
            action = "add_user_comment"
            input["taskId"] = id
            input["text"] = text
            input["notifyAgent"] = true
        case .editNotes(let id, let revision, let notes):
            action = "update_task"
            input["id"] = id
            input["expectedRevision"] = revision
            input["notes"] = notes
        case .removeArchived(let id, let revision, let permanently):
            action = permanently ? "companion_delete_archived_task" : "trash_task"
            input["id"] = id
            input["expectedRevision"] = revision
        case .restoreTrashed(let id, let revision):
            action = "restore_task"
            input["id"] = id
            input["expectedRevision"] = revision
        case .emptyTrash(let revision):
            action = "companion_empty_trash"
            input["expectedRevision"] = revision
        case .manageArchive(let ids, let revision, let permanently):
            action = "manage_archived_tasks"
            input["taskIds"] = ids
            input["expectedRevision"] = revision
            input["permanently"] = permanently
        case .forceComplete(let id):
            action = "force_complete_task"
            input["id"] = id
        case .reorderTask(let id, let projectID, let status, let anchorID, let before):
            action = "companion_reorder_task"
            input["id"] = id
            input["boardId"] = projectID
            input["status"] = status.rawValue
            input["anchorId"] = anchorID
            input["before"] = before
        case .setField(let id, let expected, let edit):
            action = "companion_set_task_field"
            input["id"] = id
            input["field"] = edit.field.rawValue
            input["value"] = edit.value.map { $0 as Any } ?? NSNull()
            input["expectedValue"] = expected.map { $0 as Any } ?? NSNull()
            if case .status(_, let agent, let model, let comment) = edit {
                input["agent"] = agent?.rawValue
                input["model"] = model
                input["dispatchComment"] = comment
            }
        case .editField(let id, let revision, let edit):
            input["id"] = id
            input["expectedRevision"] = revision
            switch edit {
            case .project(let projectID):
                action = "move_task"
                input["boardId"] = projectID
            case .status(let status, let agent, let model, let dispatchComment):
                action = "move_task"
                input["status"] = status.rawValue
                input["agent"] = agent?.rawValue
                input["model"] = model
                input["dispatchComment"] = dispatchComment
            case .priority(let priority):
                action = "update_task"
                input["priority"] = priority.rawValue
            case .dueDate(let date):
                action = "update_task"
                input["dueDate"] = date.map { $0 as Any } ?? NSNull()
            case .title, .notes, .definitionOfDone, .issueType:
                action = "update_task"
                input[edit.field.rawValue] = edit.value
            }
        case .send(let id, let revision, _), .complete(let id, let revision):
            let current: Workspace = try await service.call("snapshot")
            // A different revision may be a replay after a successful commit. Let the store
            // check the original request key before it checks the expected revision.
            if let task = current.tasks.first(where: { $0.id == id && $0.revision == revision }),
               task.deleted || current.agentAssignments[id] != nil || ![.todo, .working].contains(task.status) {
                return PhoneReceipt(requestID: request.id, outcome: .rejected, message: "This task is no longer open for manual changes.")
            }
            action = "move_task"
            input["id"] = id
            input["expectedRevision"] = revision
            if case .send(_, _, let agent) = request.action {
                input["status"] = WorkStatus.sent.rawValue
                input["agent"] = agent?.rawValue
            }
            else { input["status"] = WorkStatus.done.rawValue }
        }

        do {
            let result: MutationRevision = try await service.call(action, input)
            let createdTaskID: String?
            if case .create = request.action { createdTaskID = result.task?.id }
            else { createdTaskID = nil }
            return PhoneReceipt(requestID: request.id, outcome: .applied, revision: result.revision,
                                createdTaskID: createdTaskID)
        } catch let failure as ServiceFailure {
            switch failure.code {
            case "AGENT_SETUP_REQUIRED", "AGENT_NOT_INSTALLED", "MCP_DISABLED":
                return PhoneReceipt(requestID: request.id, outcome: .waiting, message: failure.message)
            case "CONFLICT", "NOT_FOUND", "IN_TRASH", "INVALID_ARGUMENT", "INVALID_STATE", "EMPTY_COMMENT",
                 "AGENT_ALREADY_RUNNING", "COMPLETION_PROOF_REQUIRED":
                return PhoneReceipt(requestID: request.id, outcome: .rejected, message: failure.message)
            default:
                throw failure
            }
        }
    }
}

struct PhoneCompanionSettings: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("iCloud sync").font(.system(size: 16, weight: .semibold))
            Text("OpenTalon syncs projects and tasks automatically with your iPhone using the same Apple Account.")
                .font(.system(size: 12)).foregroundStyle(palette.muted)
            if let error = model.phoneCompanion.error {
                Text(error).font(.caption).foregroundStyle(palette.muted)
            }
            if let lastSync = model.phoneCompanion.lastSync {
                Label("Last synced \(lastSync.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.icloud")
                    .font(.caption).foregroundStyle(palette.muted)
            }
            Button(model.phoneCompanion.syncing ? "Checking iCloud…" : "Check Now", systemImage: "arrow.clockwise") {
                Task { await model.phoneCompanion.sync(service: model.service) }
            }
            .disabled(model.phoneCompanion.syncing || !model.service.ready || model.isolatedProfile)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
