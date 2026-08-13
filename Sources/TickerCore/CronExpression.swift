import Foundation

public enum CronExpressionError: Error, Equatable, LocalizedError {
    case invalidExpression(String)

    public var errorDescription: String? {
        switch self {
        case .invalidExpression(let reason):
            return "Invalid cron expression: \(reason)"
        }
    }
}

public struct CronExpression {
    public let rawExpression: String
    public let expandedExpression: String

    private let minute: CronField
    private let hour: CronField
    private let dayOfMonth: CronField
    private let month: CronField
    private let dayOfWeek: CronField

    public init(_ expression: String) throws {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CronExpressionError.invalidExpression("expression is empty")
        }

        let expanded = Self.shortcuts[trimmed.lowercased()] ?? trimmed
        let fields = expanded.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count == 5 else {
            throw CronExpressionError.invalidExpression("expected 5 fields, found \(fields.count)")
        }

        rawExpression = trimmed
        expandedExpression = fields.joined(separator: " ")
        minute = try CronField.parse(fields[0], range: 0...59, names: [:], canonicalize: { $0 })
        hour = try CronField.parse(fields[1], range: 0...23, names: [:], canonicalize: { $0 })
        dayOfMonth = try CronField.parse(fields[2], range: 1...31, names: [:], canonicalize: { $0 })
        month = try CronField.parse(
            fields[3],
            range: 1...12,
            names: Self.monthNames,
            canonicalize: { $0 }
        )
        dayOfWeek = try CronField.parse(
            fields[4],
            range: 0...7,
            names: Self.weekdayNames,
            canonicalize: { $0 == 7 ? 0 : $0 }
        )
    }

    public func nextFire(after date: Date, calendar: Calendar) -> Date? {
        guard
            let minuteStart = calendar.dateInterval(of: .minute, for: date)?.start,
            var candidate = calendar.date(byAdding: .minute, value: 1, to: minuteStart)
        else {
            return nil
        }

        let horizon = date.addingTimeInterval(4 * 366 * 24 * 60 * 60)
        while candidate <= horizon {
            let components = calendar.dateComponents(
                [.minute, .hour, .day, .month, .weekday],
                from: candidate
            )
            guard
                let candidateMinute = components.minute,
                let candidateHour = components.hour,
                let candidateDay = components.day,
                let candidateMonth = components.month,
                let foundationWeekday = components.weekday
            else {
                return nil
            }

            let cronWeekday = (foundationWeekday + 6) % 7
            if !month.values.contains(candidateMonth)
                || !matchesDay(day: candidateDay, weekday: cronWeekday)
            {
                guard let nextDay = Self.startOfNextDay(after: candidate, calendar: calendar) else {
                    return nil
                }
                candidate = nextDay
                continue
            }

            if hour.values.contains(candidateHour) && minute.values.contains(candidateMinute) {
                return candidate
            }

            guard let nextMinute = calendar.date(byAdding: .minute, value: 1, to: candidate) else {
                return nil
            }
            candidate = nextMinute
        }
        return nil
    }

    public var humanDescription: String {
        let dayDescription = commonDayDescription

        if let step = minute.starStep, step > 1, let dayDescription = dayDescription {
            var parts = ["every \(step) minutes"]
            if let hourWindow = hourWindowDescription {
                parts.append(hourWindow)
            }
            if dayDescription != "every day" {
                parts.append(dayDescription)
            }
            return parts.joined(separator: ", ")
        }

        if minute.values.count == 1,
            hour.values.count == 1,
            let minuteValue = minute.values.first,
            let hourValue = hour.values.first,
            let dayDescription = dayDescription
        {
            return "\(dayDescription) at \(Self.twoDigits(hourValue)):\(Self.twoDigits(minuteValue))"
        }

        return rawExpression.isEmpty ? "cron schedule" : rawExpression
    }

    private func matchesDay(day: Int, weekday: Int) -> Bool {
        let dayOfMonthMatches = dayOfMonth.values.contains(day)
        let dayOfWeekMatches = dayOfWeek.values.contains(weekday)

        if !dayOfMonth.isWildcard && !dayOfWeek.isWildcard {
            return dayOfMonthMatches || dayOfWeekMatches
        }
        if !dayOfMonth.isWildcard {
            return dayOfMonthMatches
        }
        if !dayOfWeek.isWildcard {
            return dayOfWeekMatches
        }
        return true
    }

    private var commonDayDescription: String? {
        guard dayOfMonth.isWildcard, month.isWildcard else {
            return nil
        }
        if dayOfWeek.isWildcard {
            return "every day"
        }
        if dayOfWeek.values == Set(1...5) {
            return "weekdays"
        }
        if dayOfWeek.values == Set([0, 6]) {
            return "weekends"
        }
        if dayOfWeek.values.count == 1, let value = dayOfWeek.values.first {
            return Self.weekdayPlural(value)
        }
        return nil
    }

    private var hourWindowDescription: String? {
        if hour.isWildcard {
            return nil
        }
        if let bounds = hour.simpleRange {
            return "\(Self.twoDigits(bounds.lowerBound)):00-\(Self.twoDigits(bounds.upperBound)):59"
        }
        if hour.values.count == 1, let value = hour.values.first {
            return "\(Self.twoDigits(value)):00-\(Self.twoDigits(value)):59"
        }
        return nil
    }

    private static func startOfNextDay(after date: Date, calendar: Calendar) -> Date? {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
    }

    private static func twoDigits(_ value: Int) -> String {
        String(format: "%02d", value)
    }

    private static func weekdayPlural(_ value: Int) -> String? {
        switch value {
        case 0:
            return "Sundays"
        case 1:
            return "Mondays"
        case 2:
            return "Tuesdays"
        case 3:
            return "Wednesdays"
        case 4:
            return "Thursdays"
        case 5:
            return "Fridays"
        case 6:
            return "Saturdays"
        default:
            return nil
        }
    }

    private static let shortcuts: [String: String] = [
        "@yearly": "0 0 1 1 *",
        "@annually": "0 0 1 1 *",
        "@monthly": "0 0 1 * *",
        "@weekly": "0 0 * * 0",
        "@daily": "0 0 * * *",
        "@midnight": "0 0 * * *",
        "@hourly": "0 * * * *",
    ]

    private static let monthNames: [String: Int] = [
        "JAN": 1, "FEB": 2, "MAR": 3, "APR": 4,
        "MAY": 5, "JUN": 6, "JUL": 7, "AUG": 8,
        "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12,
    ]

    private static let weekdayNames: [String: Int] = [
        "SUN": 0, "MON": 1, "TUE": 2, "WED": 3,
        "THU": 4, "FRI": 5, "SAT": 6,
    ]
}

private struct CronField {
    let values: Set<Int>
    let isWildcard: Bool
    let source: String

    var starStep: Int? {
        let parts = source.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "*" else {
            return nil
        }
        return Int(parts[1])
    }

    var simpleRange: ClosedRange<Int>? {
        guard !source.contains(","), !source.contains("/") else {
            return nil
        }
        let parts = source.split(separator: "-", omittingEmptySubsequences: false)
        guard
            parts.count == 2,
            let lower = Int(parts[0]),
            let upper = Int(parts[1]),
            lower <= upper
        else {
            return nil
        }
        return lower...upper
    }

    static func parse(
        _ source: String,
        range: ClosedRange<Int>,
        names: [String: Int],
        canonicalize: (Int) -> Int
    ) throws -> CronField {
        let normalized = source.uppercased()
        guard !normalized.isEmpty else {
            throw CronExpressionError.invalidExpression("a field is empty")
        }

        var values = Set<Int>()
        let listParts = normalized.split(separator: ",", omittingEmptySubsequences: false)
        for listPartSlice in listParts {
            let listPart = String(listPartSlice)
            guard !listPart.isEmpty else {
                throw CronExpressionError.invalidExpression("empty list item in '\(source)'")
            }

            let stepParts = listPart.split(separator: "/", omittingEmptySubsequences: false)
            guard stepParts.count <= 2 else {
                throw CronExpressionError.invalidExpression("too many '/' separators in '\(source)'")
            }

            let base = String(stepParts[0])
            let step: Int
            if stepParts.count == 2 {
                guard let parsedStep = Int(stepParts[1]), parsedStep > 0 else {
                    throw CronExpressionError.invalidExpression("invalid step in '\(source)'")
                }
                step = parsedStep
            } else {
                step = 1
            }

            let bounds: ClosedRange<Int>
            if base == "*" {
                bounds = range
            } else {
                let rangeParts = base.split(separator: "-", omittingEmptySubsequences: false)
                if rangeParts.count == 2 {
                    let lower = try parseValue(String(rangeParts[0]), names: names, range: range)
                    let upper = try parseValue(String(rangeParts[1]), names: names, range: range)
                    guard lower <= upper else {
                        throw CronExpressionError.invalidExpression("descending range in '\(source)'")
                    }
                    bounds = lower...upper
                } else if rangeParts.count == 1, stepParts.count == 1 {
                    let value = try parseValue(base, names: names, range: range)
                    bounds = value...value
                } else {
                    throw CronExpressionError.invalidExpression("invalid range in '\(source)'")
                }
            }

            var value = bounds.lowerBound
            while value <= bounds.upperBound {
                values.insert(canonicalize(value))
                if value > bounds.upperBound - step {
                    break
                }
                value += step
            }
        }

        guard !values.isEmpty else {
            throw CronExpressionError.invalidExpression("field '\(source)' has no values")
        }
        return CronField(values: values, isWildcard: normalized == "*", source: normalized)
    }

    private static func parseValue(
        _ source: String,
        names: [String: Int],
        range: ClosedRange<Int>
    ) throws -> Int {
        let value = names[source] ?? Int(source)
        guard let value = value, range.contains(value) else {
            throw CronExpressionError.invalidExpression("value '\(source)' is out of range")
        }
        return value
    }
}
