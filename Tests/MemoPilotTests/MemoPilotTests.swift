import Testing
import Foundation
@testable import MemoPilotCore

@Suite("MemoPilotCore Tests")
struct MemoPilotTests {
    @Test("Decode ParsedPlan from strict AI JSON output")
    func decodeParsedPlan() throws {
        let sampleJSON = """
        {
          "summary": "安排明天下午国贸合同会议并提醒带公章",
          "events": [
            {
              "title": "老张丨国贸丨聊合同",
              "startISO": "2026-10-28T15:00:00+08:00",
              "endISO": "2026-10-28T16:00:00+08:00",
              "location": "国贸三期",
              "notes": "讨论年度合同条款",
              "leadTimeMinutes": [60, 15],
              "needsAlarm": false,
              "alarmTimeISO": "",
              "reasonForLeadTime": "线下外出会议，提前60分钟出发、15分钟到场"
            }
          ],
          "reminders": [
            {
              "title": "出门带公司公章",
              "dueISO": "2026-10-28T13:30:00+08:00",
              "notes": "去国贸见老张用",
              "priority": 1,
              "leadTimeMinutes": 15
            }
          ],
          "notes": [
            {
              "title": "合同谈判关键点",
              "bodyMarkdown": "- 付款周期争取季付\\n- 违约金上限 10%",
              "category": "工作备忘"
            }
          ]
        }
        """
        let plan = try ParsedPlan.decode(from: sampleJSON)
        #expect(plan.events.count == 1)
        #expect(plan.events[0].leadTimeMinutes == [60, 15])
        #expect(plan.reminders.count == 1)
        #expect(plan.reminders[0].priority == 1)
        #expect(plan.notes.count == 1)
    }

    @Test("Extract JSON safely when braces are inverted, nested in reasoning text, or contain null fields")
    func resilientJSONExtractionAndDecoding() throws {
        // 1. Inverted braces "} ... {" must never trap with Range lowerBound > upperBound
        let inverted = "} error before brace {"
        let extractedInverted = ParsedPlan.extractJSONObject(from: inverted)
        #expect(!extractedInverted.isEmpty)

        // 2. LLM reasoning text with {braces} before and after actual JSON object, plus null optional fields
        let noisyLLMOutput = """
        好的，我将按照 {summary, events, reminders, notes} 结构为您拆解：
        ```json
        {
          "summary": "包含花括号 {测试} 的日程",
          "events": [
            {
              "title": "测试会议 {A组}",
              "startISO": "2026-10-29 10:00",
              "endISO": null,
              "location": null
            }
          ],
          "reminders": null
        }
        ```
        以上即为 {JSON} 结果。
        """
        let plan = try ParsedPlan.decode(from: noisyLLMOutput)
        #expect(plan.summary == "包含花括号 {测试} 的日程")
        #expect(plan.events.count == 1)
        #expect(plan.events[0].title == "测试会议 {A组}")
        #expect(plan.events[0].leadTimeMinutes == [30])
        #expect(plan.reminders.isEmpty)
        #expect(plan.notes.isEmpty)
    }

    @Test("Parse diverse ISO8601/local date formats and normalize negative/duplicate EKAlarm offsets")
    func parseISOAndOffsets() throws {
        #expect(PromptBuilder.parseISODate("2026-10-28T15:00:00+08:00") != nil)
        #expect(PromptBuilder.parseISODate("2026-10-28T15:00:00.000") != nil)
        #expect(PromptBuilder.parseISODate("2026-10-28 15:00:00") != nil)
        #expect(PromptBuilder.parseISODate("2026/10/28 15:00") != nil)
        #expect(PromptBuilder.parseISODate("2026-10-28") != nil)

        // Negative or duplicate lead times must be normalized and deduplicated
        let offsets = PromptBuilder.alarmRelativeOffsets(forLeadTimeMinutes: [-60, 60, 15, 0])
        #expect(offsets == [-3600.0, -900.0, 0.0])
        #expect(PromptBuilder.formatLeadTimeMinutes(-180) == "提前 3 小时")
        #expect(PromptBuilder.formatLeadTimeMinutes(15) == "提前 15 分钟")

        let rangeStr = PromptBuilder.formatReadableRange(
            startISO: "2026-10-28T15:00:00+08:00",
            endISO: "2026-10-28T16:30:00+08:00"
        )
        #expect(rangeStr.contains("10月28日"))
        #expect(rangeStr.contains("15:00 – 16:30"))
    }

    @Test("Persist, recover from partial corruption, and back up corrupted HistoryStore")
    func historyStorePersistenceAndResilience() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MemoPilotHistoryTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = HistoryStore(baseDirectoryURL: tempDir)
        let plan = ParsedPlan(
            summary: "测试历史记录归档",
            events: [],
            reminders: [
                ReminderDraft(
                    title: "取件码 9-1-2046",
                    dueISO: "2026-10-28T18:00:00+08:00",
                    notes: "顺丰快递",
                    priority: 1,
                    leadTimeMinutes: 15
                )
            ],
            notes: []
        )
        let record = HistoryRecord(
            rawInputText: "顺丰快递取件码 9-1-2046",
            plan: plan,
            isCommitted: true
        )
        store.saveAll([record])

        let loaded = store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].displayTitle == "测试历史记录归档")
        #expect(loaded[0].matches(query: "2046") == true)
        #expect(loaded[0].matches(query: "不存在的词") == false)

        // Write completely corrupted JSON and verify backup file is created
        try "NOT_VALID_JSON{{{".data(using: .utf8)!.write(to: store.storageURL)
        let recovered = store.loadAll()
        #expect(recovered.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        #expect(files.contains(where: { $0.hasPrefix("history.backup-") }))
    }

    @Test("Safe UUID-based lookup, idempotent title update, and deletion on ParsedPlan never traps")
    func safePlanItemDeletionAndLookup() throws {
        let ev1 = CalendarEventDraft(
            title: "日程1",
            startISO: "2026-10-28T15:00:00+08:00",
            endISO: "2026-10-28T16:00:00+08:00",
            location: "",
            notes: "",
            leadTimeMinutes: [30],
            needsAlarm: false,
            alarmTimeISO: "",
            reasonForLeadTime: ""
        )
        let ev2 = CalendarEventDraft(
            title: "日程2",
            startISO: "2026-10-29T07:30:00+08:00",
            endISO: "2026-10-29T09:30:00+08:00",
            location: "",
            notes: "",
            leadTimeMinutes: [180],
            needsAlarm: true,
            alarmTimeISO: "",
            reasonForLeadTime: ""
        )
        let note1 = KeyNoteDraft(title: "备忘1", bodyMarkdown: "内容", category: "工作")
        var plan = ParsedPlan(summary: "测试", events: [ev1, ev2], reminders: [], notes: [note1])

        // Updating with identical title returns false (prevents view teardown publish loop)
        #expect(plan.updateEventTitle(id: ev1.id, newTitle: "日程1") == false)
        #expect(plan.updateEventTitle(id: ev1.id, newTitle: "日程1-修改") == true)

        // Delete ev2 and note1
        plan.deleteEvent(id: ev2.id)
        plan.deleteNote(id: note1.id)

        // Stale SwiftUI Binding getters querying deleted ev2.id or note1.id must safely return fallback instead of trapping
        #expect(plan.eventTitle(id: ev2.id, fallback: ev2.title) == "日程2")
        #expect(plan.noteTitle(id: note1.id, fallback: note1.title) == "备忘1")
        #expect(plan.isEventSelected(id: ev2.id, fallback: false) == false)
        #expect(plan.isNoteSelected(id: note1.id, fallback: false) == false)

        // Updating a deleted item ID must return false and be a safe no-op
        #expect(plan.updateEventTitle(id: ev2.id, newTitle: "不应崩溃") == false)
        #expect(plan.events.count == 1)
        #expect(plan.events[0].title == "日程1-修改")
    }

    @Test("Switch draft item target between Calendar, Reminder, Alarm, and Note in-place and edit details")
    func switchDraftTargetAndEditDetails() throws {
        let rem = ReminderDraft(
            title: "明早去机场赶飞机",
            dueISO: "2026-10-29T06:30:00+08:00",
            notes: "首都机场 T2",
            priority: 0,
            leadTimeMinutes: 15
        )
        var plan = ParsedPlan(summary: "测试切换类型", events: [], reminders: [rem], notes: [])
        #expect(plan.items.count == 1)
        #expect(plan.reminders.count == 1)
        #expect(plan.alarms.count == 0)

        // Switch from Reminder (.reminder) to Alarm (.alarm)
        #expect(plan.setItemTargetKind(id: rem.id, kind: .alarm) == true)
        #expect(plan.reminders.count == 0)
        #expect(plan.alarms.count == 1)
        #expect(plan.alarms[0].priority == 1)

        // Switch from Alarm (.alarm) to Calendar (.calendar)
        #expect(plan.setItemTargetKind(id: rem.id, kind: .calendar) == true)
        #expect(plan.alarms.count == 0)
        #expect(plan.events.count == 1)
        #expect(!plan.events[0].endISO.isEmpty)

        // Edit location, notes, and lead times
        #expect(plan.updateItemLocation(id: rem.id, newLocation: "T2 航站楼值机柜台") == true)
        #expect(plan.updateItemLeadTimes(id: rem.id, minutes: [180, 60]) == true)
        #expect(plan.events[0].location == "T2 航站楼值机柜台")
        #expect(plan.events[0].leadTimeMinutes == [180, 60])
    }
}
