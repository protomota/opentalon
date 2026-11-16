import AppKit
import ServiceManagement
import SwiftUI

struct DailyBackupStatus: Decodable {
    let enabled: Bool
    let folder: String
    let usesDefaultFolder: Bool
    let lastBackupAt: String?
    let lastError: String
}

enum BackupAgent {
    static let plist = "com.protomota.opentalon.native.daily-backup.plist"
    static var service: SMAppService { .agent(plistName: plist) }
}

struct DailyBackupView: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var status: DailyBackupStatus?
    @State private var background = SMAppService.Status.notRegistered
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Daily backups").font(.system(size: 13, weight: .semibold))
            if let status {
                Toggle("Automatically save a backup each day", isOn: Binding(
                    get: { status.enabled },
                    set: { configure(["enabled": $0]) }
                ))
                Text("OpenTalon checks for today’s backup when it opens and while it runs, including when its window is closed.")
                    .font(.caption).foregroundStyle(palette.muted)
                if !model.isolatedProfile && status.enabled {
                    Toggle("Back up even when OpenTalon is quit", isOn: Binding(
                        get: { background == .enabled || background == .requiresApproval },
                        set: configureBackground
                    ))
                    if background == .requiresApproval {
                        HStack {
                            Text("Allow OpenTalon in Login Items & Extensions to finish enabling daily background backups.")
                                .font(.caption).foregroundStyle(palette.muted)
                            Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
                        }
                    } else if background == .enabled {
                        Text("macOS checks at 3:00 a.m. local time while you’re signed in.")
                            .font(.caption).foregroundStyle(palette.muted)
                    }
                }
                Label(status.folder, systemImage: "folder").font(.caption)
                    .foregroundStyle(palette.muted).lineLimit(2).textSelection(.enabled)
                HStack {
                    Button("Choose folder…") {
                        run {
                            guard let folder = await chooseDirectory("Choose a daily backup folder", prompt: "Use this folder") else { return }
                            statusUpdate(try await model.service.call("native_daily_configure", ["folder": folder.path]))
                        }
                    }
                    if !status.usesDefaultFolder {
                        Button("Use default folder") { configure(["folder": NSNull()]) }
                    }
                    Button("Show backups") {
                        let url = URL(fileURLWithPath: status.folder, isDirectory: true)
                        if !NSWorkspace.shared.open(url) { error = "The backup folder is unavailable." }
                    }
                    .disabled(!FileManager.default.fileExists(atPath: status.folder))
                    Spacer()
                    Button("Back up now") {
                        run { statusUpdate(try await model.service.call("native_daily_run")) }
                    }
                }
                if let stamp = status.lastBackupAt {
                    let iso = ISO8601DateFormatter()
                    let date = iso.date(from: stamp) ?? ISO8601DateFormatter.backupDate(stamp)
                    Text("Last saved: \(date?.formatted(date: .abbreviated, time: .shortened) ?? stamp)")
                        .font(.caption).foregroundStyle(palette.muted)
                }
                if !status.lastError.isEmpty { Text(status.lastError).font(.caption).foregroundStyle(palette.danger) }
            } else {
                ProgressView().controlSize(.small)
            }
            if let error { Text(error).font(.caption).foregroundStyle(palette.danger) }
        }
        .padding(13)
        .surface()
        .disabled(busy)
        .task(id: model.backupSignal) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !model.isolatedProfile { background = BackupAgent.service.status }
        }
    }

    private func reload() async {
        do {
            statusUpdate(try await model.service.call("native_daily_status"))
            if !model.isolatedProfile { background = BackupAgent.service.status }
        } catch { self.error = error.localizedDescription }
    }

    private func statusUpdate(_ status: DailyBackupStatus) { self.status = status }

    private func configure(_ fields: [String: Any]) {
        run {
            statusUpdate(try await model.service.call("native_daily_configure", fields))
            if fields["enabled"] as? Bool == false,
               background == .enabled || background == .requiresApproval {
                try await BackupAgent.service.unregister()
                background = BackupAgent.service.status
            }
        }
    }

    private func configureBackground(_ enable: Bool) {
        run {
            defer { background = BackupAgent.service.status }
            if enable { try BackupAgent.service.register() }
            else { try await BackupAgent.service.unregister() }
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await operation() }
            catch let failure { error = failure.localizedDescription }
        }
    }
}

private extension ISO8601DateFormatter {
    static func backupDate(_ stamp: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: stamp)
    }
}
