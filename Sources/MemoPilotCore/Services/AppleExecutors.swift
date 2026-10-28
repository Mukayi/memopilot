import Foundation
@preconcurrency import EventKit
import AppKit

public struct ExecutionReport: Sendable {
    public var createdEventsCount: Int = 0
    public var createdRemindersCount: Int = 0
    public var createdAlarmsCount: Int = 0
    public var createdNotesCount: Int = 0
    public var committedItemIDs: Set<UUID> = []
    public var committedExternalIDs: [UUID: String] = [:]
    public var triggeredAlarms: [String] = []
    public var errors: [String] = []

    public var summaryText: String {
        var parts: [String] = []
        if createdEventsCount > 0 { parts.append("📅 日历 \(createdEventsCount) 项") }
        if createdRemindersCount > 0 { parts.append("☑️ 提醒事项 \(createdRemindersCount) 项") }
        if createdAlarmsCount > 0 { parts.append("⏰ 闹钟 \(createdAlarmsCount) 个") }
        if createdNotesCount > 0 { parts.append("📝 备忘录 \(createdNotesCount) 篇") }
        if !triggeredAlarms.isEmpty && createdAlarmsCount == 0 {
            parts.append("⏰ 强闹钟建议 \(triggeredAlarms.count) 项")
        }
        if parts.isEmpty && errors.isEmpty { return "未选中任何要写入的项目" }
        let base = parts.joined(separator: " · ")
        if errors.isEmpty {
            return "已写入：\(base)"
        } else if parts.isEmpty {
            return "写入失败：\(errors.joined(separator: "；"))"
        } else {
            return "\(base)（部分失败：\(errors.joined(separator: "；"))）"
        }
    }
}

@MainActor
public final class LocalAlarmScheduler {
    public static let shared = LocalAlarmScheduler()
    private var scheduledTimers: [UUID: Timer] = [:]

    private init() {}

    public func scheduleAlarm(id: UUID, title: String, alarmDate: Date, notes: String) {
        scheduledTimers[id]?.invalidate()
        let interval = alarmDate.timeIntervalSinceNow
        guard interval > 0 else { return }

        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            Task { @MainActor in
                NSSound(named: NSSound.Name("Glass"))?.play()
                NSApp.activate()
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "⏰ 闹钟时间到：\(title)"
                alert.informativeText = notes.isEmpty ? "由 MemoPilot 设定的系统强提醒闹钟" : notes
                alert.addButton(withTitle: "知道了")
                alert.runModal()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scheduledTimers[id] = timer
    }
}

public final class AppleExecutors: @unchecked Sendable {
    public static let shared = AppleExecutors()
    private let eventStore = EKEventStore()
    private let lock = NSLock()

    private init() {}

    // MARK: - 1-Click Jump to Native macOS Apps (Calendar / Reminders / Notes)

    @MainActor
    public static func openSystemApp(for kind: DraftTargetKind) {
        let appPath: String
        switch kind {
        case .calendar:
            appPath = "/System/Applications/Calendar.app"
        case .reminder, .alarm:
            appPath = "/System/Applications/Reminders.app"
        case .note:
            appPath = "/System/Applications/Notes.app"
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: config)
    }

    @MainActor
    public static func openInTargetApp(for item: DraftItem) {
        // 1. Immediately bring the target system app to front
        openSystemApp(for: item.targetKind)

        // 2. Deep-link / navigate to the exact date, reminder, or note via JXA
        let kind = item.targetKind
        let extID = item.createdExternalID ?? ""
        let title = item.title
        let startISO = item.startISO.isEmpty ? item.alarmTimeISO : item.startISO
        let parsedDate = PromptBuilder.parseISODate(startISO)

        Task.detached(priority: .userInitiated) {
            switch kind {
            case .calendar:
                if let date = parsedDate {
                    let epochMs = Int64(date.timeIntervalSince1970 * 1000.0)
                    let jxa = """
                    const Cal = Application("Calendar");
                    Cal.activate();
                    Cal.viewCalendar({at: new Date(\(epochMs))});
                    """
                    Self.runQuickJXA(jxa, arguments: [])
                }

            case .reminder, .alarm:
                let searchTitle = (kind == .alarm && !title.hasPrefix("⏰")) ? "⏰ 【闹钟】\(title)" : title
                let jxa = """
                ObjC.import('Foundation');
                const args = $.NSProcessInfo.processInfo.arguments;
                const targetID = ObjC.unwrap(args.objectAtIndex(4));
                const targetTitle = ObjC.unwrap(args.objectAtIndex(5));
                const Rem = Application("Reminders");
                Rem.activate();
                try {
                    if (targetID.length > 0) {
                        Rem.reminders.byId(targetID).show();
                    } else if (targetTitle.length > 0) {
                        const found = Rem.reminders.whose({name: targetTitle})();
                        if (found.length > 0) { found[0].show(); }
                    }
                } catch (e) {}
                """
                Self.runQuickJXA(jxa, arguments: [extID, searchTitle])

            case .note:
                let jxa = """
                ObjC.import('Foundation');
                const args = $.NSProcessInfo.processInfo.arguments;
                const targetID = ObjC.unwrap(args.objectAtIndex(4));
                const targetTitle = ObjC.unwrap(args.objectAtIndex(5));
                const Notes = Application("Notes");
                Notes.activate();
                try {
                    if (targetID.length > 0) {
                        Notes.notes.byId(targetID).show();
                    } else if (targetTitle.length > 0) {
                        const found = Notes.notes.whose({name: targetTitle})();
                        if (found.length > 0) { found[0].show(); }
                    }
                } catch (e) {}
                """
                Self.runQuickJXA(jxa, arguments: [extID, title])
            }
        }
    }

    private static func runQuickJXA(_ script: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Execution

    public func execute(plan: ParsedPlan) async -> ExecutionReport {
        var report = ExecutionReport()

        let selectedEvents = plan.events.filter(\.isSelected)
        let selectedReminders = plan.reminders.filter(\.isSelected)
        let selectedAlarms = plan.alarms.filter(\.isSelected)
        let selectedNotes = plan.notes.filter(\.isSelected)

        if !selectedEvents.isEmpty || !selectedAlarms.isEmpty {
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                if granted {
                    if eventStore.defaultCalendarForNewEvents == nil {
                        eventStore.reset()
                    }
                    for draft in selectedEvents {
                        do {
                            let evID = try createCalendarEvent(from: draft)
                            report.createdEventsCount += 1
                            report.committedItemIDs.insert(draft.id)
                            if let evID { report.committedExternalIDs[draft.id] = evID }
                            if draft.needsAlarm {
                                report.triggeredAlarms.append("\(draft.title) (\(draft.alarmTimeISO.isEmpty ? draft.startISO : draft.alarmTimeISO))")
                            }
                        } catch {
                            report.errors.append("日程「\(draft.title)」写入失败: \(error.localizedDescription)")
                        }
                    }
                } else if !selectedEvents.isEmpty {
                    report.errors.append("未获得「日历」权限，请在系统设置 > 隐私与安全性 > 日历中允许 MemoPilot")
                }
            } catch {
                if !selectedEvents.isEmpty {
                    report.errors.append("请求日历权限出错: \(error.localizedDescription)")
                }
            }
        }

        if !selectedReminders.isEmpty || !selectedAlarms.isEmpty {
            do {
                let granted = try await eventStore.requestFullAccessToReminders()
                if granted {
                    if eventStore.defaultCalendarForNewReminders() == nil {
                        eventStore.reset()
                    }
                    for draft in selectedReminders {
                        do {
                            let remID = try createReminder(from: draft)
                            report.createdRemindersCount += 1
                            report.committedItemIDs.insert(draft.id)
                            if let remID { report.committedExternalIDs[draft.id] = remID }
                        } catch {
                            report.errors.append("提醒「\(draft.title)」写入失败: \(error.localizedDescription)")
                        }
                    }
                    for alarmDraft in selectedAlarms {
                        do {
                            let alarmID = try await createAlarmEntry(from: alarmDraft)
                            report.createdAlarmsCount += 1
                            report.committedItemIDs.insert(alarmDraft.id)
                            if let alarmID { report.committedExternalIDs[alarmDraft.id] = alarmID }
                            report.triggeredAlarms.append("\(alarmDraft.title)")
                        } catch {
                            report.errors.append("闹钟「\(alarmDraft.title)」设置失败: \(error.localizedDescription)")
                        }
                    }
                } else {
                    report.errors.append("未获得「提醒事项」权限，请在系统设置 > 隐私与安全性 > 提醒事项中允许 MemoPilot")
                }
            } catch {
                report.errors.append("请求提醒事项权限出错: \(error.localizedDescription)")
            }
        }

        for note in selectedNotes {
            do {
                let noteID = try await createAppleNoteAsync(from: note)
                report.createdNotesCount += 1
                report.committedItemIDs.insert(note.id)
                if let noteID, !noteID.isEmpty {
                    report.committedExternalIDs[note.id] = noteID
                }
            } catch {
                report.errors.append("备忘录「\(note.title)」写入失败: \(error.localizedDescription)")
            }
        }

        return report
    }

    private func createAlarmEntry(from draft: DraftItem) async throws -> String? {
        let isoTarget = draft.startISO.isEmpty ? draft.alarmTimeISO : draft.startISO
        guard let alarmDate = PromptBuilder.parseISODate(isoTarget) else {
            throw NSError(domain: "MemoPilot.Alarm", code: 10, userInfo: [NSLocalizedDescriptionKey: "无法解析闹钟时间（\(isoTarget)）"])
        }

        let alarmTitle = draft.title.hasPrefix("⏰") ? draft.title : "⏰ 【闹钟】\(draft.title)"
        var createdRemID: String?

        try lock.withLock {
            if let remCal = eventStore.defaultCalendarForNewReminders() ?? eventStore.calendars(for: .reminder).first(where: { $0.allowsContentModifications }) {
                let reminder = EKReminder(eventStore: eventStore)
                reminder.calendar = remCal
                reminder.title = alarmTitle
                reminder.notes = [draft.location, draft.notes].filter { !$0.isEmpty }.joined(separator: " · ")
                reminder.priority = 1

                var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: alarmDate)
                comps.timeZone = TimeZone.current
                comps.calendar = Calendar.current
                reminder.dueDateComponents = comps

                reminder.addAlarm(EKAlarm(absoluteDate: alarmDate))
                for lead in draft.leadTimeMinutes where lead > 0 {
                    reminder.addAlarm(EKAlarm(absoluteDate: alarmDate.addingTimeInterval(-Double(lead * 60))))
                }
                try eventStore.save(reminder, commit: true)
                createdRemID = reminder.calendarItemExternalIdentifier
            }

            if let evCal = eventStore.defaultCalendarForNewEvents ?? eventStore.calendars(for: .event).first(where: { $0.allowsContentModifications }) {
                let ev = EKEvent(eventStore: eventStore)
                ev.calendar = evCal
                ev.title = alarmTitle
                ev.startDate = alarmDate
                ev.endDate = alarmDate.addingTimeInterval(900)
                ev.location = draft.location
                ev.notes = draft.notes
                ev.addAlarm(EKAlarm(relativeOffset: 0))
                ev.addAlarm(EKAlarm(relativeOffset: -300))
                for offset in PromptBuilder.alarmRelativeOffsets(forLeadTimeMinutes: draft.leadTimeMinutes) where offset < 0 {
                    ev.addAlarm(EKAlarm(relativeOffset: offset))
                }
                try? eventStore.save(ev, span: .thisEvent, commit: true)
            }
        }

        await MainActor.run {
            LocalAlarmScheduler.shared.scheduleAlarm(
                id: draft.id,
                title: draft.title,
                alarmDate: alarmDate,
                notes: draft.notes
            )
        }
        return createdRemID
    }

    private func createCalendarEvent(from draft: CalendarEventDraft) throws -> String? {
        try lock.withLock {
            guard let calendar = eventStore.defaultCalendarForNewEvents ?? eventStore.calendars(for: .event).first(where: { $0.allowsContentModifications }) else {
                throw NSError(domain: "MemoPilot.EventKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到可写入的日历"])
            }
            guard let startDate = PromptBuilder.parseISODate(draft.startISO) else {
                throw NSError(domain: "MemoPilot.EventKit", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法解析日程开始时间（\(draft.startISO)）"])
            }
            let endDate = PromptBuilder.parseISODate(draft.endISO) ?? startDate.addingTimeInterval(3600)

            let event = EKEvent(eventStore: eventStore)
            event.calendar = calendar
            event.title = draft.title
            event.startDate = startDate
            event.endDate = endDate > startDate ? endDate : startDate.addingTimeInterval(1800)
            if !draft.location.isEmpty {
                event.location = draft.location
            }

            var noteLines: [String] = []
            if !draft.notes.isEmpty { noteLines.append(draft.notes) }
            if !draft.reasonForLeadTime.isEmpty {
                noteLines.append("💡 提前提醒策略：\(draft.reasonForLeadTime)")
            }
            if draft.needsAlarm {
                noteLines.append("⏰ 强提醒事项（建议闹钟：\(draft.alarmTimeISO.isEmpty ? "出发前" : draft.alarmTimeISO)）")
            }
            event.notes = noteLines.joined(separator: "\n")

            let leadTimes = draft.leadTimeMinutes.isEmpty ? [30] : draft.leadTimeMinutes
            for offset in PromptBuilder.alarmRelativeOffsets(forLeadTimeMinutes: leadTimes) {
                event.addAlarm(EKAlarm(relativeOffset: offset))
            }
            if draft.needsAlarm, let alarmDate = PromptBuilder.parseISODate(draft.alarmTimeISO) {
                event.addAlarm(EKAlarm(absoluteDate: alarmDate))
            }

            try eventStore.save(event, span: .thisEvent, commit: true)
            return event.calendarItemExternalIdentifier
        }
    }

    private func createReminder(from draft: ReminderDraft) throws -> String? {
        try lock.withLock {
            guard let calendar = eventStore.defaultCalendarForNewReminders() ?? eventStore.calendars(for: .reminder).first(where: { $0.allowsContentModifications }) else {
                throw NSError(domain: "MemoPilot.EventKit", code: 2, userInfo: [NSLocalizedDescriptionKey: "未找到默认提醒事项列表"])
            }
            let reminder = EKReminder(eventStore: eventStore)
            reminder.calendar = calendar
            reminder.title = draft.title
            reminder.notes = draft.notes
            reminder.priority = min(max(draft.priority, 0), 9)

            if let dueDate = PromptBuilder.parseISODate(draft.dueISO) {
                var comps = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: dueDate
                )
                comps.timeZone = TimeZone.current
                comps.calendar = Calendar.current
                reminder.dueDateComponents = comps
                let alarmDate = dueDate.addingTimeInterval(-Double(abs(draft.leadTimeMinutes) * 60))
                reminder.addAlarm(EKAlarm(absoluteDate: alarmDate))
            }

            try eventStore.save(reminder, commit: true)
            return reminder.calendarItemExternalIdentifier
        }
    }

    public static func htmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func createAppleNoteAsync(from draft: KeyNoteDraft) async throws -> String? {
        try await Task.detached(priority: .userInitiated) {
            let safeTitle = Self.htmlEscape(draft.title)
            let safeCategory = Self.htmlEscape(draft.category)
            let htmlBody = Self.htmlEscape(draft.bodyMarkdown)
                .replacingOccurrences(of: "\r\n", with: "<br>")
                .replacingOccurrences(of: "\n", with: "<br>")

            let fullHTML = "<h1>\(safeTitle)</h1><p><em>分类：\(safeCategory)</em></p><hr><p>\(htmlBody)</p>"

            let script = """
            on run argv
                set noteTitle to item 1 of argv
                set noteBody to item 2 of argv
                tell application "Notes"
                    tell default account
                        try
                            set createdNote to make new note at default folder with properties {name:noteTitle, body:noteBody}
                            return id of createdNote
                        on error
                            set createdNote to make new note with properties {name:noteTitle, body:noteBody}
                            return id of createdNote
                        end try
                    end tell
                end tell
            end run
            """

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script, draft.title, fullHTML]
            process.standardInput = FileHandle.nullDevice

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            try process.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知 AppleScript 错误"
                throw NSError(
                    domain: "MemoPilot.Notes",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: errMsg]
                )
            }
            return String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
