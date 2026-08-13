import Foundation

public struct CalendarComponents: Codable, Hashable {
    public var minute: Int?
    public var hour: Int?
    public var day: Int?
    public var weekday: Int?
    public var month: Int?

    public init(
        minute: Int? = nil,
        hour: Int? = nil,
        day: Int? = nil,
        weekday: Int? = nil,
        month: Int? = nil
    ) {
        self.minute = minute
        self.hour = hour
        self.day = day
        self.weekday = weekday
        self.month = month
    }

    fileprivate var hasValidValues: Bool {
        if let minute = minute, !(0...59).contains(minute) {
            return false
        }
        if let hour = hour, !(0...23).contains(hour) {
            return false
        }
        if let day = day, !(1...31).contains(day) {
            return false
        }
        if let weekday = weekday, !(0...7).contains(weekday) {
            return false
        }
        if let month = month, !(1...12).contains(month) {
            return false
        }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case minute
        case hour
        case day
        case weekday
        case month
    }
}

public enum Schedule: Codable, Hashable {
    case cron(String)
    case calendar([CalendarComponents])
    case interval(TimeInterval)
    case atLoad
    case keepAlive
    case watchPaths([String])
    case queueDirectories([String])
    case onDemand

    public var humanDescription: String {
        switch self {
        case .cron(let expression):
            guard let cron = try? CronExpression(expression) else {
                let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "invalid cron schedule" : expression
            }
            return cron.humanDescription
        case .calendar(let entries):
            return Self.calendarDescription(entries)
        case .interval(let interval):
            return Self.intervalDescription(interval)
        case .atLoad:
            return "at load"
        case .keepAlive:
            return "kept alive"
        case .watchPaths(let paths):
            return Self.pathTriggerDescription(paths, condition: "changes", fallback: "when watched paths change")
        case .queueDirectories(let paths):
            return Self.pathTriggerDescription(
                paths,
                condition: "is not empty",
                fallback: "when queued directories are not empty"
            )
        case .onDemand:
            return "on demand"
        }
    }

    public func nextFire(after date: Date, calendar: Calendar) -> Date? {
        switch self {
        case .cron(let expression):
            return (try? CronExpression(expression))?.nextFire(after: date, calendar: calendar)
        case .calendar(let entries):
            return entries.compactMap {
                Self.nextCalendarFire(for: $0, after: date, calendar: calendar)
            }.min()
        case .interval, .atLoad, .keepAlive, .watchPaths, .queueDirectories, .onDemand:
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(Discriminator.self, forKey: .type)
        switch type {
        case .cron:
            self = .cron(try container.decode(String.self, forKey: .expression))
        case .calendar:
            self = .calendar(try container.decode([CalendarComponents].self, forKey: .entries))
        case .interval:
            self = .interval(try container.decode(TimeInterval.self, forKey: .seconds))
        case .atLoad:
            self = .atLoad
        case .keepAlive:
            self = .keepAlive
        case .watchPaths:
            self = .watchPaths(try container.decode([String].self, forKey: .paths))
        case .queueDirectories:
            self = .queueDirectories(try container.decode([String].self, forKey: .paths))
        case .onDemand:
            self = .onDemand
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cron(let expression):
            try container.encode(Discriminator.cron, forKey: .type)
            try container.encode(expression, forKey: .expression)
        case .calendar(let entries):
            try container.encode(Discriminator.calendar, forKey: .type)
            try container.encode(entries, forKey: .entries)
        case .interval(let seconds):
            try container.encode(Discriminator.interval, forKey: .type)
            try container.encode(seconds, forKey: .seconds)
        case .atLoad:
            try container.encode(Discriminator.atLoad, forKey: .type)
        case .keepAlive:
            try container.encode(Discriminator.keepAlive, forKey: .type)
        case .watchPaths(let paths):
            try container.encode(Discriminator.watchPaths, forKey: .type)
            try container.encode(paths, forKey: .paths)
        case .queueDirectories(let paths):
            try container.encode(Discriminator.queueDirectories, forKey: .type)
            try container.encode(paths, forKey: .paths)
        case .onDemand:
            try container.encode(Discriminator.onDemand, forKey: .type)
        }
    }

    private static func nextCalendarFire(
        for entry: CalendarComponents,
        after date: Date,
        calendar: Calendar
    ) -> Date? {
        guard
            entry.hasValidValues,
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
            let requestedWeekday = entry.weekday == 7 ? 0 : entry.weekday
            let dateMatches = (entry.month == nil || entry.month == candidateMonth)
                && (entry.day == nil || entry.day == candidateDay)
                && (requestedWeekday == nil || requestedWeekday == cronWeekday)

            if !dateMatches {
                guard let nextDay = calendar.date(
                    byAdding: .day,
                    value: 1,
                    to: calendar.startOfDay(for: candidate)
                ) else {
                    return nil
                }
                candidate = nextDay
                continue
            }

            let timeMatches = (entry.hour == nil || entry.hour == candidateHour)
                && (entry.minute == nil || entry.minute == candidateMinute)
            if timeMatches {
                return candidate
            }

            guard let nextMinute = calendar.date(byAdding: .minute, value: 1, to: candidate) else {
                return nil
            }
            candidate = nextMinute
        }
        return nil
    }

    private static func pathTriggerDescription(
        _ paths: [String],
        condition: String,
        fallback: String
    ) -> String {
        guard !paths.isEmpty else {
            return fallback
        }
        if paths.count == 1 {
            return "when \(paths[0]) \(condition)"
        }
        return "when any of \(paths.joined(separator: ", ")) \(condition)"
    }

    private static func calendarDescription(_ entries: [CalendarComponents]) -> String {
        guard !entries.isEmpty else {
            return "calendar schedule"
        }

        if entries.count > 1, let first = entries.first {
            let sameStructure = entries.dropFirst().allSatisfy {
                $0.day == first.day && $0.weekday == first.weekday && $0.month == first.month
            }
            let allHaveTimes = entries.allSatisfy { $0.hour != nil && $0.minute != nil }
            if sameStructure && allHaveTimes {
                if first.day == nil, first.weekday == nil, first.month == nil {
                    return "\(entries.count) times daily"
                }
                if first.day == nil, first.month == nil, let weekday = first.weekday {
                    return "\(entries.count) times on \(weekdayPlural(weekday))"
                }
                if first.weekday == nil, first.month == nil, first.day != nil {
                    return "\(entries.count) times monthly"
                }
                if first.weekday == nil, first.month != nil, first.day != nil {
                    return "\(entries.count) times yearly"
                }
            }
            return "\(entries.count) calendar times"
        }

        let entry = entries[0]
        guard entry.hasValidValues else {
            return "calendar schedule"
        }
        if let hour = entry.hour, let minute = entry.minute {
            let time = "\(twoDigits(hour)):\(twoDigits(minute))"
            if entry.day == nil, entry.weekday == nil, entry.month == nil {
                return "every day at \(time)"
            }
            if entry.day == nil, entry.month == nil, let weekday = entry.weekday {
                return "\(weekdayPlural(weekday)) at \(time)"
            }
            if entry.weekday == nil, entry.month == nil, let day = entry.day {
                return "monthly on day \(day) at \(time)"
            }
            if entry.weekday == nil,
                let month = entry.month,
                let day = entry.day,
                let monthName = monthName(month)
            {
                return "every \(monthName) \(day) at \(time)"
            }
        }
        return "calendar schedule"
    }

    private static func intervalDescription(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval > 0 else {
            return "interval schedule"
        }
        if interval.truncatingRemainder(dividingBy: 7 * 24 * 60 * 60) == 0 {
            return quantityDescription(interval / (7 * 24 * 60 * 60), unit: "week")
        }
        if interval.truncatingRemainder(dividingBy: 24 * 60 * 60) == 0 {
            return quantityDescription(interval / (24 * 60 * 60), unit: "day")
        }
        if interval.truncatingRemainder(dividingBy: 60 * 60) == 0 {
            return quantityDescription(interval / (60 * 60), unit: "hour")
        }
        if interval.truncatingRemainder(dividingBy: 60) == 0 {
            return quantityDescription(interval / 60, unit: "minute")
        }
        return quantityDescription(interval, unit: "second")
    }

    private static func quantityDescription(_ quantity: Double, unit: String) -> String {
        let rendered = String(format: "%.0f", quantity)
        return quantity == 1 ? "every \(unit)" : "every \(rendered) \(unit)s"
    }

    private static func twoDigits(_ value: Int) -> String {
        String(format: "%02d", value)
    }

    private static func weekdayPlural(_ weekday: Int) -> String {
        switch weekday == 7 ? 0 : weekday {
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
            return "scheduled days"
        }
    }

    private static func monthName(_ month: Int) -> String? {
        switch month {
        case 1:
            return "January"
        case 2:
            return "February"
        case 3:
            return "March"
        case 4:
            return "April"
        case 5:
            return "May"
        case 6:
            return "June"
        case 7:
            return "July"
        case 8:
            return "August"
        case 9:
            return "September"
        case 10:
            return "October"
        case 11:
            return "November"
        case 12:
            return "December"
        default:
            return nil
        }
    }

    private enum Discriminator: String, Codable {
        case cron
        case calendar
        case interval
        case atLoad
        case keepAlive
        case watchPaths
        case queueDirectories
        case onDemand
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case expression
        case entries
        case seconds
        case paths
    }
}
