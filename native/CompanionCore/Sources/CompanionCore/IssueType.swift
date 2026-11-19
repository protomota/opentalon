import SwiftUI

public enum IssueType: String, CaseIterable, Codable, Identifiable, Sendable {
    case issue = "Issue", bug = "Bug"

    public var id: Self { self }
    public var symbol: String { self == .bug ? "ladybug" : "circle.dashed" }

    public static func inferred(from text: String) -> Self {
        let pattern = #"(?i)(?:^\s*bug\s*[:\-]|\b(?:create|add|file|report|log|fix|new)\s+(?:(?:a|the|this|an|critical|urgent|high\s+priority)\s+)*bug\b|\bbug\s+(?:report|ticket)\b)"#
        return text.range(of: pattern, options: .regularExpression) == nil ? .issue : .bug
    }
}

public struct IssueTypeBadge: View {
    public let type: IssueType
    public let tint: Color

    public init(_ type: IssueType, tint: Color) { self.type = type; self.tint = tint }

    public var body: some View {
        Label(type.rawValue, systemImage: type.symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(tint)
            .background(tint.opacity(0.11), in: Capsule())
            .accessibilityLabel("Issue type: " + type.rawValue)
    }
}
