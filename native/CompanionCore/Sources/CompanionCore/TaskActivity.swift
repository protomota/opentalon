import SwiftUI

public struct TaskActivityImage: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let mimeType: String
}

public struct TaskActivityEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sequence: Int
    public let createdAt: String
    public let actor: String
    public let kind: String
    public let summary: String
    public let detail: String
    public let images: [TaskActivityImage]

    public var symbol: String {
        switch kind {
        case "agent": "sparkles"
        case "comment": "bubble.left"
        case "legacy": "clock.arrow.circlepath"
        case "restore": "arrow.uturn.backward"
        default: "arrow.left.arrow.right"
        }
    }
    public var dateLabel: String {
        TaskCreationOrder.date(from: createdAt)?.formatted(date: .abbreviated, time: .shortened) ?? createdAt
    }
}

public struct TaskActivityPage: Codable, Equatable, Sendable {
    public let taskID: String
    public let revision: Int
    public let entries: [TaskActivityEntry]
    public let nextBefore: Int?

    public func merging(_ older: Self) -> Self {
        guard taskID == older.taskID else { return self }
        let values = Dictionary((entries + older.entries).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Self(taskID: taskID, revision: max(revision, older.revision),
                    entries: values.values.sorted { $0.sequence > $1.sequence }, nextBefore: older.nextBefore)
    }

    public func keepingOlder(from cached: Self) -> Self {
        guard taskID == cached.taskID, nextBefore != nil else { return self }
        let known = Set(cached.entries.map(\.id))
        if entries.contains(where: { $0.kind == "restore" && !known.contains($0.id) }) { return self }
        guard entries.contains(where: { known.contains($0.id) }) ||
              cached.entries.first?.sequence == (entries.last?.sequence ?? 0) - 1 else { return self }
        return merging(cached)
    }
}

public struct TaskActivitySummary: View {
    let page: TaskActivityPage
    let colors: OpenTalonColors
    let open: () -> Void
    public init(page: TaskActivityPage, colors: OpenTalonColors, open: @escaping () -> Void) {
        self.page = page; self.colors = colors; self.open = open
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if page.entries.isEmpty { Text("No activity yet.").foregroundStyle(colors.muted) }
            ForEach(Array(page.entries.prefix(3))) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: entry.symbol).foregroundStyle(colors.actionAccent).frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.summary).font(.callout.weight(.medium))
                        Text(entry.actor + " · " + entry.dateLabel).font(.caption).foregroundStyle(colors.muted)
                    }
                }
            }
            Button("View all activity", systemImage: "clock.arrow.circlepath", action: open)
                .buttonStyle(ActivityPillStyle(colors: colors))
                .accessibilityIdentifier("taskActivity")
        }
    }
}

public struct TaskActivityView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var expanded = Set<String>()
    @State private var failure: String?
    @State private var loading = false
    let page: TaskActivityPage?
    let colors: OpenTalonColors
    let waitingForMac: Bool
    let load: @MainActor (Int?) async throws -> Void
    let openImage: ((TaskActivityImage) -> Void)?

    public init(page: TaskActivityPage?, colors: OpenTalonColors, waitingForMac: Bool = false,
                load: @escaping @MainActor (Int?) async throws -> Void,
                openImage: ((TaskActivityImage) -> Void)? = nil) {
        self.page = page; self.colors = colors; self.waitingForMac = waitingForMac
        self.load = load; self.openImage = openImage
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                Button("Close") { dismiss() }.accessibilityIdentifier("activityClose")
            }.padding(20)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text("Task changes and agent updates. Your messages stay in Comments.")
                        .font(.callout).foregroundStyle(colors.muted)
                    if let failure { Text(failure).foregroundStyle(colors.danger) }
                    if waitingForMac {
                        Label("Waiting for your Mac to load activity…", systemImage: "clock")
                            .font(.footnote).foregroundStyle(colors.muted)
                    }
                    if let page {
                        ForEach(page.entries) { entry in activityRow(entry) }
                        if page.entries.isEmpty { Text("No activity yet.").foregroundStyle(colors.muted) }
                        if let before = page.nextBefore {
                            Button("Load older activity") { fetch(before) }
                                .disabled(loading || waitingForMac).accessibilityIdentifier("activityLoadOlder")
                        }
                    } else { ProgressView("Loading activity…") }
                }.padding(20)
            }
        }
        .foregroundStyle(colors.text).background(colors.canvas)
        .buttonStyle(ActivityPillStyle(colors: colors)).tint(colors.actionAccent)
        .task { fetch(nil) }
    }
    private func activityRow(_ entry: TaskActivityEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: entry.symbol).foregroundStyle(colors.actionAccent).frame(width: 22)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.summary).font(.headline)
                    Text(entry.actor + " · " + entry.dateLabel).font(.caption).foregroundStyle(colors.muted)
                }
            }
            if !entry.detail.isEmpty {
                DisclosureGroup("Details", isExpanded: Binding(get: { expanded.contains(entry.id) }, set: { value in
                    if value { expanded.insert(entry.id) } else { expanded.remove(entry.id) }
                })) {
                    Text(entry.detail).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
                .accessibilityIdentifier("activityDetails-" + entry.id)
            }
            ForEach(entry.images) { image in
                if let openImage {
                    Button(image.name, systemImage: "photo") { openImage(image) }
                } else { Label(image.name + " · Saved on your Mac", systemImage: "photo").font(.footnote) }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.card, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("activityEntry-" + entry.id)
    }
    private func fetch(_ before: Int?) {
        guard !loading else { return }; loading = true; failure = nil
        Task { @MainActor in
            defer { loading = false }
            do { try await load(before) } catch { failure = error.localizedDescription }
        }
    }
}

private struct ActivityPillStyle: ButtonStyle {
    let colors: OpenTalonColors
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.callout.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(colors.card.opacity(configuration.isPressed ? 0.65 : 1), in: Capsule())
            .overlay { Capsule().strokeBorder(colors.line, lineWidth: 1) }
    }
}
