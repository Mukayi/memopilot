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

    @Test("AppleNotesWatcherService tracks processed notes and strips processed markers")
    func appleNotesWatcherStateTracking() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MemoPilotNotesWatchTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let watcher = AppleNotesWatcherService(baseDirectoryURL: tempDir)
        let rawNote = "周四下午4点开产品会\n\(AppleNotesWatcherService.processedMarker)：已生成草稿"
        #expect(AppleNotesWatcherService.normalizeNoteText(rawNote) == "周四下午4点开产品会")
        #expect(watcher.isNoteAlreadyProcessed(noteID: "note-1", plaintext: rawNote) == true)

        let freshNote = "周五晚上7点健身"
        #expect(watcher.isNoteAlreadyProcessed(noteID: "note-2", plaintext: freshNote) == false)
        watcher.recordNoteProcessed(noteID: "note-2", plaintext: freshNote)
        #expect(watcher.isNoteAlreadyProcessed(noteID: "note-2", plaintext: freshNote) == true)
        #expect(watcher.isNoteAlreadyProcessed(noteID: "note-2", plaintext: "周五晚上7点健身（改到8点）") == false)
    }

    @Test("CodexCLIBridge augmentedPATH includes local node bin and proxy helper executes safely")
    func codexBridgePathAndProxyResolution() {
        let path = CodexCLIBridge.augmentedPATH()
        #expect(path.contains(".local/node/bin"))
        _ = CodexCLIBridge.systemProxyEnvironment()
    }

    @Test("Mark individual draft items as committed, separate pending vs committed, and format custom HotKeyBinding")
    func itemLevelCommittedSeparationAndHotKeyFormat() {
        let item1 = DraftItem(targetKind: .calendar, title: "会议1")
        let item2 = DraftItem(targetKind: .reminder, title: "待办2")
        var plan = ParsedPlan(summary: "测试单条写入状态", items: [item1, item2])
        #expect(plan.pendingItems.count == 2)
        #expect(plan.committedItems.count == 0)

        plan.markItemsCommitted([item1.id])
        #expect(plan.pendingItems.count == 1)
        #expect(plan.committedItems.count == 1)
        #expect(plan.committedItems[0].id == item1.id)
        #expect(plan.committedItems[0].isSelected == false)

        let hk = HotKeyBinding(keyCode: 8, carbonModifiers: 2048, isEnabled: true)
        #expect(hk.displayString == "⌥C")
        let disabledHK = HotKeyBinding(keyCode: 8, carbonModifiers: 2048, isEnabled: false)
        #expect(disabledHK.displayString == "已关闭")

        // Editing a committed item automatically resets isCommitted to false and selects it for re-commit
        #expect(plan.updateItemTitle(id: item1.id, newTitle: "会议1（改期）") == true)
        #expect(plan.pendingItems.count == 2)
        #expect(plan.committedItems.count == 0)
        #expect(plan.item(id: item1.id)?.isSelected == true)
    }

    @Test("CodexCLIBridge.buildCodexExecArguments places -- separator before prompt so variadic -i never swallows prompt")
    func codexExecArgumentsSeparatorBeforePrompt() {
        #expect(AISpeedProfile.flash.codexReasoningEffort == "low")
        let argsWithImage = CodexCLIBridge.buildCodexExecArguments(
            tempDirPath: "/tmp/mp",
            schemaPath: "/tmp/mp/schema.json",
            outputPath: "/tmp/mp/output.json",
            imagePath: "/tmp/mp/shot.png",
            prompt: "-带短横线开头的提示词",
            speedProfile: .flash
        )
        #expect(!argsWithImage.contains("--ignore-user-config"))
        #expect(argsWithImage.contains("mcp_servers={}"))
        let imageFlagIndex = argsWithImage.firstIndex(of: "-i")
        let separatorIndex = argsWithImage.firstIndex(of: "--")
        #expect(imageFlagIndex != nil)
        #expect(separatorIndex != nil)
        if let iIdx = imageFlagIndex, let sepIdx = separatorIndex {
            #expect(argsWithImage[iIdx + 1] == "/tmp/mp/shot.png")
            #expect(sepIdx == iIdx + 2)
            #expect(argsWithImage[sepIdx + 1] == "-带短横线开头的提示词")
        }
        #expect(argsWithImage.suffix(2) == ["--", "-带短横线开头的提示词"])
    }

    @Test("WebArticleFetcher extracts WeChat title, account name, data-formula LaTeX, and plain-text arXiv links while stripping massive SVG paths")
    func wechatArticleHTMLFormulaAndLinkExtraction() throws {
        let sampleWeChatHTML = """
        <html>
        <head><meta property="og:title" content="视频模型被压缩器卡住？逐帧出像素"/></head>
        <body>
        <span id="js_name">AIRoobt</span>
        <div id="js_content">
          <p>论文链接：https://arxiv.org/abs/2611.17336</p>
          <p>每帧切成 <span class="inline-equation" data-formula="1 \\times p \\times p"><svg><path d="M213 578L200...HUGE_SVG"></path></svg></span> 的小块。</p>
          <section class="block-equation" data-formula="x_0 = f_\\theta(x_t, t)"><svg><path d="M999..."></path></svg></section>
        </div>
        <script>var tail = 1;</script>
        </body>
        </html>
        """
        let url = URL(string: "https://mp.weixin.qq.com/s/6Bxf7A4oPv1V-UAkHPex0Q?scene=1")!
        let parsed = WebArticleFetcher.parseRawHTML(sampleWeChatHTML, url: url, originalURLString: url.absoluteString)

        #expect(parsed.articleTitle == "视频模型被压缩器卡住？逐帧出像素")
        #expect(parsed.siteOrAccountName == "微信公众号 · AIRoobt")
        #expect(parsed.cleanedBodyText.contains("$1 \\times p \\times p$"))
        #expect(parsed.cleanedBodyText.contains("$$x_0 = f_\\theta(x_t, t)$$"))
        #expect(!parsed.cleanedBodyText.contains("HUGE_SVG"))
        #expect(parsed.detectedExternalURLs.contains("https://arxiv.org/abs/2611.17336"))
        #expect(parsed.detectedArxivIDs == ["2611.17336"])

        // Test URL extraction with trailing Chinese punctuation
        let messyShare = "推荐这篇好文：https://mp.weixin.qq.com/s/6Bxf7A4oPv1V-UAkHPex0Q?scene=1，快看看！"
        #expect(WebArticleFetcher.extractPrimaryURL(from: messyShare) == "https://mp.weixin.qq.com/s/6Bxf7A4oPv1V-UAkHPex0Q?scene=1")
    }

    @Test("PaperDigest decodes partial JSON, derives arXiv PDF link, persists in PaperDigestStore, and exports Obsidian Markdown")
    func paperDigestDecodingStoreAndMarkdownExport() throws {
        let rawLLMJSON = """
        好的，解析如下：
        {
          "paperTitleEN": "Back to Pixels: Lifting Latent Video Diffusion into Pixel Space",
          "paperTitleZH": "回归像素：将潜空间视频扩散抬升至像素空间",
          "shortAlias": "PixVid",
          "paperURL": "https://arxiv.org/abs/2611.17336",
          "codeURL": null,
          "domainTags": ["Video Diffusion", "Pixel-Space"],
          "oneLineConclusion": "控制延迟从 495ms 降至 34ms",
          "methodSteps": ["像素-潜变量对齐矩阵", "干净视频直接预测"]
        }
        """
        let digest = try PaperDigest.decode(from: rawLLMJSON)
        #expect(digest.shortAlias == "PixVid")
        #expect(digest.pdfURL == "https://arxiv.org/pdf/2611.17336")
        #expect(digest.hasOpenSourceCode == false)
        #expect(digest.primaryDisplayTitle.contains("PixVid"))

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MemoPilotPaperTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = PaperDigestStore(baseDirectoryURL: tempDir)
        var rec = PaperDigestRecord(userNotes: "可借鉴 x_0 预测思路", digest: digest)
        rec.isPinned = true
        store.saveAll([rec])

        let loaded = store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].matches(query: "pixvid") == true)
        #expect(loaded[0].matches(query: "495ms") == true)

        let mdDir = tempDir.appendingPathComponent("ExportedMD", isDirectory: true)
        let savedMDPath = try store.writeMarkdownFile(for: rec, directoryURL: mdDir)
        let mdContent = try String(contentsOfFile: savedMDPath, encoding: .utf8)
        #expect(mdContent.contains("paper_url: \"https://arxiv.org/abs/2611.17336\""))
        #expect(mdContent.contains("## 个人批注与思考"))
        #expect(mdContent.contains("可借鉴 x_0 预测思路"))

        // Exporting a second distinct record with the same filename stem appends `-2.md` instead of overwriting
        let rec2 = PaperDigestRecord(createdAt: rec.createdAt, digest: digest)
        let savedMDPath2 = try store.writeMarkdownFile(for: rec2, directoryURL: mdDir)
        #expect(savedMDPath2 != savedMDPath)
        #expect(savedMDPath2.hasSuffix("-2.md"))
    }

    @Test("Edge cases: &amp; query params, balanced URL parens, decimal HTML entities, arxiv/html derivation, and empty JSON rejection")
    func paperDigestAndWebFetcherEdgeCases() throws {
        // 1. &amp; unescaping and balanced parentheses in URLs vs outer wrapping parens
        let ampURL = "https://mp.weixin.qq.com/s?__biz=MzA&amp;mid=123&amp;idx=1"
        #expect(WebArticleFetcher.extractPrimaryURL(from: ampURL) == "https://mp.weixin.qq.com/s?__biz=MzA&mid=123&idx=1")

        let parenInsideURL = "参考文档 https://github.com/org/repo/blob/main/RL_(GRPO).md。"
        #expect(WebArticleFetcher.extractPrimaryURL(from: parenInsideURL) == "https://github.com/org/repo/blob/main/RL_(GRPO).md")

        let outerWrappedURL = "(详见 https://arxiv.org/abs/2501.12948v2)"
        #expect(WebArticleFetcher.extractPrimaryURL(from: outerWrappedURL) == "https://arxiv.org/abs/2501.12948v2")

        // 2. Decimal + hex HTML entities + order-independent meta tag
        let ghHTML = """
        <html><head><meta content="Repo&#8212;Title &#x2014; &amp;amp;" property="og:title"/></head>
        <body><article class="markdown-body"><p>Paper: <a href="/org/repo/blob/main/paper.pdf">PDF</a></p></article></body></html>
        """
        let parsedGH = WebArticleFetcher.parseRawHTML(ghHTML, url: URL(string: "https://github.com/org/repo")!, originalURLString: "https://github.com/org/repo")
        #expect(parsedGH.articleTitle == "Repo—Title — &amp;")
        #expect(parsedGH.detectedExternalURLs.contains("https://github.com/org/repo/blob/main/paper.pdf"))

        // 3. arxiv.org/html/2501.12948v2#S1 derives clean PDF URL without #S1 fragment and deduplicates tags
        let htmlDigest = PaperDigest(
            paperTitleEN: "Test Paper",
            paperURL: "https://arxiv.org/html/2501.12948v2#S1",
            domainTags: ["Diffusion", "diffusion", "RL"],
            oneLineConclusion: "Valid conclusion"
        )
        #expect(htmlDigest.pdfURL == "https://arxiv.org/pdf/2501.12948v2")
        #expect(htmlDigest.domainTags.count == 2)

        // 4. Empty or diagnostic error JSON must throw so .auto mode falls back cleanly
        #expect(throws: Error.self) {
            _ = try PaperDigest.decode(from: "{\"error\": \"rate_limit\"}")
        }
    }
}
