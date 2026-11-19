import SwiftUI
import UniformTypeIdentifiers

public struct MarkdownPlanFile: FileDocument {
    public static var readableContentTypes: [UTType] { [UTType(filenameExtension: "md") ?? .plainText, .plainText] }
    public var markdown: String
    public init(_ markdown: String) { self.markdown = markdown }
    public init(configuration: ReadConfiguration) throws {
        markdown = try TaskPlan.decode(configuration.file.regularFileContents ?? Data())
    }
    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try TaskPlan.validate(markdown)
        return FileWrapper(regularFileWithContents: Data(markdown.utf8))
    }
}

public struct MarkdownPlanPreview: View {
    public let markdown: String
    public init(_ markdown: String) { self.markdown = markdown }

    public var body: some View {
        let blocks = Self.blocks(markdown)
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.code {
                    Text(block.text).font(.system(.body, design: .monospaced))
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                } else if block.text.hasPrefix("### ") {
                    Text(String(block.text.dropFirst(4))).font(.headline)
                } else if block.text.hasPrefix("## ") {
                    Text(String(block.text.dropFirst(3))).font(.title3.bold())
                } else if block.text.hasPrefix("# ") {
                    Text(String(block.text.dropFirst(2))).font(.title2.bold())
                } else if block.text.hasPrefix("- [ ] ") || block.text.lowercased().hasPrefix("- [x] ") {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: block.text.lowercased().hasPrefix("- [x]") ? "checkmark.square" : "square")
                        inline(String(block.text.dropFirst(6)))
                    }
                } else if block.text.hasPrefix("- ") || block.text.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 8) { Text("•"); inline(String(block.text.dropFirst(2))) }
                } else {
                    inline(block.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> Text {
        // Text renders Markdown text only; it never executes HTML or fetches remote images.
        if let attributed = try? AttributedString(markdown: text,
                                                 options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }

    private struct Block { var text: String; var code: Bool }
    private static func blocks(_ markdown: String) -> [Block] {
        var result = [Block]()
        var code: [String]?
        var fence: PlanCodeFence?
        for line in markdown.components(separatedBy: .newlines) {
            if let active = fence {
                if active.closes(with: line) {
                    result.append(Block(text: (code ?? []).joined(separator: "\n"), code: true))
                    code = nil; fence = nil
                } else { code?.append(line) }
            } else if let opening = PlanCodeFence(line) { fence = opening; code = [] }
            else if !line.trimmingCharacters(in: .whitespaces).isEmpty { result.append(Block(text: line, code: false)) }
        }
        if let code { result.append(Block(text: code.joined(separator: "\n"), code: true)) }
        return result
    }
}

public struct PlanDocumentView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var mode = 0
    @State private var instruction = ""
    @State private var candidate: String?
    @State private var beforeAI: String?
    @State private var generation: Task<Void, Never>?
    @State private var saving = false
    @State private var error: String?
    @State private var importing = false
    @State private var exporting = false
    @State private var inputFrames = [String: CGRect]()
    @State private var persistence: Task<Void, Never>?
    @State private var closedIntentionally = false
    @FocusState private var focusedInput: String?
    let original: String
    let reference: String
    let context: String
    let colors: OpenTalonColors
    let save: @MainActor (String) async throws -> Void
    let persistDraft: @MainActor (String?) -> Void

    public init(markdown: String, draft: String? = nil, proposal: String? = nil, reference: String, context: String,
                colors: OpenTalonColors, save: @escaping @MainActor (String) async throws -> Void,
                persistDraft: @escaping @MainActor (String?) -> Void = { _ in }) {
        original = markdown
        _draft = State(initialValue: draft ?? markdown)
        _candidate = State(initialValue: proposal)
        self.reference = reference
        self.context = context
        self.colors = colors
        self.save = save
        self.persistDraft = persistDraft
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(TaskPlan.filename(reference: reference)).font(.headline).lineLimit(1)
                Spacer()
                Button(draft == original ? "Close" : "Cancel") {
                    generation?.cancel()
                    persistence?.cancel()
                    closedIntentionally = true
                    persistDraft(nil)
                    dismiss()
                }
                .accessibilityIdentifier("planCancel")
            }
            .padding(20)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { focusedInput = nil })
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PlanViewTabs(selection: $mode, colors: colors)
                        .frame(maxWidth: 360)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let candidate {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Suggested revision").font(.headline)
                            Text("Your saved plan is unchanged.").font(.caption).foregroundStyle(colors.muted)
                            MarkdownPlanPreview(candidate)
                            HStack {
                                Spacer()
                                Button("Discard") { self.candidate = nil }
                                Button("Apply to draft") {
                                    beforeAI = draft
                                    draft = candidate
                                    self.candidate = nil
                                }
                                .accessibilityIdentifier("planApplyRevision")
                            }
                        }
                        .padding(16).background(colors.card, in: RoundedRectangle(cornerRadius: 18))
                    }
                    if mode == 1 {
                        TextEditor(text: $draft)
                            .modifier(PlanWritingTools())
                            .focused($focusedInput, equals: "source")
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(12).frame(height: 360)
                            .background(colors.card, in: RoundedRectangle(cornerRadius: 18))
                            .accessibilityIdentifier("planMarkdownEditor")
                            .background { inputGeometry("source") }
                    } else if draft.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("No plan yet").font(.title3.bold())
                            Text("Write a plan in Markdown, import a file, or ask Apple Intelligence to draft one.")
                                .foregroundStyle(colors.muted)
                            Button("Start writing") { mode = 1 }
                        }
                    } else {
                        MarkdownPlanPreview(draft)
                            .padding(16).background(colors.card, in: RoundedRectangle(cornerRadius: 18))
                    }
                    HStack {
                        Button("Import Markdown") { importing = true }
                        Button("Export Markdown") { exporting = true }.disabled(draft.isEmpty)
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Apple Intelligence", systemImage: "sparkles").font(.headline)
                        if let reason = TaskDrafting.unavailableReason {
                            Text(reason).font(.footnote).foregroundStyle(colors.muted)
                        } else {
                            TextField("How should the plan change?", text: $instruction, axis: .vertical)
                                .focused($focusedInput, equals: "instruction")
                                .lineLimit(2...4).textFieldStyle(.plain).padding(12)
                                .background(colors.card, in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityIdentifier("planAIInstruction")
                                .background { inputGeometry("instruction") }
                            if generation != nil {
                                HStack { ProgressView("Editing on this device…"); Spacer(); Button("Stop") { generation?.cancel() } }
                            } else {
                                ViewThatFits {
                                    HStack { aiButtons }
                                    VStack(alignment: .leading) { aiButtons }
                                }
                            }
                        }
                        if let beforeAI {
                            Button("Undo AI edit") { draft = beforeAI; self.beforeAI = nil; candidate = nil }
                        }
                    }
                    if let error { Text(error).foregroundStyle(colors.danger).font(.footnote) }
                    HStack {
                        Spacer()
                        Button(saving ? "Saving…" : "Save") {
                            saving = true
                            Task {
                                defer { saving = false }
                                do {
                                    try TaskPlan.validate(draft)
                                    try await save(draft)
                                    persistence?.cancel()
                                    closedIntentionally = true
                                    persistDraft(nil)
                                    dismiss()
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                        .disabled(saving || generation != nil || candidate != nil || draft == original)
                        .accessibilityIdentifier("planSave")
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
            .coordinateSpace(name: "planEditor")
            .scrollDismissesKeyboard(.interactively)
            .onPreferenceChange(PlanInputFrames.self) { inputFrames = $0 }
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("planEditor")).onEnded { tap in
                if !inputFrames.values.contains(where: { $0.contains(tap.location) }) { focusedInput = nil }
            })
        }
        .foregroundStyle(colors.text)
        .background(colors.canvas.ignoresSafeArea())
        .buttonStyle(PlanButtonStyle(colors: colors))
        .onChange(of: draft) { _, value in
            persistence?.cancel()
            persistence = Task {
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                persistDraft(value == original ? nil : value)
            }
        }
        .onDisappear {
            generation?.cancel()
            persistence?.cancel()
            if !closedIntentionally { persistDraft(draft == original ? nil : draft) }
        }
        .interactiveDismissDisabled(saving)
        .fileImporter(isPresented: $importing, allowedContentTypes: MarkdownPlanFile.readableContentTypes) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                draft = try TaskPlan.decode(Data(contentsOf: url))
                candidate = nil
            } catch { self.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: MarkdownPlanFile(draft),
                      contentType: UTType(filenameExtension: "md") ?? .plainText,
                      defaultFilename: TaskPlan.filename(reference: reference)) { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
    }

    @ViewBuilder private var aiButtons: some View {
        Button("Proofread") { revise("Proofread this plan. Preserve its meaning, facts and Markdown structure.") }
            .disabled(draft.isEmpty)
        Button(draft.isEmpty ? "Draft plan" : "Revise plan") {
            revise(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                   ? "Draft an actionable Markdown plan with steps and verification checks." : instruction)
        }
    }

    private func inputGeometry(_ key: String) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: PlanInputFrames.self, value: [key: geometry.frame(in: .named("planEditor"))])
        }
    }

    private func revise(_ instruction: String) {
        error = nil
        let originalDraft = draft
        generation = Task {
            defer { generation = nil }
            do {
                let result = try await TaskPlan.revise(originalDraft, instruction: instruction, context: context)
                try Task.checkCancellation()
                guard draft == originalDraft else {
                    error = "You edited the plan while AI was working. Run the revision again to use your latest text."
                    return
                }
                candidate = result
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct PlanInputFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct PlanButtonStyle: ButtonStyle {
    let colors: OpenTalonColors
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.callout.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(colors.card.opacity(configuration.isPressed ? 0.65 : 1), in: Capsule())
            .overlay { Capsule().strokeBorder(colors.line, lineWidth: 1) }
            .opacity(enabled ? 1 : 0.45)
    }
}

private struct PlanWritingTools: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) { content.writingToolsBehavior(.complete) }
        else { content }
    }
}


private struct PlanViewTabs: View {
    @Binding var selection: Int
    let colors: OpenTalonColors
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            tab("Preview", symbol: "doc.richtext", value: 0)
            tab("Markdown", symbol: "chevron.left.forwardslash.chevron.right", value: 1)
        }
        .padding(4)
        .background(colors.text.opacity(0.05), in: Capsule())
        .overlay { Capsule().strokeBorder(colors.line.opacity(0.7), lineWidth: 1) }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Plan view")
        .accessibilityIdentifier("planDisplayMode")
    }

    private func tab(_ title: String, symbol: String, value: Int) -> some View {
        let selected = selection == value
        return Button { selection = value } label: {
            Label(title, systemImage: symbol)
                .font(.body.weight(selected ? .semibold : .medium))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(selected ? colors.actionAccent : colors.text)
                .background {
                    if selected {
                        Capsule().fill(colors.card)
                            .overlay { Capsule().strokeBorder(colors.actionAccent.opacity(0.5), lineWidth: 1) }
                            .shadow(color: .black.opacity(0.08), radius: 3, y: 2)
                            .matchedGeometryEffect(id: "planSelectedTab", in: highlight)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(value == 0 ? "planPreviewTab" : "planMarkdownTab")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
