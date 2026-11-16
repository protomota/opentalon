import CloudKit
import CompanionCore
import Foundation
import Observation
import StoreKit
import UserNotifications

@MainActor
@Observable
final class PhoneWorkspace {
    static let pickupAlertsKey = "agentPickupAlerts"
    let reviewMilestone = OpenTalonReviewMilestone()
    private(set) var publicReviewsAvailable = false

    var canRequestAppStoreReview: Bool {
        #if DEBUG && targetEnvironment(simulator)
        true
        #else
        publicReviewsAvailable
        #endif
    }

    func checkAppStoreInstall() async {
        guard !publicReviewsAvailable else { return }
        guard case .verified(let transaction) = try? await AppTransaction.shared else { return }
        publicReviewsAvailable = transaction.environment == .production
    }

    struct UnsavedNotes: Codable {
        let text: String
        let message: String
    }

    private enum QueueError: LocalizedError {
        case changePending

        var errorDescription: String? { "Wait for the current task change to sync with your Mac." }
    }

    private struct LocalState: Codable {
        var snapshot: PhoneSnapshot?
        var pending: [PhoneRequest] = []
        var waiting: [UUID: String] = [:]
        var rejected: String?
        var commentDrafts: [String: String]?
        var unsavedNotes: [String: UnsavedNotes]?
    }

    private let directory = URL.applicationSupportDirectory.appending(path: "OpenTalonCompanion", directoryHint: .isDirectory)
    @ObservationIgnored private let cloud: any CompanionTransport
    private var state = LocalState()
    private var account: String?
    private var accountGeneration = 0
    private(set) var syncing = false
    private(set) var syncError: String?
    private(set) var syncErrorCode: String?
    private(set) var accountStatus = "Not checked"
    private(set) var remoteWorkspaceFound: Bool?
    private(set) var lastCheck: Date?
    private(set) var lastCloudContact: Date?
    private(set) var pickupNotice: String?

    init() {
        #if DEBUG && targetEnvironment(simulator)
        if let path = ProcessInfo.processInfo.environment["OPENTALON_LOCAL_SYNC_DIRECTORY"], !path.isEmpty {
            cloud = LocalCompanionTransport(directory: URL(fileURLWithPath: path, isDirectory: true))
        } else {
            cloud = CompanionCloud()
        }
        #else
        cloud = CompanionCloud()
        #endif
    }

    var snapshot: PhoneSnapshot? { state.snapshot }
    var pending: [PhoneRequest] { state.pending }
    var lastRejection: String? { state.rejected }

    func accountDidChange() {
        accountGeneration += 1
        account = nil
        state = LocalState()
        syncError = nil
        syncErrorCode = nil
        accountStatus = "Not checked"
        remoteWorkspaceFound = nil
        lastCheck = nil
        lastCloudContact = nil
        pickupNotice = nil
        Task { await sync() }
    }

    func queue(_ action: PhoneRequest.Action) throws {
        guard let snapshot else { throw CompanionSyncError.missingWorkspace }
        let request = PhoneRequest(workspaceID: snapshot.workspaceID, action: action)
        if case .forceComplete = action {
            try enqueue(request, in: state)
            return
        }
        if request.changesTask, let taskID = request.taskID, pendingTaskChange(for: taskID) != nil {
            throw QueueError.changePending
        }

        try enqueue(request, in: state)
    }

    func queueField(_ edit: PhoneTaskFieldEdit, for task: PhoneTask, in workspaceID: UUID) throws {
        guard snapshot?.workspaceID == workspaceID, snapshot?.supportsFieldEditing == true else {
            throw CompanionSyncError.missingWorkspace
        }
        if snapshot?.supportsTaskOverrides == true {
            let current = snapshot?.tasks.first(where: { $0.id == task.id }) ?? task
            let expected: String? = switch edit.field {
            case .project: displayedProject(for: current)
            case .status: displayedStatus(for: current).rawValue
            case .priority: displayedPriority(for: current).rawValue
            case .dueDate: displayedDueDate(for: current)
            }
            guard expected != edit.value else { return }
            try enqueue(PhoneRequest(workspaceID: workspaceID,
                                     action: .setField(taskID: task.id, expected: expected, edit: edit)), in: state)
            return
        }
        try queue(.editField(taskID: task.id, revision: task.revision, edit: edit))
    }

    func canMarkDone(_ task: PhoneTask) -> Bool {
        guard task.archivedAt == nil, displayedStatus(for: task) != .done else { return false }
        if snapshot?.supportsTaskOverrides == true { return true }
        return task.isManualOpen && pendingTaskChange(for: task.id) == nil
    }

    func completionNeedsConfirmation(for task: PhoneTask) -> Bool {
        task.assigned || displayedStatus(for: task) == .sent
    }

    func markDone(_ task: PhoneTask) throws {
        guard let snapshot, canMarkDone(task) else { return }
        if completionNeedsConfirmation(for: task) {
            try queue(.forceComplete(taskID: task.id))
        } else if snapshot.supportsTaskOverrides {
            try queueField(.status(.done), for: task, in: snapshot.workspaceID)
        } else {
            try queue(.complete(taskID: task.id, revision: task.revision))
        }
    }

    func queueNotes(_ notes: String, for task: PhoneTask, in workspaceID: UUID) throws {
        guard snapshot?.workspaceID == workspaceID, snapshot?.supportsNoteEditing == true else {
            throw CompanionSyncError.missingWorkspace
        }
        guard pendingTaskChange(for: task.id) == nil else { throw QueueError.changePending }
        var updated = state
        updated.unsavedNotes?.removeValue(forKey: task.id)
        let request = PhoneRequest(workspaceID: workspaceID,
                                   action: .editNotes(taskID: task.id, revision: task.revision, notes: notes))
        try enqueue(request, in: updated)
    }

    func unsavedNotes(for taskID: String) -> UnsavedNotes? { state.unsavedNotes?[taskID] }

    func commentDraft(for taskID: String, in workspaceID: UUID) -> String {
        guard snapshot?.workspaceID == workspaceID else { return "" }
        return state.commentDrafts?[taskID] ?? ""
    }

    func saveCommentDraft(_ text: String, for taskID: String, in workspaceID: UUID) throws {
        guard snapshot?.workspaceID == workspaceID else { return }
        guard text != commentDraft(for: taskID, in: workspaceID) else { return }
        var updated = state
        var drafts = updated.commentDrafts ?? [:]
        drafts[taskID] = text.isEmpty ? nil : text
        updated.commentDrafts = drafts.isEmpty ? nil : drafts
        try save(updated)
    }

    func finishComment(_ text: String, for taskID: String, in workspaceID: UUID) throws {
        guard snapshot?.workspaceID == workspaceID, snapshot?.commentsByTask != nil else {
            throw CompanionSyncError.missingWorkspace
        }
        var updated = state
        updated.commentDrafts?.removeValue(forKey: taskID)
        let request = PhoneRequest(workspaceID: workspaceID, action: .comment(taskID: taskID, text: text))
        try enqueue(request, in: updated)
    }

    private func enqueue(_ request: PhoneRequest, in state: LocalState) throws {
        var updated = state
        updated.pending.append(request)
        try save(updated)
        Task { await sync() }
    }

    func sync() async {
        guard !syncing else { return }
        syncing = true
        let generation = accountGeneration
        var checkedAccount = false
        defer {
            syncing = false
            if generation != accountGeneration {
                Task { await sync() }
            } else if !Task.isCancelled {
                lastCheck = .now
            }
        }

        do {
            let currentAccount = try await cloud.accountKey()
            guard generation == accountGeneration else { return }
            checkedAccount = true
            accountStatus = "Connected"
            if account != currentAccount {
                account = currentAccount
                state = load(cacheURL(currentAccount)) ?? LocalState()
            }
            let incoming = try await cloud.snapshot(newerThan: state.snapshot)
            guard generation == accountGeneration else { return }
            lastCloudContact = .now
            switch incoming {
            case .missing:
                remoteWorkspaceFound = false
            case .unchanged:
                remoteWorkspaceFound = true
            case .updated(let incoming):
                let previous = snapshot
                remoteWorkspaceFound = true
                var updated = state
                if updated.snapshot?.workspaceID != incoming.workspaceID {
                    updated.commentDrafts = nil
                    updated.unsavedNotes = nil
                }
                if updated.snapshot == nil, let legacy = load(directory.appending(path: "workspace.json")),
                   legacy.snapshot?.workspaceID == incoming.workspaceID {
                    updated.pending = legacy.pending.filter { $0.workspaceID == incoming.workspaceID }
                }
                for request in updated.pending where request.workspaceID != incoming.workspaceID {
                    updated.waiting[request.id] = "This change belongs to an earlier Mac workspace."
                }
                updated.snapshot = incoming
                try save(updated)
                await announcePickups(from: previous, to: incoming)
            }

            guard let snapshot, remoteWorkspaceFound == true else {
                syncError = nil
                syncErrorCode = nil
                return
            }
            for request in pending where request.workspaceID == snapshot.workspaceID {
                guard generation == accountGeneration else { return }
                let receipt = try await cloud.submit(request)
                guard generation == accountGeneration else { return }
                guard let receipt else { continue }
                var updated = state
                if receipt.isSettled(at: snapshot.revision) {
                    updated.pending.removeAll { $0.id == receipt.requestID }
                    updated.waiting.removeValue(forKey: receipt.requestID)
                    if receipt.outcome == .rejected {
                        let message = receipt.message ?? "The Mac could not apply a queued change."
                        updated.rejected = message
                        if case .editNotes(let taskID, _, let notes) = request.action {
                            updated.unsavedNotes = updated.unsavedNotes ?? [:]
                            updated.unsavedNotes?[taskID] = UnsavedNotes(text: notes, message: message)
                        }
                    }
                    try save(updated)
                    if receipt.outcome == .applied {
                        switch request.action {
                        case .create, .complete, .forceComplete,
                             .editField(_, _, .status(.done, _, _, _)), .setField(_, _, .status(.done, _, _, _)):
                            reviewMilestone.recordActivity()
                        default: break
                        }
                    }
                    try? await cloud.retire(receipt.requestID)
                } else if let message = receipt.message, updated.waiting[receipt.requestID] != message {
                    updated.waiting[receipt.requestID] = message
                    try save(updated)
                }
            }
            if generation == accountGeneration {
                syncError = nil
                syncErrorCode = nil
            }
        } catch {
            guard generation == accountGeneration, !Task.isCancelled else { return }
            if !checkedAccount {
                switch error as? CompanionCloudError {
                case .noAccount: accountStatus = "Signed out"
                case .accountRestricted: accountStatus = "Restricted"
                default: accountStatus = "Unavailable"
                }
            }
            let failure = error as NSError
            syncErrorCode = "\(failure.domain) (\(failure.code))"
            switch (error as? CKError)?.code {
            case .badContainer, .missingEntitlement:
                syncError = "This build couldn’t access the OpenTalon iCloud container."
            case .notAuthenticated:
                syncError = CompanionCloudError.noAccount.localizedDescription
            case .networkUnavailable, .networkFailure:
                syncError = "Check your internet connection and try again."
            default:
                syncError = error.localizedDescription
            }
        }
    }

    func waitingMessage(for request: PhoneRequest) -> String? { state.waiting[request.id] }

    private func announcePickups(from previous: PhoneSnapshot?, to incoming: PhoneSnapshot) async {
        guard let previous, previous.workspaceID == incoming.workspaceID, previous.macName != nil else { return }
        let previousPickups = Set(previous.tasks.compactMap { $0.agentPickup?.id })
        let starts = incoming.tasks.filter { task in
            guard let pickup = task.agentPickup else { return false }
            return !previousPickups.contains(pickup.id)
        }
        guard let first = starts.first, let pickup = first.agentPickup else { return }
        let macName = incoming.macName ?? "your Mac"
        let message = starts.count == 1 ? first.title : "\(starts.count) tasks"
        pickupNotice = "Picked up by \(macName): \(message)"
        guard UserDefaults.standard.bool(forKey: Self.pickupAlertsKey) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Picked up by \(macName)"
        content.body = message
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "OpenTalon-Pickup-" + pickup.id, content: content, trigger: nil)
        )
    }

    func dismissPickupNotice() { pickupNotice = nil }

    func pendingNotes(for taskID: String) -> String? {
        taskChanges(for: taskID).reversed().compactMap { request -> String? in
            if case .editNotes(_, _, let notes) = request.action { return notes }
            return nil
        }.first
    }

    private func pendingField(for taskID: String, field: PhoneTaskFieldEdit.Field) -> PhoneTaskFieldEdit? {
        for request in taskChanges(for: taskID).reversed() {
            switch request.action {
            case .editField(_, _, let edit), .setField(_, _, let edit):
                if edit.field == field { return edit }
            default: break
            }
        }
        return nil
    }

    func pendingTaskChange(for taskID: String) -> PhoneRequest? {
        taskChanges(for: taskID).last
    }

    private func taskChanges(for taskID: String) -> [PhoneRequest] {
        pending.filter {
            $0.workspaceID == snapshot?.workspaceID && $0.taskID == taskID && $0.changesTask
        }
    }

    func displayedStatus(for task: PhoneTask) -> PhoneTask.Status {
        for request in taskChanges(for: task.id).reversed() {
            switch request.action {
            case .complete, .forceComplete: return .done
            case .send: return .sent
            case .editField(_, _, .status(let status, _, _, _)),
                 .setField(_, _, .status(let status, _, _, _)): return status
            default: break
            }
        }
        return task.status
    }

    func displayedPriority(for task: PhoneTask) -> PhoneTask.Priority {
        if case .priority(let priority) = pendingField(for: task.id, field: .priority) { return priority }
        return task.priority
    }

    func displayedProject(for task: PhoneTask) -> String {
        if case .project(let id) = pendingField(for: task.id, field: .project) { return id }
        return task.projectID
    }

    func hasPendingProjectMove(for task: PhoneTask) -> Bool {
        pendingField(for: task.id, field: .project) != nil
    }

    var pendingArchiveRemovals: [String: Bool] {
        var removals: [String: Bool] = [:]
        for request in pending where request.workspaceID == snapshot?.workspaceID {
            switch request.action {
            case .removeArchived(let id, _, let permanently):
                removals[id] = permanently
            case .manageArchive(let ids, _, let permanently):
                for id in ids { removals[id] = permanently }
            default: break
            }
        }
        return removals
    }

    var displayedTrash: [PhoneTrashedTask]? {
        guard let snapshot, let savedTrash = snapshot.trashedTasks else { return nil }
        let removals = pendingArchiveRemovals
        let trashedIDs = Set(savedTrash.map(\.id))
        let queued = snapshot.tasks.filter { removals[$0.id] == false && !trashedIDs.contains($0.id) }
        return queued.map {
            PhoneTrashedTask(id: $0.id, projectID: displayedProject(for: $0), title: $0.title, revision: $0.revision)
        } + savedTrash
    }

    func displayedDueDate(for task: PhoneTask) -> String? {
        if case .dueDate(let date) = pendingField(for: task.id, field: .dueDate) { return date }
        return task.dueDate
    }

    func orderedTasks(_ tasks: [PhoneTask], byPriority: Bool = false) -> [PhoneTask] {
        tasks.sorted {
            let priority = displayedPriority(for: $0)
            let otherPriority = displayedPriority(for: $1)
            if byPriority && priority != otherPriority { return priority.rank < otherPriority.rank }
            return TaskCreationOrder.precedes(urgent: priority == .urgent, createdAt: $0.createdAt,
                                              otherUrgent: otherPriority == .urgent, otherCreatedAt: $1.createdAt)
                ?? ($0.id < $1.id)
        }
    }

    func manualTaskOrder(_ tasks: [PhoneTask], projectID: String, status: PhoneTask.Status) -> [PhoneTask] {
        func position(_ task: PhoneTask) -> Int {
            guard task.projectID == projectID, task.status == status else { return .max }
            return task.position ?? .max
        }

        var ordered = tasks.sorted { (position($0), $0.id) < (position($1), $1.id) }
        for request in pending where request.workspaceID == snapshot?.workspaceID {
            guard case .reorderTask(let id, let destination, let lane, let anchorID, let before) = request.action,
                  destination == projectID, lane == status,
                  let source = ordered.firstIndex(where: { $0.id == id }),
                  let target = ordered.firstIndex(where: { $0.id == anchorID }), source != target else { continue }
            let item = ordered.remove(at: source)
            let anchor = target - (source < target ? 1 : 0)
            ordered.insert(item, at: anchor + (before ? 0 : 1))
        }
        return ordered
    }

    func title(for request: PhoneRequest) -> String {
        switch request.action {
        case .create(_, let title, _, _, _, _, _, _, _, _): title
        case .emptyTrash: "Trash"
        case .manageArchive: "Archive"
        case .restoreTrashed(let id, _): snapshot?.trashedTasks?.first(where: { $0.id == id })?.title ?? "Task"
        case .send(let id, _, _), .complete(let id, _), .comment(let id, _), .editNotes(let id, _, _),
             .editField(let id, _, _), .setField(let id, _, _), .forceComplete(let id), .removeArchived(let id, _, _),
             .reorderTask(let id, _, _, _, _):
            snapshot?.tasks.first(where: { $0.id == id })?.title ?? "Task"
        }
    }

    func clearRejection() {
        var updated = state
        updated.rejected = nil
        try? save(updated)
    }

    func projectName(_ id: String) -> String {
        snapshot?.projects.first(where: { $0.id == id })?.name ?? "Project"
    }

    private func cacheURL(_ account: String) -> URL {
        directory.appending(path: "cloud-" + account + ".json")
    }

    private func load(_ url: URL) -> LocalState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LocalState.self, from: data)
    }

    private func save(_ updated: LocalState) throws {
        guard let account else { throw CompanionCloudError.accountUnavailable }
        var directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try JSONEncoder().encode(updated).write(to: cacheURL(account), options: [.atomic, .completeFileProtection])
        state = updated
    }
}
