import CloudKit
import CryptoKit
import Foundation
#if os(macOS)
import Security
#endif

public enum CompanionCloudError: LocalizedError {
    case missingCapability, accountUnavailable, noAccount, accountRestricted, accountChanged, invalidRecord, workspaceOwnedElsewhere

    public var errorDescription: String? {
        switch self {
        case .missingCapability: "This build is missing the OpenTalon iCloud capability."
        case .accountUnavailable: "iCloud is unavailable. OpenTalon will retry automatically."
        case .noAccount: "Sign in to your Apple Account in system Settings to sync with iCloud."
        case .accountRestricted: "This device restricts access to iCloud."
        case .accountChanged: "OpenTalon will sync when the original Apple Account is available."
        case .invalidRecord: "OpenTalon couldn’t read the iCloud data."
        case .workspaceOwnedElsewhere: "This Apple Account already syncs an OpenTalon workspace from another Mac."
        }
    }
}

public enum CompanionSnapshotUpdate {
    case missing
    case unchanged
    case updated(PhoneSnapshot)
}

@MainActor
public protocol CompanionTransport {
    func accountKey() async throws -> String
    func prepare(account: String) async throws
    func publish(_ snapshot: PhoneSnapshot) async throws
    func snapshot(newerThan cached: PhoneSnapshot?) async throws -> CompanionSnapshotUpdate
    func pendingRequests(for workspaceID: UUID) async throws -> [PhoneRequest]
    func submit(_ request: PhoneRequest) async throws -> PhoneReceipt?
    func acknowledge(_ receipt: PhoneReceipt) async throws
    func retire(_ id: UUID) async throws
}

@MainActor
public final class CompanionCloud: CompanionTransport {
    public static let containerID = "iCloud.com.protomota.opentalon"
    private static let zone = CKRecordZone(zoneName: "OpenTalon")
    private static let recordType = "OpenTalonSync"
    private static let snapshotName = "workspace"
    private static let requestPrefix = "request-"
    private lazy var container = CKContainer(identifier: Self.containerID)
    private var database: CKDatabase { container.privateCloudDatabase }
    private var preparedAccount: String?
    private var token: CKServerChangeToken?
    private var pendingIDs = Set<CKRecord.ID>()
    private var inspectedSnapshotTag: String?
    private var inspectedAvailableAgents: [PhoneAgent]?
    private var inspectedDefaultAgent: PhoneAgent?
    private var inspectedAgentModels: [AgentModelChoice]?
    private var inspectedCaptureProjectID: String?
    private var inspectedMacName: String?
    private var inspectedProjectionVersion: Int?

    public init() {}

    public func accountKey() async throws -> String {
#if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String],
              containers.contains(Self.containerID) else { throw CompanionCloudError.missingCapability }
#endif
        switch try await container.accountStatus() {
        case .available: break
        case .noAccount: throw CompanionCloudError.noAccount
        case .restricted: throw CompanionCloudError.accountRestricted
        default: throw CompanionCloudError.accountUnavailable
        }
        let record = try await container.userRecordID()
        return SHA256.hash(data: Data(record.recordName.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func prepare(account: String) async throws {
        guard preparedAccount != account else { return }
        do {
            let result = try await database.recordZones(for: [Self.zone.zoneID])
            guard let zone = result[Self.zone.zoneID] else { throw CompanionCloudError.invalidRecord }
            _ = try zone.get()
        } catch let error as CKError where [.zoneNotFound, .userDeletedZone, .unknownItem].contains(error.code) {
            _ = try await database.save(Self.zone)
        }
        preparedAccount = account
        token = nil
        pendingIDs.removeAll()
        inspectedSnapshotTag = nil
    }

    public func publish(_ snapshot: PhoneSnapshot) async throws {
        let id = recordID(Self.snapshotName)
        let current = try await fetch(id, keys: ["workspaceID", "revision"])
        if let current {
            guard current["workspaceID"] as? String == snapshot.workspaceID.uuidString else {
                throw CompanionCloudError.workspaceOwnedElsewhere
            }
            let revision = current["revision"] as? Int ?? -1
            if revision > snapshot.revision { return }
            if revision == snapshot.revision {
                guard snapshot.projectionVersion > 0 else { return }
                if let inspectedSnapshotTag, inspectedSnapshotTag == current.recordChangeTag,
                   inspectedAvailableAgents == snapshot.availableAgents,
                   inspectedDefaultAgent == snapshot.defaultAgent,
                   inspectedAgentModels == snapshot.agentModels,
                   inspectedCaptureProjectID == snapshot.captureProjectID,
                   inspectedMacName == snapshot.macName,
                   inspectedProjectionVersion == snapshot.projectionVersion { return }
                guard let full = try await fetch(id, keys: ["payload"]),
                      full.recordChangeTag == current.recordChangeTag else { return }
                let stored: PhoneSnapshot = try decodeAsset(full, limit: 32 * 1024 * 1024)
                if !snapshot.shouldReplace(stored) {
                    inspectedSnapshotTag = current.recordChangeTag
                    inspectedAvailableAgents = snapshot.availableAgents
                    inspectedDefaultAgent = snapshot.defaultAgent
                    inspectedAgentModels = snapshot.agentModels
                    inspectedCaptureProjectID = snapshot.captureProjectID
                    inspectedMacName = snapshot.macName
                    inspectedProjectionVersion = snapshot.projectionVersion
                    return
                }
            }
        }
        let record = current ?? CKRecord(recordType: Self.recordType, recordID: id)
        let url = try assetFile(snapshot, limit: 32 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: url) }
        record["workspaceID"] = snapshot.workspaceID.uuidString
        record["revision"] = snapshot.revision
        record["payload"] = CKAsset(fileURL: url)
        try await save(record)
    }

    public func snapshot(newerThan cached: PhoneSnapshot?) async throws -> CompanionSnapshotUpdate {
        let id = recordID(Self.snapshotName)
        if let cached {
            guard let header = try await fetch(id, keys: ["workspaceID", "revision"]) else { return .missing }
            if header["workspaceID"] as? String == cached.workspaceID.uuidString,
               header["revision"] as? Int == cached.revision,
               inspectedSnapshotTag != nil, inspectedSnapshotTag == header.recordChangeTag {
                return .unchanged
            }
        }
        guard let record = try await fetch(id, keys: ["payload"]) else { return .missing }
        let result: PhoneSnapshot = try decodeAsset(record, limit: 32 * 1024 * 1024)
        guard result.version == 1 else { throw CompanionSyncError.unsupportedVersion }
        inspectedSnapshotTag = record.recordChangeTag
        return .updated(result)
    }

    public func pendingRequests(for workspaceID: UUID) async throws -> [PhoneRequest] {
        do {
            try await collectChanges()
        } catch let error as CKError where error.code == .changeTokenExpired {
            token = nil
            pendingIDs.removeAll()
            try await collectChanges()
        }
        var requests: [PhoneRequest] = []
        for id in pendingIDs {
            guard let record = try await fetch(id, keys: ["workspaceID", "payload", "receipt"]),
                  record["workspaceID"] as? String == workspaceID.uuidString else { continue }
            if let receipt = try decodeReceipt(record), receipt.outcome != .waiting { continue }
            let request: PhoneRequest = try decodeAsset(record, limit: 1024 * 1024)
            guard request.workspaceID == workspaceID, id == requestID(request.id) else { continue }
            requests.append(request)
        }
        return requests.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    public func submit(_ request: PhoneRequest) async throws -> PhoneReceipt? {
        let id = requestID(request.id)
        if let existing = try await fetch(id, keys: ["receipt"]) { return try decodeReceipt(existing) }
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        let url = try assetFile(request, limit: 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: url) }
        record["workspaceID"] = request.workspaceID.uuidString
        record["payload"] = CKAsset(fileURL: url)
        try await save(record)
        return nil
    }

    public func acknowledge(_ receipt: PhoneReceipt) async throws {
        let id = requestID(receipt.requestID)
        guard let record = try await fetch(id, keys: ["workspaceID", "payload", "receipt"]) else { return }
        if let previous = try decodeReceipt(record), previous == receipt || previous.outcome != .waiting { return }
        record["receipt"] = try JSONEncoder().encode(receipt)
        try await save(record)
        if receipt.outcome != .waiting { pendingIDs.remove(id) }
    }

    public func retire(_ id: UUID) async throws {
        _ = try await database.deleteRecord(withID: requestID(id))
    }

    private func collectChanges() async throws {
        var more: Bool
        repeat {
            let batch = try await database.recordZoneChanges(
                inZoneWith: Self.zone.zoneID, since: token, desiredKeys: ["receipt"]
            )
            for (id, change) in batch.modificationResultsByID where id.recordName.hasPrefix(Self.requestPrefix) {
                let record = try change.get().record
                if let receipt = try decodeReceipt(record), receipt.outcome != .waiting {
                    pendingIDs.remove(id)
                } else {
                    pendingIDs.insert(id)
                }
            }
            for deletion in batch.deletions { pendingIDs.remove(deletion.recordID) }
            token = batch.changeToken
            more = batch.moreComing
        } while more
    }

    private func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: Self.zone.zoneID)
    }

    private func requestID(_ id: UUID) -> CKRecord.ID {
        recordID(Self.requestPrefix + id.uuidString)
    }

    private func fetch(_ id: CKRecord.ID, keys: [String]) async throws -> CKRecord? {
        do {
            return try await database.records(for: [id], desiredKeys: keys)[id]?.get()
        } catch let error as CKError where [.unknownItem, .zoneNotFound, .userDeletedZone].contains(error.code) {
            return nil
        }
    }

    private func save(_ record: CKRecord) async throws {
        let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
        guard let saved = result.saveResults[record.recordID] else { throw CompanionCloudError.invalidRecord }
        _ = try saved.get()
    }

    private func decodeReceipt(_ record: CKRecord) throws -> PhoneReceipt? {
        guard let bytes = record["receipt"] as? Data else { return nil }
        return try JSONDecoder().decode(PhoneReceipt.self, from: bytes)
    }

    private func assetFile<Value: Encodable>(_ value: Value, limit: Int) throws -> URL {
        let bytes = try JSONEncoder().encode(value)
        guard bytes.count <= limit else { throw CompanionSyncError.oversizedRecord }
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try bytes.write(to: url, options: .atomic)
        return url
    }

    private func decodeAsset<Value: Decodable>(_ record: CKRecord, limit: Int) throws -> Value {
        guard let url = (record["payload"] as? CKAsset)?.fileURL else { throw CompanionCloudError.invalidRecord }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= limit else { throw CompanionSyncError.oversizedRecord }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
    }
}
