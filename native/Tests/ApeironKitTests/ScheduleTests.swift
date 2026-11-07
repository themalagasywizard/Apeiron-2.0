import XCTest
@testable import ApeironKit

final class ScheduleTests: XCTestCase {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    func testParsesFieldsAndShortcuts() throws {
        XCTAssertNoThrow(try CronSchedule("*/15 9-17 * * mon-fri"))
        XCTAssertNoThrow(try CronSchedule("0 0 1,15 jan,jul *"))
        XCTAssertNoThrow(try CronSchedule("@daily"))
        XCTAssertNoThrow(try CronSchedule("5/10 * * * 7"))
        XCTAssertThrowsError(try CronSchedule("* * * *"))
        XCTAssertThrowsError(try CronSchedule("60 * * * *"))
        XCTAssertThrowsError(try CronSchedule("* * * * funday"))
        XCTAssertThrowsError(try CronSchedule("*/0 * * * *"))
        XCTAssertThrowsError(try CronSchedule("5-1 * * * *"))
    }

    func testNextDate() throws {
        // Saturday 7 Nov 2026, 15:00:30.
        let now = date(2026, 11, 7, 15, 0, 30)
        let weekdays = try CronSchedule("0 9 * * 1-5")
        XCTAssertEqual(weekdays.nextDate(after: now, calendar: calendar), date(2026, 11, 9, 9, 0))

        let quarterHour = try CronSchedule("*/15 * * * *")
        XCTAssertEqual(quarterHour.nextDate(after: now, calendar: calendar), date(2026, 11, 7, 15, 15))

        let hourly = try CronSchedule("@hourly")
        XCTAssertEqual(hourly.nextDate(after: now, calendar: calendar), date(2026, 11, 7, 16, 0))

        let monthly = try CronSchedule("30 8 1 * *")
        XCTAssertEqual(monthly.nextDate(after: now, calendar: calendar), date(2026, 12, 1, 8, 30))

        // Strictly after: a time exactly on the schedule moves to the next one.
        let daily = try CronSchedule("0 15 * * *")
        XCTAssertEqual(daily.nextDate(after: date(2026, 11, 7, 15, 0), calendar: calendar), date(2026, 11, 8, 15, 0))

        // Sunday as 7.
        let sunday = try CronSchedule("0 10 * * 7")
        XCTAssertEqual(sunday.nextDate(after: now, calendar: calendar), date(2026, 11, 8, 10, 0))

        // Day of month OR weekday when both are restricted.
        let either = try CronSchedule("0 12 13 * 5")
        XCTAssertEqual(either.nextDate(after: now, calendar: calendar), date(2026, 11, 13, 12, 0))
        XCTAssertEqual(either.nextDate(after: date(2026, 11, 13, 12, 0), calendar: calendar), date(2026, 11, 20, 12, 0))

        let leap = try CronSchedule("0 0 29 2 *")
        XCTAssertEqual(leap.nextDate(after: now, calendar: calendar), date(2028, 2, 29, 0, 0))

        XCTAssertEqual(quarterHour.upcoming(3, after: now, calendar: calendar).count, 3)
    }

    func testSummaries() throws {
        XCTAssertEqual(try CronSchedule("0 9 * * 1-5").summary, "Every weekday at 09:00")
        XCTAssertEqual(try CronSchedule("30 18 * * *").summary, "Every day at 18:30")
        XCTAssertEqual(try CronSchedule("*/10 * * * *").summary, "Every 10 minutes")
        XCTAssertEqual(try CronSchedule("@hourly").summary, "Every hour at :00")
        XCTAssertEqual(try CronSchedule("0 8 * * 1,3,5").summary, "Mondays, Wednesdays and Fridays at 08:00")
        XCTAssertEqual(try CronSchedule("0 7 1 * *").summary, "Monthly on day 1 at 07:00")
    }

    func testTaskIsDueOncePerFireTime() throws {
        let launched = date(2026, 11, 7, 8, 0)
        var task = ScheduledTask(name: "Standup", prompt: "Summarise", schedule: "0 9 * * *", createdAt: date(2026, 11, 1))
        XCTAssertFalse(task.isDue(at: date(2026, 11, 7, 8, 59), since: launched))
        XCTAssertTrue(task.isDue(at: date(2026, 11, 7, 9, 0, 20), since: launched))
        task.lastRunAt = date(2026, 11, 7, 9, 0, 20)
        XCTAssertFalse(task.isDue(at: date(2026, 11, 7, 9, 0, 50), since: launched))
        XCTAssertTrue(task.isDue(at: date(2026, 11, 8, 9, 0, 5), since: launched))
        task.isEnabled = false
        XCTAssertFalse(task.isDue(at: date(2026, 11, 8, 9, 0, 5), since: launched))
    }

    func testTaskRoundTripsAndKeepsRecentRuns() throws {
        var task = ScheduledTask(name: "Nightly", prompt: "Run tests", schedule: "@daily")
        for _ in 0..<(ScheduledTask.maxRunsKept + 5) {
            task.record(ScheduledTaskRun(sessionID: UUID()))
        }
        XCTAssertEqual(task.runs.count, ScheduledTask.maxRunsKept)

        let file = try makeTempDirectory().appendingPathComponent("tasks.json")
        let store = ScheduledTaskStore(fileURL: file)
        try store.save([task])
        XCTAssertEqual(store.load().first?.name, "Nightly")
        XCTAssertEqual(store.load().first?.runs.count, ScheduledTask.maxRunsKept)

        // Old files without newer fields still load.
        let legacy = #"[{"id":"\#(UUID().uuidString)","name":"Old","prompt":"x","schedule":"@hourly"}]"#
        try Data(legacy.utf8).write(to: file)
        XCTAssertEqual(store.load().first?.approvalPolicy, .deny)
    }
}

final class ProjectTests: XCTestCase {
    func testLinkedRootsHaveWorkspaceAccess() throws {
        let workspace = try makeTempDirectory()
        let other = try makeTempDirectory()
        let file = try makeTempDirectory().appendingPathComponent("notes.md")
        try "hi".write(to: file, atomically: true, encoding: .utf8)

        var project = Project(name: "Launch")
        project.link([workspace, other, file, other])
        XCTAssertEqual(project.items.count, 3)
        XCTAssertEqual(project.folders.count, 2)
        XCTAssertEqual(project.files.count, 1)
        XCTAssertEqual(project.primaryFolder?.standardizedFileURL.path, workspace.standardizedFileURL.path)

        let context = ToolContext(
            workspace: workspace,
            sessionDirectory: workspace.appendingPathComponent(".session"),
            linkedRoots: project.linkedRoots(excluding: workspace)
        )
        XCTAssertTrue(context.isInsideWorkspace(other.appendingPathComponent("src/a.swift")))
        XCTAssertTrue(context.isInsideWorkspace(file))
        XCTAssertFalse(context.isInsideWorkspace(file.deletingLastPathComponent().appendingPathComponent("other.md")))
        XCTAssertFalse(context.isInsideWorkspace(URL(fileURLWithPath: "/etc/hosts")))

        let edit: JSONValue = ["path": .string(other.appendingPathComponent("a.txt").path), "old_string": "a", "new_string": "b"]
        XCTAssertEqual(PermissionPolicy(mode: .autoEdit).evaluate(tool: EditFileTool(), input: edit, context: context), .allow)
        let read: JSONValue = ["path": .string(file.path)]
        XCTAssertEqual(PermissionPolicy(mode: .ask).evaluate(tool: ReadFileTool(), input: read, context: context), .allow)
    }

    func testProjectStoreAndPrompt() throws {
        let file = try makeTempDirectory().appendingPathComponent("projects.json")
        let store = ProjectStore(fileURL: file)
        let project = Project(name: "Site", instructions: "Use British English.", items: [ProjectItem(path: "/tmp/site", isDirectory: true)])
        try store.save([project])
        let loaded = try XCTUnwrap(store.load().first)
        XCTAssertEqual(loaded.id, project.id)
        XCTAssertEqual(loaded.name, "Site")
        XCTAssertEqual(loaded.items, project.items)
        XCTAssertEqual(loaded.defaultMode, .fullAccess)
        let section = ProjectBrief(project).promptSection
        XCTAssertTrue(section.contains("Project: Site"))
        XCTAssertTrue(section.contains("/tmp/site"))
        XCTAssertTrue(section.contains("Use British English."))
    }
}
