import Foundation

// MARK: - Cron expressions

/// A five-field cron expression: minute, hour, day of month, month, day of
/// week. Supports `*`, lists (`1,15`), ranges (`1-5`), steps (`*/15`,
/// `0-30/10`), month and weekday names (`jan`, `mon`), and the shortcuts
/// `@hourly`, `@daily`, `@weekly`, `@monthly` and `@yearly`.
public struct CronSchedule: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public let expression: String
    let minutes: Set<Int>
    let hours: Set<Int>
    let daysOfMonth: Set<Int>
    let months: Set<Int>
    /// 0 = Sunday … 6 = Saturday.
    let weekdays: Set<Int>
    let dayOfMonthRestricted: Bool
    let weekdayRestricted: Bool

    public var description: String { expression }

    public enum ParseError: Error, LocalizedError, Equatable {
        case fieldCount(Int)
        case invalid(field: String, value: String)

        public var errorDescription: String? {
            switch self {
            case .fieldCount(let count):
                return "A cron schedule needs 5 fields (minute hour day month weekday), not \(count)."
            case .invalid(let field, let value):
                return "“\(value)” isn't a valid \(field)."
            }
        }
    }

    public init(_ expression: String) throws {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded: String
        switch trimmed.lowercased() {
        case "@hourly": expanded = "0 * * * *"
        case "@daily", "@midnight": expanded = "0 0 * * *"
        case "@weekly": expanded = "0 0 * * 0"
        case "@monthly": expanded = "0 0 1 * *"
        case "@yearly", "@annually": expanded = "0 0 1 1 *"
        default: expanded = trimmed
        }
        let fields = expanded.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else { throw ParseError.fieldCount(fields.count) }
        self.expression = trimmed
        minutes = try Self.parse(fields[0], name: "minute", range: 0...59)
        hours = try Self.parse(fields[1], name: "hour", range: 0...23)
        daysOfMonth = try Self.parse(fields[2], name: "day of month", range: 1...31)
        months = try Self.parse(fields[3], name: "month", range: 1...12, names: Self.monthNames)
        var weekdays = try Self.parse(fields[4], name: "weekday", range: 0...7, names: Self.weekdayNames)
        if weekdays.remove(7) != nil { weekdays.insert(0) }
        self.weekdays = weekdays
        dayOfMonthRestricted = fields[2] != "*" && fields[2] != "?"
        weekdayRestricted = fields[4] != "*" && fields[4] != "?"
    }

    public static func isValid(_ expression: String) -> Bool {
        (try? CronSchedule(expression)) != nil
    }

    // Codable as its expression string.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(expression)
    }

    static let monthNames = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
    static let weekdayNames = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]

    private static func parse(_ field: String, name: String, range: ClosedRange<Int>, names: [String: Int] = [:]) throws -> Set<Int> {
        func value(_ token: String) throws -> Int {
            if let number = Int(token), range.contains(number) { return number }
            if let named = names[token.lowercased()] { return named }
            throw ParseError.invalid(field: name, value: field)
        }
        var result = Set<Int>()
        for part in field.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            guard !part.isEmpty else { throw ParseError.invalid(field: name, value: field) }
            var base = part
            var step = 1
            if let slash = part.firstIndex(of: "/") {
                base = String(part[..<slash])
                guard let parsed = Int(part[part.index(after: slash)...]), parsed > 0 else {
                    throw ParseError.invalid(field: name, value: field)
                }
                step = parsed
            }
            let lower: Int
            let upper: Int
            if base == "*" || base == "?" {
                lower = range.lowerBound
                upper = range.upperBound
            } else if let dash = base.firstIndex(of: "-") {
                lower = try value(String(base[..<dash]))
                upper = try value(String(base[base.index(after: dash)...]))
                guard lower <= upper else { throw ParseError.invalid(field: name, value: field) }
            } else {
                lower = try value(base)
                // "5/15" means every 15 starting at 5.
                upper = part.contains("/") ? range.upperBound : lower
            }
            result.formUnion(stride(from: lower, through: upper, by: step))
        }
        return result
    }

    /// True when the schedule fires at this minute.
    public func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        guard let minute = c.minute, let hour = c.hour else { return false }
        return minutes.contains(minute) && hours.contains(hour) && dayMatches(c, calendar: calendar)
    }

    private func dayMatches(_ c: DateComponents, calendar: Calendar) -> Bool {
        guard let day = c.day, let month = c.month, let weekday = c.weekday else { return false }
        guard months.contains(month) else { return false }
        let domOK = daysOfMonth.contains(day)
        let dowOK = weekdays.contains(weekday - 1)
        // Classic cron: when both are restricted, either one may match.
        if dayOfMonthRestricted && weekdayRestricted { return domOK || dowOK }
        return domOK && dowOK
    }

    /// The first time strictly after `date` at which the schedule fires.
    public func nextDate(after date: Date, calendar: Calendar = .current) -> Date? {
        // Start at the next whole minute.
        guard var candidate = calendar.dateInterval(of: .minute, for: date)?.end else { return nil }
        let limit = date.addingTimeInterval(5 * 366 * 24 * 3600)
        while candidate < limit {
            let c = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: candidate)
            if !dayMatches(c, calendar: calendar) {
                guard let startOfDay = calendar.dateInterval(of: .day, for: candidate)?.end else { return nil }
                candidate = startOfDay
                continue
            }
            if let hour = c.hour, !hours.contains(hour) {
                guard let nextHour = calendar.dateInterval(of: .hour, for: candidate)?.end else { return nil }
                candidate = nextHour
                continue
            }
            if let minute = c.minute, minutes.contains(minute) {
                return candidate
            }
            candidate = candidate.addingTimeInterval(60)
        }
        return nil
    }

    /// The next `count` fire times after `date`.
    public func upcoming(_ count: Int, after date: Date = Date(), calendar: Calendar = .current) -> [Date] {
        var dates: [Date] = []
        var cursor = date
        while dates.count < count, let next = nextDate(after: cursor, calendar: calendar) {
            dates.append(next)
            cursor = next
        }
        return dates
    }

    /// A short English description for common shapes, e.g. "Every weekday at 09:00".
    public var summary: String {
        let fields = (try? CronSchedule.expand(expression)) ?? []
        guard fields.count == 5 else { return expression }
        let (m, h, dom, mon, dow) = (fields[0], fields[1], fields[2], fields[3], fields[4])
        func time() -> String? {
            guard let hour = Int(h), let minute = Int(m) else { return nil }
            return String(format: "%02d:%02d", hour, minute)
        }
        if m == "*" && h == "*" && dom == "*" && mon == "*" && dow == "*" { return "Every minute" }
        if m.hasPrefix("*/"), h == "*", dom == "*", mon == "*", dow == "*" { return "Every \(m.dropFirst(2)) minutes" }
        if Int(m) != nil, h == "*", dom == "*", mon == "*", dow == "*" { return "Every hour at :\(String(format: "%02d", Int(m)!))" }
        if Int(m) != nil, h.hasPrefix("*/"), dom == "*", mon == "*", dow == "*" { return "Every \(h.dropFirst(2)) hours" }
        guard let at = time() else { return expression }
        if dom == "*" && mon == "*" {
            switch dow.lowercased() {
            case "*": return "Every day at \(at)"
            case "1-5", "mon-fri": return "Every weekday at \(at)"
            case "0,6", "6,0", "sat,sun", "sun,sat": return "Weekends at \(at)"
            default:
                if let set = try? CronSchedule.parse(dow, name: "weekday", range: 0...7, names: weekdayNames) {
                    let names = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"]
                    let days = Set(set.map { $0 % 7 }).sorted().map { names[$0] }
                    let joined = days.count > 1
                        ? days.dropLast().joined(separator: ", ") + " and " + days.last!
                        : days.joined()
                    return "\(joined) at \(at)"
                }
            }
        }
        if mon == "*" && dow == "*", let day = Int(dom) {
            return "Monthly on day \(day) at \(at)"
        }
        return expression
    }

    private static func expand(_ expression: String) throws -> [String] {
        _ = try CronSchedule(expression)
        switch expression.trimmingCharacters(in: .whitespaces).lowercased() {
        case "@hourly": return ["0", "*", "*", "*", "*"]
        case "@daily", "@midnight": return ["0", "0", "*", "*", "*"]
        case "@weekly": return ["0", "0", "*", "*", "0"]
        case "@monthly": return ["0", "0", "1", "*", "*"]
        case "@yearly", "@annually": return ["0", "0", "1", "1", "*"]
        default: return expression.split(whereSeparator: \.isWhitespace).map(String.init)
        }
    }
}

// MARK: - Scheduled tasks

/// A prompt Apeiron runs on a schedule, each run in a fresh chat.
public struct ScheduledTask: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var prompt: String
    /// Cron expression (see `CronSchedule`).
    public var schedule: String
    public var isEnabled: Bool
    /// Runs inside this project when set; otherwise in `workspacePath`.
    public var projectID: UUID?
    public var workspacePath: String?
    /// nil uses the project's or the app's default model.
    public var modelID: String?
    public var mode: PermissionMode
    /// What to do when a tool still needs approval during a run.
    public var approvalPolicy: ApprovalPolicy
    /// Show a notification when a run finishes.
    public var notify: Bool
    public var createdAt: Date
    public var lastRunAt: Date?
    public var runs: [ScheduledTaskRun]

    public enum ApprovalPolicy: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Deny the action and let the agent carry on without it.
        case deny
        /// Pause the run until someone approves it in the chat.
        case wait

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .deny: return "Skip it and carry on"
            case .wait: return "Wait for my approval"
            }
        }
    }

    public init(
        id: UUID = UUID(),
        name: String = "New task",
        prompt: String = "",
        schedule: String = "0 9 * * 1-5",
        isEnabled: Bool = true,
        projectID: UUID? = nil,
        workspacePath: String? = nil,
        modelID: String? = nil,
        mode: PermissionMode = .fullAccess,
        approvalPolicy: ApprovalPolicy = .deny,
        notify: Bool = true,
        createdAt: Date = Date(),
        lastRunAt: Date? = nil,
        runs: [ScheduledTaskRun] = []
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.schedule = schedule
        self.isEnabled = isEnabled
        self.projectID = projectID
        self.workspacePath = workspacePath
        self.modelID = modelID
        self.mode = mode
        self.approvalPolicy = approvalPolicy
        self.notify = notify
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.runs = runs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ScheduledTask()
        id = try c.decode(UUID.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? defaults.name
        prompt = (try? c.decode(String.self, forKey: .prompt)) ?? ""
        schedule = (try? c.decode(String.self, forKey: .schedule)) ?? defaults.schedule
        isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? true
        projectID = try? c.decodeIfPresent(UUID.self, forKey: .projectID)
        workspacePath = try? c.decodeIfPresent(String.self, forKey: .workspacePath)
        modelID = try? c.decodeIfPresent(String.self, forKey: .modelID)
        mode = (try? c.decode(PermissionMode.self, forKey: .mode)) ?? defaults.mode
        approvalPolicy = (try? c.decode(ApprovalPolicy.self, forKey: .approvalPolicy)) ?? .deny
        notify = (try? c.decode(Bool.self, forKey: .notify)) ?? true
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        lastRunAt = try? c.decodeIfPresent(Date.self, forKey: .lastRunAt)
        runs = (try? c.decode([ScheduledTaskRun].self, forKey: .runs)) ?? []
    }

    public var cron: CronSchedule? { try? CronSchedule(schedule) }

    /// When the task fires next, counting from its last run (or creation).
    public func nextRun(after date: Date = Date()) -> Date? {
        guard isEnabled, let cron else { return nil }
        return cron.nextDate(after: date)
    }

    /// True when a fire time has passed since the task last ran (or since
    /// `since`, whichever is later), so the scheduler should start it now.
    public func isDue(at now: Date, since: Date) -> Bool {
        guard isEnabled, let cron else { return false }
        let from = max(lastRunAt ?? createdAt, since)
        guard let next = cron.nextDate(after: from) else { return false }
        return next <= now
    }

    public static let maxRunsKept = 50

    public mutating func record(_ run: ScheduledTaskRun) {
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.insert(run, at: 0)
        }
        if runs.count > Self.maxRunsKept { runs.removeLast(runs.count - Self.maxRunsKept) }
    }
}

public struct ScheduledTaskRun: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var sessionID: UUID
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: Status
    public var trigger: Trigger
    /// First lines of the final answer, or the error.
    public var summary: String?

    public enum Status: String, Codable, Sendable {
        case running, succeeded, failed, stopped
    }

    public enum Trigger: String, Codable, Sendable {
        case schedule, manual
    }

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        status: Status = .running,
        trigger: Trigger = .schedule,
        summary: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.trigger = trigger
        self.summary = summary
    }
}

/// Scheduled tasks as one JSON file in the Apeiron config folder.
public final class ScheduledTaskStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? ProjectContext.userConfigDirectory.appendingPathComponent("tasks.json")
        try? FileManager.default.createDirectory(at: self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    public func load() -> [ScheduledTask] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ScheduledTask].self, from: data)) ?? []
    }

    public func save(_ tasks: [ScheduledTask]) throws {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(tasks).write(to: fileURL, options: .atomic)
    }
}
