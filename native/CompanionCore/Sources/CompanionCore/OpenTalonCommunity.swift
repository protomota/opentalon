import Foundation
import Observation

public enum OpenTalonCommunity {
    public static let newsletter = URL(string: "https://newsletter.protomota.com/")!
    public static let websiteTip = URL(string: "https://buymeacoffee.com/protomotalab")!
    public static let website = URL(string: "https://opentalon.ai/")!
    public static let websiteHelp = website.appendingPathComponent("help")
    public static let support = URL(string: "https://protomota.com/support?app=opentalon")!
    public static let feedback = URL(string: "https://protomota.com/apps?app=opentalon#feedback")!
    public static let appStoreReview = URL(string: "https://apps.apple.com/app/id6833695057?action=write-review")!
    public static let protomota = URL(string: "https://protomota.com/")!
    public static let protomotaApps = URL(string: "https://protomota.com/apps")!
}

@MainActor
@Observable
public final class OpenTalonReviewMilestone {
    private static let activityKey = "OpenTalon.reviewActivityCount"
    private static let requestedKey = "OpenTalon.reviewRequested"
    private let defaults: UserDefaults?
    private var activityCount: Int
    private var requested: Bool

    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        activityCount = defaults?.integer(forKey: Self.activityKey) ?? 0
        requested = defaults?.bool(forKey: Self.requestedKey) ?? false
    }

    public var isDue: Bool { activityCount >= 3 && !requested }

    public func recordActivity() {
        guard !requested, activityCount < 3 else { return }
        activityCount += 1
        defaults?.set(activityCount, forKey: Self.activityKey)
    }

    @discardableResult
    public func takeRequest() -> Bool {
        guard isDue else { return false }
        requested = true
        defaults?.set(true, forKey: Self.requestedKey)
        return true
    }
}
