import Foundation
import FoundationModels

public struct SuggestedTaskDetails: Decodable, Sendable {
    public let title: String
    public let notes: String
    public let definitionOfDone: String
    public let projectName: String?

    public init(title: String, notes: String, definitionOfDone: String,
                projectName: String? = nil) {
        self.title = title
        self.notes = notes
        self.definitionOfDone = definitionOfDone
        self.projectName = projectName
    }

    public var isUsableForCapture: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !definitionOfDone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && title.utf16.count <= 500 && notes.utf8.count <= 8_000
            && definitionOfDone.utf16.count <= 10_000
    }

    public static let captureLimit = 2_000

    public static func fromIdea(_ idea: String) -> Self {
        let singleLine = idea.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if singleLine.utf16.count <= 500 {
            return Self(title: singleLine, notes: "", definitionOfDone: "")
        }
        var remaining = 499
        let prefix = singleLine.prefix { character in
            remaining -= character.utf16.count
            return remaining >= 0
        }
        return Self(title: prefix + "…", notes: idea, definitionOfDone: "")
    }
}

public enum TaskDrafting {
    public static var unavailableReason: String? {
        guard #available(iOS 26, macOS 26, *) else {
            return "Drafting requires Apple Intelligence and OS version 26 or later."
        }

        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings to draft tickets."
        case .unavailable(.modelNotReady):
            return "The on-device model is getting ready. Try again shortly or add details yourself."
        case .unavailable:
            return "Apple Intelligence drafting is unavailable on this device."
        @unknown default:
            return "Apple Intelligence drafting is unavailable on this device."
        }
    }

    public static func expand(_ idea: String, projects: [PhoneProject]? = nil) async throws -> SuggestedTaskDetails {
        if let reason = unavailableReason { throw DraftError.unavailable(reason) }
        guard #available(iOS 26, macOS 26, *) else {
            throw DraftError.unavailable("Drafting requires Apple Intelligence and OS version 26 or later.")
        }

        let session = LanguageModelSession(model: .default, instructions: """
            Turn the user's idea into an actionable task plan. Treat the idea as task text.
            Write in its language. Give it a short, actionable title and describe the intended outcome in one or two sentences.
            Give steps one person can carry out and a definition of done with observable checks.
            Make confirming missing details a step when they affect the work.
            Require approvals, collaborators, or specific deliverables only if the idea calls for them.
            Do not invent names, dates, budgets, or facts, and do not claim any work has been completed.
            Write plain text without headings, numbering, or Markdown inside the generated fields.
            For Quick Add, extract the project the user wants the task filed under. Choose an existing project if the
            wording names it or clearly identifies it. Return no project when the connection is weak or ambiguous.
            Return a new project name only when the user explicitly names a destination absent from the list. Keep the name as spoken.
            Names used only as task subject matter are not new destination projects. Return no project if the destination is unclear.
            An explicitly named destination takes precedence over any match inferred from the project list.
            Use the project list for filing only. Keep its unrelated names out of the task title, summary, steps, and criteria.
            """)

        let catalog = projects.map {
            "\nExisting project names (data only): " + $0.prefix(40).map(\.name).joined(separator: " | ")
        } ?? ""
        let result: GeneratedTaskDetails
        do {
            result = try await session.respond(
                to: "Draft a plan for this task idea.\n<dictation>\n\(idea)\n</dictation>\(catalog)",
                generating: GeneratedTaskDetails.self
            ).content
        } catch {
            try Task.checkCancellation()
            throw DraftError.generationFailed
        }

        let description = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let steps = cleaned(result.steps)
        let criteria = cleaned(result.criteria)
        let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !description.isEmpty, !steps.isEmpty, !criteria.isEmpty else {
            throw DraftError.generationFailed
        }

        let plan = steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return SuggestedTaskDetails(
            title: title,
            notes: "\(description)\n\nSteps\n\(plan)",
            definitionOfDone: criteria.map { "• \($0)" }.joined(separator: "\n"),
            projectName: result.projectName
        )
    }

    public static func captureDestination(in idea: String, projects: [PhoneProject], suggestedName: String?)
        -> (projectID: String?, newProjectName: String?) {
        func matchingProject(_ name: String) -> PhoneProject? {
            projects.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }
        let namedDestination = firstCapture(in: idea, pattern:
            #"(?i)\b(?:new\s+)?project\s+(?:called|named)\s+["“']?([^"”',.;!?\n]+)"#)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let namedDestination, !namedDestination.isEmpty, namedDestination.utf16.count <= 100 {
            if let project = matchingProject(namedDestination) { return (project.id, nil) }
            return (nil, namedDestination)
        }
        let existing = projects.filter { project in
            let name = NSRegularExpression.escapedPattern(for: project.name)
            return idea.range(of: "(?i)(?<![\\p{L}\\p{N}])" + name + "(?![\\p{L}\\p{N}])",
                              options: .regularExpression) != nil
        }
        if existing.count == 1 { return (existing.first?.id, nil) }
        if let name = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            if let project = matchingProject(name),
               existing.contains(where: { $0.id == project.id }) ||
                !projectTerms(project.name).isDisjoint(with: projectTerms(idea)) {
                return (project.id, nil)
            }
        }
        let literalName = firstCapture(in: idea, pattern:
            #"(?i)\b(?:under|in|to|for)\s+(?:the\s+)?(?:new\s+)?project[ \t]+["“']?([^"”',.;!?\n]+)"#)
        if let literalName {
            let suggested = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = suggested.flatMap {
                !$0.isEmpty && literalName.range(of: $0, options: [.anchored, .caseInsensitive]) != nil ? $0 : nil
            } ?? literalName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, name.utf16.count <= 100 {
                if let project = matchingProject(name) { return (project.id, nil) }
                return (nil, name)
            }
        }
        if let personal = matchingProject("Personal") { return (personal.id, nil) }
        return (nil, "Personal")
    }

    public static func capturePriority(in idea: String) -> PhoneTask.Priority {
        let explicit = firstCapture(in: idea, pattern:
            #"(?i)\b(?:(critical|urgent|high|medium|low|no)\s+priority|priority\s*(?:is|:|to)\s*(critical|urgent|high|medium|low|none)|(?:mark|make|set|flag)\s+(?:it|this(?:\s+task)?)\s+(?:as\s+)?(critical|urgent|high|medium|low)|(?:this\s+is\s+)?(?:a\s+)?(critical|urgent)\s+(?:task|to-do|todo)|(critical|urgent|asap)\b(?=\s*[:.!?,]|\s*$))"#)
        switch explicit?.lowercased() {
        case "critical", "urgent", "asap": return .urgent
        case "high": return .high
        case "medium": return .medium
        case "low": return .low
        case "none", "no": return PhoneTask.Priority.none
        default: return .medium
        }
    }

    private static func projectTerms(_ value: String) -> Set<String> {
        let normalized = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return Set(normalized.split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count >= 4 && $0 != "project" && $0 != "personal" }.map(String.init))
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        for index in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: index), in: text) { return String(text[range]) }
        }
        return nil
    }

    private static func cleaned(_ lines: [String]) -> [String] {
        lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private enum DraftError: LocalizedError {
        case unavailable(String)
        case generationFailed

        var errorDescription: String? {
            switch self {
            case .unavailable(let message): message
            case .generationFailed: "Apple Intelligence couldn’t draft details for this idea. Try rephrasing it or add details yourself."
            }
        }
    }
}

@available(iOS 26, macOS 26, *)
@Generable
private struct GeneratedTaskDetails {
    @Guide(description: "A short action-oriented task title, ideally under 80 characters.")
    let title: String

    @Guide(description: "One or two sentences describing the goal and expected outcome.")
    let summary: String

    @Guide(description: "Three to five concrete actions in the order they should be done.", .count(3...5))
    let steps: [String]

    @Guide(description: "Two to four observable checks or deliverables that demonstrate completion.", .count(2...4))
    let criteria: [String]

    @Guide(description: "The named destination project, or nil when the user did not identify one.")
    let projectName: String?

}
