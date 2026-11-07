import ApeironKit
import SwiftUI

/// Create or edit a scheduled task.
struct TaskEditorView: View {
    @State var task: ScheduledTask
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var builder = ScheduleBuilder()
    @State private var customCron = ""

    private var isNew: Bool { app.task(id: task.id) == nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.accentColor)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.accentColor.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNew ? "New task" : "Edit task")
                        .font(theme.display(20))
                        .foregroundStyle(Palette.textPrimary)
                    Text("Apeiron runs the prompt on schedule, each time in a new chat.")
                        .font(theme.ui(12))
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            Divider().overlay(Palette.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("Task") {
                        TextField("Name, e.g. Morning briefing", text: $task.name)
                            .textFieldStyle(.plain)
                            .font(theme.ui(14, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .card(fill: Palette.surface)
                        ZStack(alignment: .topLeading) {
                            if task.prompt.isEmpty {
                                Text("What should Apeiron do each time? Be specific about the result you want.")
                                    .font(theme.ui(13))
                                    .foregroundStyle(Palette.textTertiary)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 10)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $task.prompt)
                                .font(theme.ui(13))
                                .scrollContentBackground(.hidden)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        }
                        .frame(minHeight: 120)
                        .card(fill: Palette.surface)
                    }
                    section("Schedule") { scheduleControls }
                    section("Where it runs") { locationControls }
                    section("Run settings") { runControls }
                }
                .padding(24)
            }

            Divider().overlay(Palette.border)
            HStack {
                Toggle("Enabled", isOn: $task.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(theme.accentColor)
                    .font(theme.ui(12.5))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(OutlineButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create task" : "Save") {
                    task.schedule = cronExpression
                    app.saveTask(task)
                    dismiss()
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.5)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 620, height: 720)
        .background(Palette.canvas)
        .onAppear {
            builder = ScheduleBuilder(cron: task.schedule)
            customCron = task.schedule
        }
    }

    // MARK: Schedule

    private var cronExpression: String {
        builder.frequency == .custom ? customCron.trimmingCharacters(in: .whitespaces) : builder.expression
    }

    private var parsed: Result<CronSchedule, Error> {
        Result { try CronSchedule(cronExpression) }
    }

    private var canSave: Bool {
        !task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (try? parsed.get()) != nil
    }

    private var scheduleControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Repeat").font(theme.ui(13, weight: .medium)).foregroundStyle(Palette.textPrimary)
                Spacer()
                Picker("", selection: $builder.frequency) {
                    ForEach(ScheduleBuilder.Frequency.allCases) { frequency in
                        Text(frequency.label).tag(frequency)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(12)

            if builder.frequency != .custom {
                Divider().overlay(Palette.border)
                HStack(spacing: 12) {
                    switch builder.frequency {
                    case .minutes:
                        Text("Every").font(theme.ui(13)).foregroundStyle(Palette.textSecondary)
                        Picker("", selection: $builder.interval) {
                            ForEach([5, 10, 15, 20, 30], id: \.self) { Text("\($0) minutes").tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    case .hourly:
                        Text("At minute").font(theme.ui(13)).foregroundStyle(Palette.textSecondary)
                        Stepper(value: $builder.minute, in: 0...59, step: 5) {
                            Text(String(format: ":%02d", builder.minute)).font(theme.mono(13))
                        }
                    case .weekly:
                        Picker("", selection: $builder.weekday) {
                            ForEach(0..<7, id: \.self) { day in
                                Text(Calendar.current.weekdaySymbols[day]).tag(day)
                            }
                        }
                        .labelsHidden().fixedSize()
                        timePicker
                    case .monthly:
                        Text("Day").font(theme.ui(13)).foregroundStyle(Palette.textSecondary)
                        Stepper(value: $builder.dayOfMonth, in: 1...28) {
                            Text("\(builder.dayOfMonth)").font(theme.mono(13))
                        }
                        timePicker
                    case .daily, .weekdays:
                        Text("At").font(theme.ui(13)).foregroundStyle(Palette.textSecondary)
                        timePicker
                    case .custom:
                        EmptyView()
                    }
                    Spacer()
                }
                .padding(12)
            } else {
                Divider().overlay(Palette.border)
                VStack(alignment: .leading, spacing: 6) {
                    TextField("minute hour day month weekday", text: $customCron)
                        .textFieldStyle(.plain)
                        .font(theme.mono(13))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous).fill(Palette.surfaceSunken))
                    Text("Cron syntax, e.g. `*/15 9-17 * * 1-5` for every 15 minutes during working hours. `@daily` and `@hourly` work too.")
                        .font(theme.ui(11.5))
                        .foregroundStyle(Palette.textTertiary)
                }
                .padding(12)
            }

            Divider().overlay(Palette.border)
            preview.padding(12)
        }
        .card(fill: Palette.surface)
        .onChange(of: builder.frequency) { old, new in
            if new == .custom && old != .custom { customCron = builder.expression(for: old) }
        }
    }

    private var timePicker: some View {
        DatePicker("", selection: $builder.time, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .fixedSize()
    }

    @ViewBuilder
    private var preview: some View {
        switch parsed {
        case .success(let cron):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.clock").foregroundStyle(theme.accentColor)
                    Text(cron.summary).foregroundStyle(Palette.textPrimary)
                    Spacer()
                    Text(cron.expression)
                        .font(theme.mono(11))
                        .foregroundStyle(Palette.textTertiary)
                }
                .font(theme.ui(12.5, weight: .medium))
                Text("Next: " + cron.upcoming(3).map { $0.formatted(date: .abbreviated, time: .shortened) }.joined(separator: "  ·  "))
                    .font(theme.ui(11.5))
                    .foregroundStyle(Palette.textTertiary)
            }
        case .failure(let error):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                Text(error.localizedDescription).foregroundStyle(Palette.textSecondary)
            }
            .font(theme.ui(12))
        }
    }

    // MARK: Location

    private var locationControls: some View {
        VStack(spacing: 0) {
            row("Project", detail: "Runs get the project's folders, files and instructions.") {
                Picker("", selection: $task.projectID) {
                    Text("None").tag(UUID?.none)
                    if !app.projects.isEmpty { Divider() }
                    ForEach(app.projects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if task.projectID == nil {
                Divider().overlay(Palette.border)
                row("Folder", detail: task.workspacePath ?? "Uses your most recent folder") {
                    Button("Choose…") {
                        if let url = app.chooseFolder() { task.workspacePath = url.path }
                    }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                }
            }
        }
        .card(fill: Palette.surface)
    }

    // MARK: Run settings

    private var runControls: some View {
        VStack(spacing: 0) {
            row("Model", detail: "Defaults to the project's or the app's model.") {
                Picker("", selection: $task.modelID) {
                    Text("Default").tag(String?.none)
                    Divider()
                    ForEach(app.allModels.filter { app.isConfigured($0.provider) }, id: \.id) { model in
                        Text(model.displayName).tag(Optional(model.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Divider().overlay(Palette.border)
            row("Permission mode", detail: task.mode.summary) {
                Picker("", selection: $task.mode) {
                    ForEach(PermissionMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Divider().overlay(Palette.border)
            row("When something needs approval", detail: task.approvalPolicy == .deny
                ? "The agent is told it was skipped and carries on."
                : "The run pauses until you approve it in the chat.") {
                Picker("", selection: $task.approvalPolicy) {
                    ForEach(ScheduledTask.ApprovalPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Divider().overlay(Palette.border)
            row("Notify when done", detail: "A macOS notification with the result.") {
                Toggle("", isOn: $task.notify)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(theme.accentColor)
            }
        }
        .card(fill: Palette.surface)
    }

    // MARK: Helpers

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(theme.ui(10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Palette.textTertiary)
            content()
        }
    }

    private func row<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(theme.ui(13, weight: .medium)).foregroundStyle(Palette.textPrimary)
                Text(detail).font(theme.ui(11.5)).foregroundStyle(Palette.textTertiary).lineLimit(2).truncationMode(.middle)
            }
            Spacer()
            control()
        }
        .padding(12)
    }
}

/// Friendly schedule controls that map to a cron expression.
struct ScheduleBuilder: Equatable {
    enum Frequency: String, CaseIterable, Identifiable {
        case minutes, hourly, daily, weekdays, weekly, monthly, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .minutes: return "Every few minutes"
            case .hourly: return "Hourly"
            case .daily: return "Daily"
            case .weekdays: return "Weekdays"
            case .weekly: return "Weekly"
            case .monthly: return "Monthly"
            case .custom: return "Custom (cron)"
            }
        }
    }

    var frequency: Frequency = .weekdays
    var interval = 15
    var minute = 0
    var hour = 9
    var weekday = 1
    var dayOfMonth = 1

    var time: Date {
        get { Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? Date() }
        set {
            let c = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            hour = c.hour ?? 9
            minute = c.minute ?? 0
        }
    }

    var expression: String { expression(for: frequency) }

    func expression(for frequency: Frequency) -> String {
        switch frequency {
        case .minutes: return "*/\(interval) * * * *"
        case .hourly: return "\(minute) * * * *"
        case .daily: return "\(minute) \(hour) * * *"
        case .weekdays: return "\(minute) \(hour) * * 1-5"
        case .weekly: return "\(minute) \(hour) * * \(weekday)"
        case .monthly: return "\(minute) \(hour) \(dayOfMonth) * *"
        case .custom: return "\(minute) \(hour) * * *"
        }
    }

    init() {}

    /// Recognises the shapes the controls produce; anything else is custom.
    init(cron: String) {
        let f = cron.split(whereSeparator: \.isWhitespace).map(String.init)
        guard f.count == 5 else { frequency = .custom; return }
        let m = Int(f[0]), h = Int(f[1])
        if f[0].hasPrefix("*/"), let n = Int(f[0].dropFirst(2)), [5, 10, 15, 20, 30].contains(n), f[1...].allSatisfy({ $0 == "*" }) {
            frequency = .minutes; interval = n
        } else if let m, f[1] == "*", f[2] == "*", f[3] == "*", f[4] == "*" {
            frequency = .hourly; minute = m
        } else if let m, let h, f[2] == "*", f[3] == "*" {
            minute = m; hour = h
            if f[4] == "*" { frequency = .daily }
            else if f[4] == "1-5" { frequency = .weekdays }
            else if let d = Int(f[4]), (0...7).contains(d) { frequency = .weekly; weekday = d % 7 }
            else { frequency = .custom }
        } else if let m, let h, let d = Int(f[2]), (1...28).contains(d), f[3] == "*", f[4] == "*" {
            frequency = .monthly; minute = m; hour = h; dayOfMonth = d
        } else {
            frequency = .custom
        }
    }
}
