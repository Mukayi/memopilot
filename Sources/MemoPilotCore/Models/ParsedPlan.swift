import Foundation

public enum DraftTargetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case calendar = "日历"
    case reminder = "提醒"
    case alarm    = "闹钟"
    case note     = "备忘"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .calendar: return "calendar"
        case .reminder: return "checklist"
        case .alarm:    return "alarm.fill"
        case .note:     return "doc.text"
        }
    }
}

public struct DraftItem: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var isSelected: Bool
    public var targetKind: DraftTargetKind
    public var title: String
    public var startISO: String
    public var endISO: String
    public var location: String
    public var notes: String
    public var leadTimeMinutes: [Int]
    public var priority: Int
    public var needsAlarm: Bool
    public var alarmTimeISO: String
    public var reasonForLeadTime: String
    public var category: String

    public init(
        id: UUID = UUID(),
        isSelected: Bool = true,
        targetKind: DraftTargetKind,
        title: String,
        startISO: String = "",
        endISO: String = "",
        location: String = "",
        notes: String = "",
        leadTimeMinutes: [Int] = [15],
        priority: Int = 0,
        needsAlarm: Bool = false,
        alarmTimeISO: String = "",
        reasonForLeadTime: String = "",
        category: String = "备忘"
    ) {
        self.id = id
        self.isSelected = isSelected
        self.targetKind = targetKind
        self.title = title
        self.startISO = startISO
        self.endISO = endISO
        self.location = location
        self.notes = notes
        self.leadTimeMinutes = leadTimeMinutes
        self.priority = priority
        self.needsAlarm = needsAlarm
        self.alarmTimeISO = alarmTimeISO
        self.reasonForLeadTime = reasonForLeadTime
        self.category = category
    }

    public static func fromCalendarEvent(_ e: CalendarEventDraft) -> DraftItem {
        DraftItem(
            id: e.id,
            isSelected: e.isSelected,
            targetKind: .calendar,
            title: e.title,
            startISO: e.startISO,
            endISO: e.endISO,
            location: e.location,
            notes: e.notes,
            leadTimeMinutes: e.leadTimeMinutes.isEmpty ? [30] : e.leadTimeMinutes,
            priority: e.needsAlarm ? 1 : 0,
            needsAlarm: e.needsAlarm,
            alarmTimeISO: e.alarmTimeISO,
            reasonForLeadTime: e.reasonForLeadTime,
            category: "日程"
        )
    }

    public static func fromReminder(_ r: ReminderDraft) -> DraftItem {
        DraftItem(
            id: r.id,
            isSelected: r.isSelected,
            targetKind: .reminder,
            title: r.title,
            startISO: r.dueISO,
            endISO: "",
            location: "",
            notes: r.notes,
            leadTimeMinutes: [r.leadTimeMinutes],
            priority: r.priority,
            needsAlarm: false,
            alarmTimeISO: r.dueISO,
            reasonForLeadTime: "",
            category: "待办"
        )
    }

    public static func fromNote(_ n: KeyNoteDraft) -> DraftItem {
        DraftItem(
            id: n.id,
            isSelected: n.isSelected,
            targetKind: .note,
            title: n.title,
            startISO: "",
            endISO: "",
            location: "",
            notes: n.bodyMarkdown,
            leadTimeMinutes: [0],
            priority: 0,
            needsAlarm: false,
            alarmTimeISO: "",
            reasonForLeadTime: "",
            category: n.category.isEmpty ? "备忘" : n.category
        )
    }

    public func asCalendarEventDraft() -> CalendarEventDraft {
        let start = startISO.isEmpty ? Self.defaultUpcomingISO(offsetHours: 1) : startISO
        let end: String
        if !endISO.isEmpty,
           let sDate = PromptBuilder.parseISODate(start),
           let eDate = PromptBuilder.parseISODate(endISO),
           eDate > sDate {
            end = endISO
        } else if let sDate = PromptBuilder.parseISODate(start) {
            end = PromptBuilder.formatISODate(sDate.addingTimeInterval(3600))
        } else {
            end = Self.defaultUpcomingISO(offsetHours: 2)
        }
        return CalendarEventDraft(
            id: id,
            title: title,
            startISO: start,
            endISO: end,
            location: location,
            notes: notes,
            leadTimeMinutes: leadTimeMinutes.isEmpty ? [30] : leadTimeMinutes,
            needsAlarm: needsAlarm || targetKind == .alarm,
            alarmTimeISO: alarmTimeISO,
            reasonForLeadTime: reasonForLeadTime,
            isSelected: isSelected
        )
    }

    public func asReminderDraft() -> ReminderDraft {
        ReminderDraft(
            id: id,
            title: title,
            dueISO: startISO,
            notes: [location, notes].filter { !$0.isEmpty }.joined(separator: " · "),
            priority: priority,
            leadTimeMinutes: leadTimeMinutes.first ?? 15,
            isSelected: isSelected
        )
    }

    public func asKeyNoteDraft() -> KeyNoteDraft {
        let body: String
        if !notes.isEmpty {
            body = notes
        } else if !location.isEmpty {
            body = location
        } else {
            body = title
        }
        return KeyNoteDraft(
            id: id,
            title: title,
            bodyMarkdown: body,
            category: category.isEmpty ? "备忘" : category,
            isSelected: isSelected
        )
    }

    public static func defaultUpcomingISO(offsetHours: Int = 1) -> String {
        let now = Date()
        let cal = Calendar.current
        let nextHour = cal.date(byAdding: .hour, value: offsetHours, to: now) ?? now.addingTimeInterval(Double(offsetHours * 3600))
        let rounded = cal.date(bySetting: .minute, value: 0, of: nextHour) ?? nextHour
        return PromptBuilder.formatISODate(rounded)
    }
}

public struct ParsedPlan: Codable, Sendable, Equatable {
    public var summary: String
    public var items: [DraftItem]

    enum CodingKeys: String, CodingKey {
        case summary, items, events, reminders, notes
    }

    public var events: [CalendarEventDraft] {
        get {
            items.filter { $0.targetKind == .calendar }.map { $0.asCalendarEventDraft() }
        }
        set {
            let nonCalendar = items.filter { $0.targetKind != .calendar }
            items = newValue.map { DraftItem.fromCalendarEvent($0) } + nonCalendar
        }
    }

    public var reminders: [ReminderDraft] {
        get {
            items.filter { $0.targetKind == .reminder }.map { $0.asReminderDraft() }
        }
        set {
            let calendars = items.filter { $0.targetKind == .calendar }
            let others = items.filter { $0.targetKind != .calendar && $0.targetKind != .reminder }
            items = calendars + newValue.map { DraftItem.fromReminder($0) } + others
        }
    }

    public var alarms: [DraftItem] {
        get {
            items.filter { $0.targetKind == .alarm }
        }
        set {
            let nonAlarms = items.filter { $0.targetKind != .alarm }
            items = nonAlarms + newValue
        }
    }

    public var notes: [KeyNoteDraft] {
        get {
            items.filter { $0.targetKind == .note }.map { $0.asKeyNoteDraft() }
        }
        set {
            let nonNotes = items.filter { $0.targetKind != .note }
            items = nonNotes + newValue.map { DraftItem.fromNote($0) }
        }
    }

    public init(
        summary: String = "",
        items: [DraftItem]
    ) {
        self.summary = summary
        self.items = items
    }

    public init(
        summary: String = "",
        events: [CalendarEventDraft] = [],
        reminders: [ReminderDraft] = [],
        notes: [KeyNoteDraft] = []
    ) {
        self.summary = summary
        var combined: [DraftItem] = []
        for ev in events {
            combined.append(DraftItem.fromCalendarEvent(ev))
            if ev.needsAlarm && !ev.alarmTimeISO.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                combined.append(
                    DraftItem(
                        targetKind: .alarm,
                        title: "早起闹钟：\(ev.title)",
                        startISO: ev.alarmTimeISO,
                        notes: ev.reasonForLeadTime,
                        leadTimeMinutes: [0],
                        priority: 1,
                        needsAlarm: true,
                        alarmTimeISO: ev.alarmTimeISO
                    )
                )
            }
        }
        combined.append(contentsOf: reminders.map { DraftItem.fromReminder($0) })
        combined.append(contentsOf: notes.map { DraftItem.fromNote($0) })
        self.items = combined
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""

        if let decodedItems = try? c.decodeIfPresent([DraftItem].self, forKey: .items),
           !decodedItems.isEmpty {
            self.items = decodedItems
            return
        }

        let decodedEvents = (try? c.decodeIfPresent([CalendarEventDraft].self, forKey: .events)) ?? []
        let decodedReminders = (try? c.decodeIfPresent([ReminderDraft].self, forKey: .reminders)) ?? []
        let decodedNotes = (try? c.decodeIfPresent([KeyNoteDraft].self, forKey: .notes)) ?? []

        var combined: [DraftItem] = []
        for ev in decodedEvents {
            combined.append(DraftItem.fromCalendarEvent(ev))
            if ev.needsAlarm && !ev.alarmTimeISO.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                combined.append(
                    DraftItem(
                        targetKind: .alarm,
                        title: "早起闹钟：\(ev.title)",
                        startISO: ev.alarmTimeISO,
                        notes: ev.reasonForLeadTime,
                        leadTimeMinutes: [0],
                        priority: 1,
                        needsAlarm: true,
                        alarmTimeISO: ev.alarmTimeISO
                    )
                )
            }
        }
        combined.append(contentsOf: decodedReminders.map { DraftItem.fromReminder($0) })
        combined.append(contentsOf: decodedNotes.map { DraftItem.fromNote($0) })
        self.items = combined
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(summary, forKey: .summary)
        try c.encode(items, forKey: .items)
        try c.encode(events, forKey: .events)
        try c.encode(reminders, forKey: .reminders)
        try c.encode(notes, forKey: .notes)
    }

    public static func decode(from rawText: String) throws -> ParsedPlan {
        let candidates = Self.extractBalancedJSONCandidates(from: rawText)
        let decoder = JSONDecoder()

        for candidate in candidates.reversed() {
            if let data = candidate.data(using: .utf8),
               let plan = try? decoder.decode(ParsedPlan.self, from: data),
               (!plan.summary.isEmpty || !plan.items.isEmpty) {
                return plan
            }
        }

        let cleaned = Self.extractJSONObject(from: rawText)
        guard let data = cleaned.data(using: .utf8) else {
            throw NSError(domain: "MemoPilot", code: 1001, userInfo: [NSLocalizedDescriptionKey: "无法将 AI 输出转换为 UTF-8 数据"])
        }
        return try decoder.decode(ParsedPlan.self, from: data)
    }

    public static func extractJSONObject(from text: String) -> String {
        let candidates = extractBalancedJSONCandidates(from: text)
        if let best = candidates.last(where: {
            $0.contains("\"summary\"") || $0.contains("\"events\"") || $0.contains("\"reminders\"") || $0.contains("\"notes\"") || $0.contains("\"items\"")
        }) {
            return best
        }
        if let lastCandidate = candidates.last {
            return lastCandidate
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}"),
           firstBrace <= lastBrace {
            return String(trimmed[firstBrace...lastBrace])
        }
        return trimmed
    }

    private static func extractBalancedJSONCandidates(from text: String) -> [String] {
        var candidates: [String] = []
        var depth = 0
        var inString = false
        var isEscaped = false
        var startIndex: String.Index?

        for idx in text.indices {
            let ch = text[idx]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if ch == "\\" {
                    isEscaped = true
                } else if ch == "\"" {
                    inString = false
                }
                continue
            }
            if ch == "\"" {
                inString = true
            } else if ch == "{" {
                if depth == 0 {
                    startIndex = idx
                }
                depth += 1
            } else if ch == "}" {
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let start = startIndex {
                        candidates.append(String(text[start...idx]))
                        startIndex = nil
                    }
                }
            }
        }
        return candidates
    }

    // MARK: - Unified Draft Item Operations (UUID-Safe)

    public func item(id: UUID) -> DraftItem? {
        items.first(where: { $0.id == id })
    }

    public mutating func toggleItemSelection(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].isSelected.toggle()
    }

    @discardableResult
    public mutating func setItemTargetKind(id: UUID, kind: DraftTargetKind) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }),
              items[idx].targetKind != kind else { return false }

        items[idx].targetKind = kind

        switch kind {
        case .calendar:
            if PromptBuilder.parseISODate(items[idx].startISO) == nil {
                if let alarmDate = PromptBuilder.parseISODate(items[idx].alarmTimeISO) {
                    items[idx].startISO = PromptBuilder.formatISODate(alarmDate)
                } else {
                    items[idx].startISO = DraftItem.defaultUpcomingISO(offsetHours: 1)
                }
            }
            if let sDate = PromptBuilder.parseISODate(items[idx].startISO) {
                if let eDate = PromptBuilder.parseISODate(items[idx].endISO), eDate > sDate {
                    // keep valid endISO
                } else {
                    items[idx].endISO = PromptBuilder.formatISODate(sDate.addingTimeInterval(3600))
                }
            }
            if items[idx].leadTimeMinutes.isEmpty || items[idx].leadTimeMinutes == [0] {
                items[idx].leadTimeMinutes = [30]
            }

        case .reminder:
            if PromptBuilder.parseISODate(items[idx].startISO) == nil {
                if let alarmDate = PromptBuilder.parseISODate(items[idx].alarmTimeISO) {
                    items[idx].startISO = PromptBuilder.formatISODate(alarmDate)
                } else {
                    items[idx].startISO = DraftItem.defaultUpcomingISO(offsetHours: 1)
                }
            }
            if items[idx].leadTimeMinutes.isEmpty {
                items[idx].leadTimeMinutes = [15]
            }

        case .alarm:
            if PromptBuilder.parseISODate(items[idx].startISO) == nil {
                if let alarmDate = PromptBuilder.parseISODate(items[idx].alarmTimeISO) {
                    items[idx].startISO = PromptBuilder.formatISODate(alarmDate)
                } else {
                    items[idx].startISO = DraftItem.defaultUpcomingISO(offsetHours: 1)
                }
            }
            items[idx].alarmTimeISO = items[idx].startISO
            items[idx].needsAlarm = true
            items[idx].priority = 1
            if items[idx].leadTimeMinutes.isEmpty {
                items[idx].leadTimeMinutes = [0]
            }

        case .note:
            if items[idx].category.isEmpty || items[idx].category == "日程" || items[idx].category == "待办" {
                items[idx].category = "备忘"
            }
        }
        return true
    }

    @discardableResult
    public mutating func updateItemTitle(id: UUID, newTitle: String) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }),
              items[idx].title != newTitle else { return false }
        items[idx].title = newTitle
        return true
    }

    @discardableResult
    public mutating func updateItemLocation(id: UUID, newLocation: String) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }),
              items[idx].location != newLocation else { return false }
        items[idx].location = newLocation
        return true
    }

    @discardableResult
    public mutating func updateItemNotes(id: UUID, newNotes: String) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }),
              items[idx].notes != newNotes else { return false }
        items[idx].notes = newNotes
        return true
    }

    @discardableResult
    public mutating func updateItemCategory(id: UUID, newCategory: String) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }),
              items[idx].category != newCategory else { return false }
        items[idx].category = newCategory
        return true
    }

    @discardableResult
    public mutating func updateItemStartDate(id: UUID, newDate: Date) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return false }
        let newISO = PromptBuilder.formatISODate(newDate)
        guard items[idx].startISO != newISO else { return false }

        let oldDuration: TimeInterval
        if let oldStart = PromptBuilder.parseISODate(items[idx].startISO),
           let oldEnd = PromptBuilder.parseISODate(items[idx].endISO),
           oldEnd > oldStart {
            oldDuration = oldEnd.timeIntervalSince(oldStart)
        } else {
            oldDuration = 3600
        }

        items[idx].startISO = newISO
        if items[idx].targetKind == .calendar {
            items[idx].endISO = PromptBuilder.formatISODate(newDate.addingTimeInterval(oldDuration))
        } else if items[idx].targetKind == .alarm {
            items[idx].alarmTimeISO = newISO
        }
        return true
    }

    @discardableResult
    public mutating func updateItemEndDate(id: UUID, newDate: Date) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return false }
        let newISO = PromptBuilder.formatISODate(newDate)
        guard items[idx].endISO != newISO else { return false }
        items[idx].endISO = newISO
        return true
    }

    @discardableResult
    public mutating func updateItemLeadTimes(id: UUID, minutes: [Int]) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }),
              items[idx].leadTimeMinutes != minutes else { return false }
        items[idx].leadTimeMinutes = minutes
        return true
    }

    @discardableResult
    public mutating func toggleItemPriority(id: UUID) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return false }
        items[idx].priority = (items[idx].priority == 1) ? 0 : 1
        return true
    }

    public mutating func deleteItem(id: UUID) {
        items.removeAll { $0.id == id }
    }

    public mutating func addNewDraftItem(kind: DraftTargetKind = .reminder) -> DraftItem {
        let start = DraftItem.defaultUpcomingISO(offsetHours: 1)
        let end = DraftItem.defaultUpcomingISO(offsetHours: 2)
        let newItem = DraftItem(
            targetKind: kind,
            title: kind == .calendar ? "新建日程" : (kind == .alarm ? "新建闹钟" : (kind == .note ? "新建备忘" : "新建待办事项")),
            startISO: kind == .note ? "" : start,
            endISO: kind == .calendar ? end : "",
            location: "",
            notes: "",
            leadTimeMinutes: kind == .calendar ? [30] : (kind == .alarm ? [0] : [15]),
            priority: kind == .alarm ? 1 : 0,
            needsAlarm: kind == .alarm,
            alarmTimeISO: kind == .alarm ? start : "",
            reasonForLeadTime: "",
            category: "备忘"
        )
        items.insert(newItem, at: 0)
        return newItem
    }

    // MARK: - Legacy Compatibility Wrappers

    public func isEventSelected(id: UUID, fallback: Bool) -> Bool {
        items.first(where: { $0.id == id })?.isSelected ?? fallback
    }

    public func isReminderSelected(id: UUID, fallback: Bool) -> Bool {
        items.first(where: { $0.id == id })?.isSelected ?? fallback
    }

    public func isNoteSelected(id: UUID, fallback: Bool) -> Bool {
        items.first(where: { $0.id == id })?.isSelected ?? fallback
    }

    public func eventTitle(id: UUID, fallback: String) -> String {
        items.first(where: { $0.id == id })?.title ?? fallback
    }

    public func reminderTitle(id: UUID, fallback: String) -> String {
        items.first(where: { $0.id == id })?.title ?? fallback
    }

    public func noteTitle(id: UUID, fallback: String) -> String {
        items.first(where: { $0.id == id })?.title ?? fallback
    }

    public mutating func toggleEvent(id: UUID) { toggleItemSelection(id: id) }
    public mutating func toggleReminder(id: UUID) { toggleItemSelection(id: id) }
    public mutating func toggleNote(id: UUID) { toggleItemSelection(id: id) }

    @discardableResult
    public mutating func updateEventTitle(id: UUID, newTitle: String) -> Bool {
        updateItemTitle(id: id, newTitle: newTitle)
    }

    @discardableResult
    public mutating func updateEventLeadTimes(id: UUID, minutes: [Int]) -> Bool {
        updateItemLeadTimes(id: id, minutes: minutes)
    }

    @discardableResult
    public mutating func updateReminderTitle(id: UUID, newTitle: String) -> Bool {
        updateItemTitle(id: id, newTitle: newTitle)
    }

    @discardableResult
    public mutating func updateNoteTitle(id: UUID, newTitle: String) -> Bool {
        updateItemTitle(id: id, newTitle: newTitle)
    }

    public mutating func deleteEvent(id: UUID) { deleteItem(id: id) }
    public mutating func deleteReminder(id: UUID) { deleteItem(id: id) }
    public mutating func deleteNote(id: UUID) { deleteItem(id: id) }
}

public struct CalendarEventDraft: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var isSelected: Bool
    public var title: String
    public var startISO: String
    public var endISO: String
    public var location: String
    public var notes: String
    public var leadTimeMinutes: [Int]
    public var needsAlarm: Bool
    public var alarmTimeISO: String
    public var reasonForLeadTime: String

    enum CodingKeys: String, CodingKey {
        case id, isSelected, title, startISO, endISO, location, notes, leadTimeMinutes, needsAlarm, alarmTimeISO, reasonForLeadTime
    }

    public init(
        id: UUID = UUID(),
        title: String,
        startISO: String,
        endISO: String,
        location: String,
        notes: String,
        leadTimeMinutes: [Int],
        needsAlarm: Bool,
        alarmTimeISO: String,
        reasonForLeadTime: String,
        isSelected: Bool = true
    ) {
        self.id = id
        self.isSelected = isSelected
        self.title = title
        self.startISO = startISO
        self.endISO = endISO
        self.location = location
        self.notes = notes
        self.leadTimeMinutes = leadTimeMinutes
        self.needsAlarm = needsAlarm
        self.alarmTimeISO = alarmTimeISO
        self.reasonForLeadTime = reasonForLeadTime
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.isSelected = (try? c.decodeIfPresent(Bool.self, forKey: .isSelected)) ?? true
        self.title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "未命名日程"
        self.startISO = (try? c.decodeIfPresent(String.self, forKey: .startISO)) ?? ""
        self.endISO = (try? c.decodeIfPresent(String.self, forKey: .endISO)) ?? ""
        self.location = (try? c.decodeIfPresent(String.self, forKey: .location)) ?? ""
        self.notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        self.leadTimeMinutes = (try? c.decodeIfPresent([Int].self, forKey: .leadTimeMinutes)) ?? [30]
        self.needsAlarm = (try? c.decodeIfPresent(Bool.self, forKey: .needsAlarm)) ?? false
        self.alarmTimeISO = (try? c.decodeIfPresent(String.self, forKey: .alarmTimeISO)) ?? ""
        self.reasonForLeadTime = (try? c.decodeIfPresent(String.self, forKey: .reasonForLeadTime)) ?? ""
    }
}

public struct ReminderDraft: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var isSelected: Bool
    public var title: String
    public var dueISO: String
    public var notes: String
    public var priority: Int
    public var leadTimeMinutes: Int

    enum CodingKeys: String, CodingKey {
        case id, isSelected, title, dueISO, notes, priority, leadTimeMinutes
    }

    public init(
        id: UUID = UUID(),
        title: String,
        dueISO: String,
        notes: String,
        priority: Int,
        leadTimeMinutes: Int,
        isSelected: Bool = true
    ) {
        self.id = id
        self.isSelected = isSelected
        self.title = title
        self.dueISO = dueISO
        self.notes = notes
        self.priority = priority
        self.leadTimeMinutes = leadTimeMinutes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.isSelected = (try? c.decodeIfPresent(Bool.self, forKey: .isSelected)) ?? true
        self.title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "未命名待办"
        self.dueISO = (try? c.decodeIfPresent(String.self, forKey: .dueISO)) ?? ""
        self.notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        self.priority = (try? c.decodeIfPresent(Int.self, forKey: .priority)) ?? 0
        self.leadTimeMinutes = (try? c.decodeIfPresent(Int.self, forKey: .leadTimeMinutes)) ?? 0
    }
}

public struct KeyNoteDraft: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var isSelected: Bool
    public var title: String
    public var bodyMarkdown: String
    public var category: String

    enum CodingKeys: String, CodingKey {
        case id, isSelected, title, bodyMarkdown, category
    }

    public init(
        id: UUID = UUID(),
        title: String,
        bodyMarkdown: String,
        category: String,
        isSelected: Bool = true
    ) {
        self.id = id
        self.isSelected = isSelected
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.category = category
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.isSelected = (try? c.decodeIfPresent(Bool.self, forKey: .isSelected)) ?? true
        self.title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "未命名备忘"
        self.bodyMarkdown = (try? c.decodeIfPresent(String.self, forKey: .bodyMarkdown)) ?? ""
        self.category = (try? c.decodeIfPresent(String.self, forKey: .category)) ?? "备忘"
    }
}
