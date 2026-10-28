import Foundation

public enum PromptBuilder {
    public static let outputJSONSchema: String = """
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["summary", "events", "reminders", "notes"],
      "properties": {
        "summary": { "type": "string" },
        "events": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": [
              "title",
              "startISO",
              "endISO",
              "location",
              "notes",
              "leadTimeMinutes",
              "needsAlarm",
              "alarmTimeISO",
              "reasonForLeadTime"
            ],
            "properties": {
              "title": { "type": "string" },
              "startISO": { "type": "string" },
              "endISO": { "type": "string" },
              "location": { "type": "string" },
              "notes": { "type": "string" },
              "leadTimeMinutes": {
                "type": "array",
                "items": { "type": "integer" }
              },
              "needsAlarm": { "type": "boolean" },
              "alarmTimeISO": { "type": "string" },
              "reasonForLeadTime": { "type": "string" }
            }
          }
        },
        "reminders": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["title", "dueISO", "notes", "priority", "leadTimeMinutes"],
            "properties": {
              "title": { "type": "string" },
              "dueISO": { "type": "string" },
              "notes": { "type": "string" },
              "priority": { "type": "integer" },
              "leadTimeMinutes": { "type": "integer" }
            }
          }
        },
        "notes": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["title", "bodyMarkdown", "category"],
            "properties": {
              "title": { "type": "string" },
              "bodyMarkdown": { "type": "string" },
              "category": { "type": "string" }
            }
          }
        }
      }
    }
    """

    public static func buildPrompt(userText: String, hasImage: Bool, now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let nowISO = formatter.string(from: now)

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = Locale(identifier: "zh_CN")
        weekdayFormatter.timeZone = TimeZone.current
        weekdayFormatter.dateFormat = "yyyy年MM月dd日 EEEE HH:mm"
        let nowReadable = weekdayFormatter.string(from: now)

        let imageHint = hasImage
            ? "用户同时提供了一张截图（可能是微信聊天记录、群通知、活动海报、机票/高铁票、取件码或邮件）。请仔细识别图中所有文字与时间信息。"
            : "请分析用户输入的备忘文本。"

        return """
        你是用户的私人 macOS / iOS 日程与信息管家 MemoPilot。
        当前精确时间：\(nowReadable)（ISO: \(nowISO)，时区：\(TimeZone.current.identifier)）。
        \(imageHint)

        请将输入内容拆解为三类结构化动作，并严格按照给定的 JSON Schema 输出纯 JSON（不要输出任何额外解释）：

        1. events（日历日程）：凡是有明确发生时间点的事件（会议、约饭、看病、面试、航班、高铁、课程等）。
           - 若未说明结束时间，普通会议/约饭默认持续 60 分钟。
           - 如果是微信聊天约事，标题尽量整理为清晰易读的格式（如「老张丨国贸丨聊合同」或「产品评审会议」）。
           - 智能判断提前提醒时间 `leadTimeMinutes`（正整数数组，单位为分钟）：
             * 若用户明确说了提前多久提醒，严格按用户说的设置。
             * 航班 / 高铁 / 火车：默认 `[180, 60]`（提前 3 小时与 1 小时）。
             * 线下外出 / 赴约 / 医院挂号 / 面试：默认 `[60, 15]`（提前 1 小时通勤与 15 分钟到场）。
             * 线上会议 / 腾讯会议 / Zoom / 电话沟通：默认 `[15, 5]`（提前 15 分钟与 5 分钟）。
             * 其它常规日程：默认 `[30]`。
           - 若事件发生在清早（05:00-09:30）或者是赶飞机/高铁/重要考试等绝不能错过的事，将 `needsAlarm` 设为 `true`，并在 `alarmTimeISO` 给出建议起床/强提醒的 ISO8601 时间（否则 `needsAlarm` 设为 `false`，`alarmTimeISO` 设为空字符串 `""`）。
           - 在 `reasonForLeadTime` 用简短一句话说明为什么设置该提前量。

        2. reminders（系统提醒事项）：无需占用日历时间块、但需要勾选完成的待办事项（如“交报销单”、“出门带公章”、“取快递 4-2-1028”、“买牛奶”、“回复某人微信”）。
           - `dueISO`：如果有截止或提醒时间则填完整带时区的 ISO8601 字符串，没有明确时间则填 `""`。
           - `priority`：高优/紧急填 `1`，中优填 `5`，普通填 `0`。
           - `leadTimeMinutes`：提前多少分钟提醒（如 `0` 表示准点提醒，`15` 表示提前 15 分钟）。

        3. notes（关键信息归档到备忘录）：如果文本或微信截图里包含值得留存的参考信息（如会议纪要要点、对方发的地址/Wi-Fi/账号、停车位置、长通知摘要、核心待确认问题），整理成结构清晰的 Markdown 放入 `notes`；如果只是单纯的一句话日程且无需额外归档，`notes` 可以为空数组 `[]`。

        用户输入内容：
        \(userText.isEmpty ? "（请直接识别所附图片中的日程、待办与关键信息）" : userText)
        """
    }

    public static func parseISODate(_ isoString: String) -> Date? {
        let trimmed = isoString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: trimmed) { return d }

        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: trimmed) { return d }

        let localFormatter = DateFormatter()
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.timeZone = TimeZone.current
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy/MM/dd HH:mm"
        ]
        for format in formats {
            localFormatter.dateFormat = format
            if let d = localFormatter.date(from: trimmed) { return d }
        }

        // Date-only fallback (defaults to 09:00 local time)
        for dateOnlyFormat in ["yyyy-MM-dd", "yyyy/MM/dd"] {
            localFormatter.dateFormat = dateOnlyFormat
            if let dayStart = localFormatter.date(from: trimmed) {
                return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: dayStart) ?? dayStart
            }
        }
        return nil
    }

    public static func formatISODate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter.string(from: date)
    }

    public static func alarmRelativeOffsets(forLeadTimeMinutes minutes: [Int]) -> [TimeInterval] {
        var seen = Set<Int>()
        var result: [TimeInterval] = []
        for m in minutes {
            let normalized = abs(m)
            if seen.insert(normalized).inserted {
                result.append(-Double(normalized * 60))
            }
        }
        return result
    }

    public static func formatReadableRange(startISO: String, endISO: String) -> String {
        guard let start = parseISODate(startISO) else {
            return startISO
        }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.timeZone = TimeZone.current
        dateFormatter.dateFormat = "M月d日 EEEE HH:mm"
        let startText = dateFormatter.string(from: start)

        guard let end = parseISODate(endISO) else {
            return startText
        }
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "zh_CN")
        timeFormatter.timeZone = TimeZone.current
        if Calendar.current.isDate(start, inSameDayAs: end) {
            timeFormatter.dateFormat = "HH:mm"
        } else {
            timeFormatter.dateFormat = "M月d日 HH:mm"
        }
        return "\(startText) – \(timeFormatter.string(from: end))"
    }

    public static func formatReadableSingleTime(_ isoString: String) -> String {
        guard let date = parseISODate(isoString) else {
            return isoString
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "M月d日 EEEE HH:mm"
        return formatter.string(from: date)
    }

    public static func formatLeadTimeMinutes(_ minutes: Int) -> String {
        let normalized = abs(minutes)
        if normalized == 0 { return "准点" }
        if normalized % 60 == 0 {
            return "提前 \(normalized / 60) 小时"
        } else if normalized > 60 {
            return "提前 \(normalized / 60) 小时 \(normalized % 60) 分"
        } else {
            return "提前 \(normalized) 分钟"
        }
    }
}
