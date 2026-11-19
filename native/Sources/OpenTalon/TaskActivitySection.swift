import AppKit
import CompanionCore
import SwiftUI

struct TaskActivitySection: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var page: TaskActivityPage?
    @State private var showing = false
    @State private var attachment: DraftImage?
    @State private var error: String?
    let taskID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity").font(.headline)
            if let page {
                TaskActivitySummary(page: page, colors: OpenTalonColors(theme: palette.theme)) { showing = true }
            } else { ProgressView("Loading activity…") }
            if let error { Text(error).font(.caption).foregroundStyle(palette.danger) }
        }
        .task(id: model.workspace?.revision) {
            do { try await load(nil) } catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented: $showing) {
            TaskActivityView(page: page, colors: OpenTalonColors(theme: palette.theme), load: load) { image in
                Task {
                    do { attachment = try await model.service.call("read_comment_image", ["imageId": image.id]) }
                    catch { self.error = error.localizedDescription }
                }
            }
            .frame(minWidth: 600, minHeight: 650)
            .sheet(item: $attachment) { image in
                VStack(alignment: .trailing, spacing: 16) {
                    HStack { Text(image.name).lineLimit(1); Spacer(); Button("Close") { attachment = nil } }
                    if let bitmap = image.image { Image(nsImage: bitmap).resizable().scaledToFit().frame(maxHeight: 520) }
                }.padding(20).frame(width: 680)
            }
        }
    }
    private func load(_ before: Int?) async throws {
        var input: [String: Any] = ["taskId": taskID, "limit": 20]
        input["beforeSequence"] = before
        let result: TaskActivityPage = try await model.service.call("list_task_activity", input)
        if before == nil { page = page.map { result.keepingOlder(from: $0) } ?? result }
        else { page = page?.merging(result) ?? result }
    }
}
