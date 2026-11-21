#if DEBUG && (os(macOS) || targetEnvironment(simulator))
import CryptoKit
import Foundation

/// A file transport for exercising the real Mac and Simulator apps without an Apple Account.
@MainActor
public final class LocalCompanionTransport: CompanionTransport {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func accountKey() async throws -> String {
        let key = SHA256.hash(data: Data(directory.path.utf8))
        return "local-" + key.map { String(format: "%02x", $0) }.joined()
    }

    public func prepare(account: String) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func publish(_ snapshot: PhoneSnapshot) async throws {
        let url = directory.appending(path: "snapshot.json")
        if let current: PhoneSnapshot = try read(url) {
            guard current.workspaceID == snapshot.workspaceID else { throw CompanionCloudError.workspaceOwnedElsewhere }
            guard snapshot.shouldReplace(current) else { return }
        }
        try write(snapshot, to: url)
    }

    public func snapshot(newerThan cached: PhoneSnapshot?) async throws -> CompanionSnapshotUpdate {
        guard let latest: PhoneSnapshot = try read(directory.appending(path: "snapshot.json")) else { return .missing }
        guard latest.version == 1 else { throw CompanionSyncError.unsupportedVersion }
        if latest.workspaceID == cached?.workspaceID, latest.revision == cached?.revision,
           latest.projectionVersion == cached?.projectionVersion,
           latest.defaultAgent == cached?.defaultAgent, latest.availableAgents == cached?.availableAgents,
           latest.agentModels == cached?.agentModels,
           latest.agentConnectionReady == cached?.agentConnectionReady { return .unchanged }
        return .updated(latest)
    }

    public func pendingRequests(for workspaceID: UUID) async throws -> [PhoneRequest] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let requests = try files.filter { $0.lastPathComponent.hasPrefix("request-") }.compactMap { file -> PhoneRequest? in
            guard let request: PhoneRequest = try read(file), request.workspaceID == workspaceID else { return nil }
            let receipt: PhoneReceipt? = try read(url("receipt", request.id))
            return receipt == nil || receipt?.outcome == .waiting ? request : nil
        }
        return requests.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    public func submit(_ request: PhoneRequest) async throws -> PhoneReceipt? {
        let file = url("request", request.id)
        if !FileManager.default.fileExists(atPath: file.path) { try write(request, to: file) }
        return try read(url("receipt", request.id))
    }

    public func acknowledge(_ receipt: PhoneReceipt) async throws {
        let file = url("receipt", receipt.requestID)
        if let previous: PhoneReceipt = try read(file), previous.outcome != .waiting { return }
        try write(receipt, to: file)
    }

    public func retire(_ id: UUID) async throws {
        try FileManager.default.removeItem(at: url("request", id))
        try FileManager.default.removeItem(at: url("receipt", id))
    }

    private func url(_ prefix: String, _ id: UUID) -> URL {
        directory.appending(path: "\(prefix)-\(id.uuidString).json")
    }

    private func read<Value: Decodable>(_ url: URL) throws -> Value? {
        do { return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
#endif
