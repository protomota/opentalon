import AppKit
import Foundation

struct ServiceFailure: LocalizedError {
    var code: String
    var message: String
    var current: WorkItem?
    var errorDescription: String? { message }
}

struct EmptyResponse: Decodable {}
struct ValueResponse: Decodable { let value: String }
struct PathResponse: Decodable { let path: String }
struct ItemResponse: Decodable { let task: WorkItem }
struct BoardResponse: Decodable { let board: Board }

@MainActor
final class Service {
    private let input = Pipe()
    private let output = Pipe()
    private let process = Process()
    private let io = DispatchQueue(label: "com.protomota.opentalon.service")
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var buffer = Data()
    private(set) var ready = false
    private var closed = false
    var onReady: (() -> Void)?
    var onChange: (() -> Void)?
    var onBackupChange: (() -> Void)?
    var onChatActivity: ((String, String?) -> Void)?
    var onFailure: ((ServiceFailure) -> Void)?
    var onExit: (() -> Void)?

    func start(profile: URL, visible: Bool) throws {
        guard let resources = Bundle.main.resourceURL, let executable = Bundle.main.executableURL else {
            throw ServiceFailure(code: "BUNDLE", message: "Open the built OpenTalon app from Finder.")
        }
        process.executableURL = resources.deletingLastPathComponent().appendingPathComponent("Helpers/node")
        process.arguments = [
            resources.appendingPathComponent("service/service.cjs").path, profile.path,
            executable.path, Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
            visible ? "visible" : "hidden"
        ]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        environment.removeValue(forKey: "NODE_OPTIONS")
        environment.removeValue(forKey: "NODE_PATH")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in self?.didExit(status: status) }
        }
        // All byte chunks go to the same main-queue consumer in order.
        output.fileHandleForReading.readabilityHandler = { [weak self] file in
            let bytes = file.availableData
            if bytes.isEmpty { file.readabilityHandler = nil }
            DispatchQueue.main.async { self?.receive(bytes) }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw error
        }
    }

    func call<Response: Decodable>(_ name: String, _ fields: [String: Any] = [:]) async throws -> Response {
        let id = UUID().uuidString
        var packet = try JSONSerialization.data(withJSONObject: ["id": id, "name": name, "input": fields])
        guard packet.count <= 20 * 1024 * 1024 else {
            throw ServiceFailure(code: "INVALID_ARGUMENT", message: "This request is too large.")
        }
        packet.append(0x0a)
        let bytes = packet
        let response: Data = try await withCheckedThrowingContinuation { continuation in
            guard ready, !closed else {
                continuation.resume(throwing: unavailable)
                return
            }
            pending[id] = continuation
            let writer = input.fileHandleForWriting
            io.async { [weak self] in
                do { try writer.write(contentsOf: bytes) }
                catch {
                    DispatchQueue.main.async {
                        self?.pending.removeValue(forKey: id)?.resume(throwing: error)
                    }
                }
            }
        }
        return try JSONDecoder().decode(Response.self, from: response)
    }

    private var unavailable: ServiceFailure {
        ServiceFailure(code: "SERVICE_CLOSED", message: "The local workspace service closed. Reopen OpenTalon to continue.")
    }

    private func receive(_ bytes: Data) {
        buffer.append(bytes)
        while let end = buffer.firstIndex(of: 0x0a) {
            let line = buffer.prefix(upTo: end)
            buffer.removeSubrange(...end)
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            switch object["event"] as? String {
            case "ready":
                ready = true
                onReady?()
            case "changed":
                if ready { onChange?() }
            case "backup-changed":
                onBackupChange?()
            case "agent-chat-activity":
                if let name = object["name"] as? String { onChatActivity?(name, object["title"] as? String) }
            case "failed":
                onFailure?(failure(object["error"] as? [String: Any]))
            default:
                guard let id = object["id"] as? String,
                      let continuation = pending.removeValue(forKey: id) else { continue }
                if let error = object["error"] as? [String: Any] {
                    continuation.resume(throwing: failure(error))
                } else {
                    do {
                        let data = try JSONSerialization.data(withJSONObject: object["data"] ?? NSNull(), options: .fragmentsAllowed)
                        continuation.resume(returning: data)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
    }

    private func failure(_ fields: [String: Any]?) -> ServiceFailure {
        var current: WorkItem?
        if let details = fields?["details"] as? [String: Any], let record = details["current"],
           let data = try? JSONSerialization.data(withJSONObject: record) {
            current = try? JSONDecoder().decode(WorkItem.self, from: data)
        }
        return ServiceFailure(
            code: fields?["code"] as? String ?? "SERVICE_ERROR",
            message: fields?["message"] as? String ?? unavailable.message,
            current: current
        )
    }

    func stop() {
        guard !closed else { return }
        closed = true
        let writer = input.fileHandleForWriting
        io.async { try? writer.close() }
    }

    private func didExit(status: Int32) {
        let wasClosing = closed
        ready = false
        closed = true
        output.fileHandleForReading.readabilityHandler = nil
        for continuation in pending.values { continuation.resume(throwing: unavailable) }
        pending.removeAll()
        if !wasClosing {
            NSLog("OpenTalon workspace service exited with status %d", status)
            onFailure?(unavailable)
        }
        onExit?()
    }
}
