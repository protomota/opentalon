import Foundation

public enum CalendarDay {
    public static var today: String { key(.now) }

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    public static func key(_ date: Date) -> String { formatter().string(from: date) }
    public static func date(_ key: String) -> Date? { formatter().date(from: key) }

    public static func label(_ key: String) -> String {
        if key == today { return "Today" }
        guard let date = date(key) else { return key }
        if key.prefix(4) != today.prefix(4) {
            return date.formatted(.dateTime.month(.abbreviated).day().year())
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
