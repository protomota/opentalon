import AppKit
import CompanionCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private struct CommentsResponse: Decodable { let comments: [WorkComment] }
private struct CommentCheck: Decodable { let queued: Int }

struct TaskComments: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    let item: WorkItem
    @Binding var dirty: Bool
    @State private var comments: [WorkComment] = []
    @State private var text = ""
    @State private var images: [DraftImage] = []
    @State private var posting = false
    @State private var feedback: String?
    @State private var requestKey = UUID().uuidString
    @State private var zoom: DraftImage?
    @State private var linkedComment: WorkComment?
    @State private var composing = false
    @FocusState private var commentFocused: Bool

    private var assigned: Bool { model.workspace?.agentAssignments[item.id] != nil }
    private var hasDraft: Bool { !text.isEmpty || !images.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(TaskRevisionRequestCopy.heading).font(.system(size: 13, weight: .semibold))
                Spacer()
                if assigned && item.status == .working && model.canUseAgents {
                    Button("Check now") {
                        model.perform {
                            let result: CommentCheck = try await model.service.call("check_task_comments")
                            feedback = result.queued == 0 ? "No pending revision requests." : "Revision requests queued."
                            await load()
                        }
                    }.buttonStyle(.link).font(.caption)
                }
            }
            if comments.isEmpty {
                Text("No revision requests yet.").font(.caption).foregroundStyle(palette.muted)
            }
            ForEach(comments) { comment in commentCard(comment) }
            if composing {
                composer
            } else {
                Button {
                    composing = true
                } label: {
                    Label(TaskRevisionRequestCopy.add, systemImage: "plus")
                }
                .buttonStyle(GlassActionStyle())
            }
            Text(assigned && item.status == .working && model.canUseAgents
                 ? "OpenTalon sends requests to the assigned agent at its next five-minute check."
                 : "Requests stay with this task for the next agent run.")
                .font(.caption).foregroundStyle(palette.muted)
            if let feedback { Text(feedback).font(.caption).foregroundStyle(palette.muted) }
        }
        .disabled(posting)
        .task(id: model.workspace?.revision) { await load() }
        .onChange(of: text) { _, _ in draftChanged() }
        .onChange(of: images.map(\.id)) { _, _ in draftChanged() }
        .onChange(of: posting) { _, _ in dirty = hasDraft || posting }
        .sheet(item: $linkedComment) { comment in
            TaskActivityPanel(taskID: item.id, commentID: comment.id)
        }
        .sheet(item: $zoom) { image in
            VStack(alignment: .trailing) {
                HStack {
                    Text(image.name).lineLimit(1)
                    Spacer()
                    Button("Done") { zoom = nil }
                }
                if let full = image.image {
                    Image(nsImage: full).resizable().scaledToFit().frame(maxHeight: 520)
                }
            }
            .padding(18).frame(width: 680)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(TaskRevisionRequestCopy.example)
                            .foregroundStyle(palette.muted)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .padding(5)
                .frame(height: 68)
                .surface()
                .accessibilityLabel(TaskRevisionRequestCopy.field)
                .accessibilityHint(TaskRevisionRequestCopy.example)
                .focused($commentFocused)
                .onAppear { commentFocused = true }
            if !images.isEmpty {
                HStack {
                    ForEach(images) { image in
                        VStack(spacing: 3) {
                            if let thumbnail = image.image {
                                Image(nsImage: thumbnail).resizable().scaledToFit().frame(width: 63, height: 43)
                            }
                            Button("Remove", role: .destructive) { images.removeAll { $0.id == image.id } }
                                .buttonStyle(.link).font(.caption2)
                        }
                    }
                }
            }
            HStack(spacing: 5) {
                IconButton(symbol: "paperclip", label: "Attach screenshots", action: attach)
                    .disabled(images.count >= 3)
                IconButton(symbol: "clipboard", label: "Paste screenshot", action: paste)
                    .disabled(images.count >= 3)
                Button(hasDraft ? "Discard" : "Cancel") { closeComposer() }
                    .buttonStyle(.link).font(.caption)
                Spacer(minLength: 0)
                Button(posting ? "Sending…" : TaskRevisionRequestCopy.send, action: post)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty)
            }
        }
    }

    private func commentCard(_ comment: WorkComment) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(comment.agent?.title ?? "You").fontWeight(.semibold)
                Text(Self.dateLabel(comment.createdAt)).foregroundStyle(palette.muted)
            }
            .font(.caption2)
            if !comment.text.isEmpty { Text(comment.text).font(.system(size: 12)).textSelection(.enabled) }
            if !comment.images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(comment.images) { image in
                        SavedScreenshot(image: image) { zoom = $0 }
                    }
                }
            }
            if comment.actedOnAt != nil, comment.activityID != nil {
                Button("Acted on · View activity", systemImage: "checkmark.circle") { linkedComment = comment }
                    .buttonStyle(.link).font(.caption).foregroundStyle(palette.accent)
                    .accessibilityIdentifier("commentActivity-" + comment.id)
            } else if comment.delivery != "local" {
                Text(comment.delivery.replacingOccurrences(of: "-", with: " ").capitalized)
                    .font(.caption2).foregroundStyle(palette.muted)
            }
            if comment.delivery == "needs-review" {
                Button("Retry delivery") {
                    model.perform {
                        try await model.mutate("retry_task_comment", ["id": comment.id])
                        await load()
                    }
                }.font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .surface()
    }

    private static func dateLabel(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)?.formatted(date: .abbreviated, time: .shortened) ?? value
    }

    private func load() async {
        do {
            let result: CommentsResponse = try await model.service.call("list_task_comments", ["taskId": item.id])
            if !Task.isCancelled { comments = result.comments.filter { $0.source == "user" } }
        } catch { if !Task.isCancelled { feedback = error.localizedDescription } }
    }

    private func draftChanged() {
        dirty = hasDraft || posting
        requestKey = UUID().uuidString
    }

    private func closeComposer() {
        composing = false
        commentFocused = false
        text = ""
        images = []
        dirty = false
        requestKey = UUID().uuidString
    }

    private func attach() {
        model.perform {
            let panel = NSOpenPanel()
            panel.title = "Attach screenshots to your revision request"
            panel.allowsMultipleSelection = true
            panel.allowedContentTypes = [.png, .jpeg, .webP]
            guard await panel.begin() == .OK else { return }
            guard panel.urls.count <= 3 - images.count else {
                throw attachmentFailure("Attach up to three screenshots per revision request.")
            }
            let files = panel.urls
            let prepared = try await Task.detached {
                try files.map { url -> DraftImage in
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 25 * 1024 * 1024 else {
                        throw attachmentFailure("Choose screenshots smaller than 25 MB.")
                    }
                    return try prepareImage(Data(contentsOf: url), name: url.lastPathComponent)
                }
            }.value
            guard prepared.count <= 3 - images.count else { return }
            images.append(contentsOf: prepared)
        }
    }

    private func paste() {
        do {
            let board = NSPasteboard.general
            guard let data = board.data(forType: .png) ?? board.data(forType: .tiff) else {
                throw attachmentFailure("Copy a screenshot to the clipboard first.")
            }
            images.append(try prepareImage(data, name: "Clipboard screenshot.png"))
        } catch { feedback = error.localizedDescription }
    }

    private func post() {
        guard !posting else { return }
        posting = true
        dirty = true
        let fields: [String: Any] = [
            "taskId": item.id, "text": text, "images": images.map(\.fields),
            "notifyAgent": assigned && model.canUseAgents, "requestKey": requestKey
        ]
        Task {
            defer { posting = false; dirty = hasDraft }
            do {
                try await model.mutate("add_user_comment", fields)
                closeComposer()
                feedback = assigned && item.status == .working ? "Revision request saved for the next agent check." : "Revision request saved for the next agent run."
                await load()
            } catch { feedback = error.localizedDescription }
        }
    }
}

private struct SavedScreenshot: View {
    @Environment(WorkspaceModel.self) private var model
    let image: CommentImage
    var open: (DraftImage) -> Void
    @State private var loaded: DraftImage?
    @State private var failed = false
    var body: some View {
        Button {
            if let loaded { open(loaded) }
        } label: {
            if let bitmap = loaded?.image {
                Image(nsImage: bitmap).resizable().scaledToFit().frame(width: 72, height: 48)
            } else {
                Image(systemName: failed ? "exclamationmark.triangle" : "photo").frame(width: 72, height: 48)
            }
        }
        .buttonStyle(.plain)
        .disabled(loaded == nil)
        .help(image.name)
        .accessibilityLabel("Enlarge \(image.name)")
        .task(id: image.id) {
            do { loaded = try await model.service.call("read_comment_image", ["imageId": image.id]) }
            catch { failed = true }
        }
    }
}

private func attachmentFailure(_ message: String) -> ServiceFailure {
    ServiceFailure(code: "IMAGE", message: message)
}

private func prepareImage(_ data: Data, name: String) throws -> DraftImage {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 5000,
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw attachmentFailure("Choose a PNG, JPEG, or WebP screenshot.")
    }
    let limit = 2 * 1024 * 1024
    let bitmap = NSBitmapImageRep(cgImage: image)
    var bytes = bitmap.representation(using: .png, properties: [:])
    var ext = "png"
    if (bytes?.count ?? Int.max) > limit {
        bytes = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        ext = "jpg"
    }
    guard let bytes, bytes.count <= limit else {
        throw attachmentFailure("This screenshot is too large. Crop it or choose a smaller image.")
    }
    let stem = String((name as NSString).deletingPathExtension.prefix(190))
    return DraftImage(name: "\(stem).\(ext)", mimeType: ext == "png" ? "image/png" : "image/jpeg",
                      data: bytes.base64EncodedString())
}
