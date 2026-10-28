import Foundation
@preconcurrency import EventKit
import AppKit

public struct ExecutionReport: Sendable {
    public var createdEventsCount: Int = 0
    public var createdRemindersCount: Int = 0
    public var createdAlarmsCount: Int = 0
    public var createdNotesCount: Int = 0
    public var committedItemIDs: Set<UUID> = []
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
                            try createCalendarEvent(from: draft)
                            report.createdEventsCount += 1
                            report.committedItemIDs.insert(draft.id)
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
                            try createReminder(from: draft)
                            report.createdRemindersCount += 1
                            report.committedItemIDs.insert(draft.id)
                        } catch {
                            report.errors.append("提醒「\(draft.title)」写入失败: \(error.localizedDescription)")
                        }
                    }
                    for alarmDraft in selectedAlarms {
                        do {
                            try await createAlarmEntry(from: alarmDraft)
                            report.createdAlarmsCount += 1
                            report.committedItemIDs.insert(alarmDraft.id)
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
                try await createAppleNoteAsync(from: note)
                report.createdNotesCount += 1
                report.committedItemIDs.insert(note.id)
            } catch {
                report.errors.append("备忘录「\(note.title)」写入失败: \(error.localizedDescription)")
            }
        }

        return report
    }

    private func createAlarmEntry(from draft: DraftItem) async throws {
        let isoTarget = draft.startISO.isEmpty ? draft.alarmTimeISO : draft.startISO
        guard let alarmDate = PromptBuilder.parseISODate(isoTarget) else {
            throw NSError(domain: "MemoPilot.Alarm", code: 10, userInfo: [NSLocalizedDescriptionKey: "无法解析闹钟时间（\(isoTarget)）"])
        }

        let alarmTitle = draft.title.hasPrefix("⏰") ? draft.title : "⏰ 【闹钟】\(draft.title)"

        try lock.withLock {
            // 1. High-priority critical Reminder with exact & pre-alarm offsets (syncs to iPhone via iCloud)
            if let remCal = eventStore.defaultCalendarForNewReminders() ?? eventStore.calendars(for: .reminder).first(where: { $0.allowsContentModifications }) {
                let reminder = EKReminder(eventStore: eventStore)
                reminder.calendar = remCal
                reminder.title = alarmTitle
                reminder.notes = [draft.location, draft.notes].filter { !$0.isEmpty }.joined(separator: " · ")
                reminder.priority = 1 // Highest priority

                var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: alarmDate)
                comps.timeZone = TimeZone.current
                comps.calendar = Calendar.current
                reminder.dueDateComponents = comps

                reminder.addAlarm(EKAlarm(absoluteDate: alarmDate))
                for lead in draft.leadTimeMinutes where lead > 0 {
                    reminder.addAlarm(EKAlarm(absoluteDate: alarmDate.addingTimeInterval(-Double(lead * 60))))
                }
                try eventStore.save(reminder, commit: true)
            }

            // 2. Also add a 15-minute Calendar alarm block so both Calendar & Reminders ring
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

        // 3. Schedule local Mac frontmost sound & critical modal alert
        await MainActor.run {
            LocalAlarmScheduler.shared.scheduleAlarm(
                id: draft.id,
                title: draft.title,
                alarmDate: alarmDate,
                notes: draft.notes
            )
        }
    }

    private func createCalendarEvent(from draft: CalendarEventDraft) throws {
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
        }
    }

    private func createReminder(from draft: ReminderDraft) throws {
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
        }
    }

    public static func htmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func createAppleNoteAsync(from draft: KeyNoteDraft) async throws {
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
                            make new note at default folder with properties {name:noteTitle, body:noteBody}
                        on error
                            make new note with properties {name:noteTitle, body:noteBody}
                        end try
                    end tell
                end tell
            end run
            """

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script, draft.title, fullHTML]
            process.standardInput = FileHandle.nullDevice

            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = FileHandle.nullDevice

            try process.run()
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
        }.value
    }
}
