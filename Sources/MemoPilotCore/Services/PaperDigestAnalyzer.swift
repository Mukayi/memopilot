import Foundation

public enum PaperDigestAnalyzer {
    public static let outputJSONSchema: String = """
    {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "paperTitleEN",
        "paperTitleZH",
        "shortAlias",
        "authorsAndAffiliations",
        "venueAndDate",
        "sourceAccountOrSite",
        "sourceArticleTitle",
        "sourceURL",
        "paperURL",
        "pdfURL",
        "codeURL",
        "projectURL",
        "domainTags",
        "oneLineConclusion",
        "whyItMatters",
        "problemAndBottlenecks",
        "scopeBoundary",
        "methodSteps",
        "keyResults",
        "computeAndTradeoffs",
        "limitations"
      ],
      "properties": {
        "paperTitleEN": { "type": "string" },
        "paperTitleZH": { "type": "string" },
        "shortAlias": { "type": "string" },
        "authorsAndAffiliations": { "type": "string" },
        "venueAndDate": { "type": "string" },
        "sourceAccountOrSite": { "type": "string" },
        "sourceArticleTitle": { "type": "string" },
        "sourceURL": { "type": "string" },
        "paperURL": { "type": "string" },
        "pdfURL": { "type": "string" },
        "codeURL": { "type": "string" },
        "projectURL": { "type": "string" },
        "domainTags": { "type": "array", "items": { "type": "string" } },
        "oneLineConclusion": { "type": "string" },
        "whyItMatters": { "type": "string" },
        "problemAndBottlenecks": { "type": "array", "items": { "type": "string" } },
        "scopeBoundary": { "type": "string" },
        "methodSteps": { "type": "array", "items": { "type": "string" } },
        "keyResults": { "type": "array", "items": { "type": "string" } },
        "computeAndTradeoffs": { "type": "string" },
        "limitations": { "type": "array", "items": { "type": "string" } }
      }
    }
    """

    public static func analyze(
        rawInput: String,
        preferredMode: AIProviderMode = .auto,
        speedProfile: AISpeedProfile = .balanced,
        onStageChange: (@Sendable (String) -> Void)? = nil
    ) async throws -> PaperDigest {
        onStageChange?("🌐 正在抓取网页/公众号正文、还原公式并嗅探论文外链…")
        let fetched = try await WebArticleFetcher.fetchAndClean(from: rawInput)

        let titleHint = fetched.articleTitle.isEmpty ? "正文" : "「\(fetched.articleTitle.prefix(26))」"
        onStageChange?("🧠 已提取\(titleHint)（\(fetched.cleanedBodyText.count) 字），AI 正在深度拆解论文要素…")

        let prompt = buildPaperAnalysisPrompt(fetched: fetched)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoPilot-Paper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let codexPath = CodexCLIBridge.findCodexBinary()
        let codexLoggedIn = CodexCLIBridge.isCodexAuthenticated(codexBinary: codexPath)

        // For deep paper synthesis, prefer at least balanced fast model on Cursor if user left default .flash
        let effectiveModelSlug: String = (speedProfile == .flash)
            ? AISpeedProfile.balanced.cursorModelSlug
            : speedProfile.cursorModelSlug

        var digest: PaperDigest?
        var cursorAttemptError: Error?
        if preferredMode != .openai {
            if let cursorBin = CodexCLIBridge.findCursorAgentBinary(),
               let cursorKey = CodexCLIBridge.discoverCursorApiKey() {
                let fullPrompt = prompt + "\n\n请只输出一个合法的 JSON 对象（不要调用任何外部工具，不要用 markdown 代码块包裹，不要任何解释文字），严格包含 schema 定义的全部字段：\n\(outputJSONSchema)"
                do {
                    let output = try await CodexCLIBridge.runProcessCancellable(
                        cursorBin,
                        arguments: [
                            "--api-key", cursorKey,
                            "--trust",
                            "--workspace", tempDir.path,
                            "--model", effectiveModelSlug,
                            "-p",
                            "--mode", "ask",
                            "--",
                            fullPrompt
                        ],
                        workingDirectoryURL: tempDir,
                        timeout: 75.0
                    )
                    digest = try PaperDigest.decode(from: output)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    UserDefaults.standard.removeObject(forKey: "MemoPilot.cachedCursorApiKey")
                    cursorAttemptError = error
                    if preferredMode == .cursor {
                        throw error
                    }
                }
            } else if preferredMode == .cursor {
                throw NSError(
                    domain: "MemoPilot.PaperAI",
                    code: 401,
                    userInfo: [NSLocalizedDescriptionKey: "当前已固定选择 Cursor 模式，但未检测到已登录的 Cursor Agent。请在右上角切换为自动模式或登录 Cursor。"]
                )
            }
        }

        if digest == nil {
            guard let codexPath else {
                if let cursorAttemptError { throw cursorAttemptError }
                throw NSError(
                    domain: "MemoPilot.PaperAI",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "未检测到可用的 Cursor 连接或 OpenAI Codex CLI。"]
                )
            }

            guard codexLoggedIn else {
                if let cursorAttemptError { throw cursorAttemptError }
                throw NSError(
                    domain: "MemoPilot.PaperAI",
                    code: 401,
                    userInfo: [NSLocalizedDescriptionKey: "尚未登录 OpenAI Codex 账号，请在右上角连接状态菜单中完成登录。"]
                )
            }

            let schemaURL = tempDir.appendingPathComponent("paper_schema.json")
            let outputURL = tempDir.appendingPathComponent("paper_output.json")
            try outputJSONSchema.write(to: schemaURL, atomically: true, encoding: .utf8)

            let args = CodexCLIBridge.buildCodexExecArguments(
                tempDirPath: tempDir.path,
                schemaPath: schemaURL.path,
                outputPath: outputURL.path,
                imagePath: nil,
                prompt: prompt + "\n\n注意：请直接生成最终 JSON，绝不要调用任何 shell 命令或外部工具。",
                speedProfile: speedProfile
            )

            let processOut = try await CodexCLIBridge.runProcessCancellable(
                codexPath,
                arguments: args,
                workingDirectoryURL: tempDir,
                timeout: 90.0
            )
            if FileManager.default.fileExists(atPath: outputURL.path),
               let rawJSON = try? String(contentsOf: outputURL, encoding: .utf8),
               !rawJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                digest = try PaperDigest.decode(from: rawJSON)
            } else {
                digest = try PaperDigest.decode(from: processOut)
            }
        }

        var finalDigest = digest ?? PaperDigest()
        // Post-process & backfill deterministic links/metadata from fetched page
        if finalDigest.sourceURL.isEmpty { finalDigest.sourceURL = fetched.sourceURL }
        if finalDigest.sourceAccountOrSite.isEmpty { finalDigest.sourceAccountOrSite = fetched.siteOrAccountName }
        if finalDigest.sourceArticleTitle.isEmpty { finalDigest.sourceArticleTitle = fetched.articleTitle }

        if finalDigest.paperURL.isEmpty {
            if let arxivLink = fetched.detectedExternalURLs.first(where: { $0.lowercased().contains("arxiv.org/abs/") || $0.lowercased().contains("openreview.net") }) {
                finalDigest.paperURL = arxivLink
            } else if let firstArxivID = fetched.detectedArxivIDs.first {
                finalDigest.paperURL = "https://arxiv.org/abs/\(firstArxivID)"
            }
        }
        if finalDigest.codeURL.isEmpty {
            let lowerSrc = fetched.sourceURL.lowercased()
            if lowerSrc.contains("github.com/") && !lowerSrc.contains(".github.io") {
                finalDigest.codeURL = fetched.sourceURL
            } else if let ghLink = fetched.detectedExternalURLs.first(where: {
                let l = $0.lowercased()
                let isGitHubNoise = l.contains("/login") || l.contains("/signup") || l.contains("/sponsors") || l.contains("/orgs/") || l.contains("/topics/")
                return !isGitHubNoise && ((l.contains("github.com/") && !l.contains(".github.io")) || l.contains("huggingface.co/"))
            }) {
                finalDigest.codeURL = ghLink
            }
        }
        if finalDigest.projectURL.isEmpty {
            if let projLink = fetched.detectedExternalURLs.first(where: { $0.lowercased().contains(".github.io") }) {
                finalDigest.projectURL = projLink
            }
        }
        finalDigest.normalizeDerivedLinks()
        return finalDigest
    }

    public static func buildPaperAnalysisPrompt(fetched: FetchedWebArticle) -> String {
        let linksSection = fetched.detectedExternalURLs.isEmpty
            ? "（未检测到显式外链）"
            : fetched.detectedExternalURLs.joined(separator: "\n")
        let arxivSection = fetched.arxivOfficialMetadata.isEmpty
            ? "（无额外 arXiv API 元数据，请完全依据正文提取）"
            : fetched.arxivOfficialMetadata

        return """
        你是一位顶尖 AI / 计算机系统领域的资深研究员与技术审稿人。
        用户发来了一篇技术推送文章或论文页面，请你剥离一切媒体夸张修辞，精准提炼这篇论文/工程工作最核心的硬核信息。

        【来源站点/公众号】：\(fetched.siteOrAccountName)
        【来源文章标题】：\(fetched.articleTitle)
        【来源链接】：\(fetched.sourceURL)
        【文中检测到的外部链接】：
        \(linksSection)
        【交叉核验的 arXiv 官方元数据（若有）】：
        \(arxivSection)

        【抓取清洗后的正文内容】：
        \(fetched.cleanedBodyText)

        请严格按照以下原则提取并输出 JSON：
        1. `paperTitleEN`：论文或项目的英文原名（若纯中文工作则填原名）。
        2. `paperTitleZH`：准确凝练的中文标题（10~26字）。
        3. `shortAlias`：模型/方法简称（如 PixVid、DeepSeek-V3、FlashAttention-3；若无明确简称填空字符串 ""）。
        4. `authorsAndAffiliations`：核心完成单位与代表作者（如 "Roblox, UC Merced, UPenn, UT Austin（Yanke Song, Xun Huang 等）"）。
        5. `venueAndDate`：精炼的发表会议/期刊或预印本状态（严格控制在 28 字以内，如 "arXiv:2611.17336 · 2026-11-12 预印本" 或 "ICLR 2026 Oral"，不要附加"未提供正式接收信息"等冗长解释）。
        6. `paperURL` / `pdfURL` / `codeURL` / `projectURL`：只填文中或元数据中真实存在的 URL，绝不编造；若未开源则 `codeURL` 填 ""。
        7. `domainTags`：3~5 个精准技术领域标签（如 ["Video Diffusion", "Pixel-Space", "Real-Time World Model"]）。
        8. `oneLineConclusion`：一句话硬核结论（50~110字），必须同时讲清「它改了什么机制」+「换来什么核心量化收益」+「付出了什么代价」。
        9. `whyItMatters`：为什么值得读（60~140字），指出它打破了什么默认惯例，或给出了什么有实验支撑的反常识结论。
        10. `problemAndBottlenecks`：3~4 条要点，直白讲清此前主流做法的具体技术瓶颈（为什么老路子走不通了）。
        11. `scopeBoundary`：结论边界与前提假设（明确本文证明了什么，没有声称解决什么）。
        12. `methodSteps`：3~5 条核心方法机制拆解，按「输入输出变化 → 关键模块 1 → 关键模块 2 → 训练/推理策略」讲透原理，保留关键数学符号（如 x_0 预测、1×p×p patch 等，可直接用简洁文本或 Unicode/LaTeX 表达）。
        13. `keyResults`：3~5 条最具说服力的量化实验与消融证据（必须带具体数字、对比基线和指标名称）。
        14. `computeAndTradeoffs`：算力、显存、吞吐率或工程部署上的真实代价与权衡（若文中未提，请明确指出"文中未披露具体训练/显存开销"）。
        15. `limitations`：3~5 条客观局限性、评测盲区或未来改进方向（站在严格审稿人视角，拒绝报喜不报忧）。
        """
    }

    // MARK: - Multi-Turn Follow-Up Discussion Grounded in Structured Card + Original PDF Full Text

    public static func askFollowUp(
        record: PaperDigestRecord,
        priorHistory: [PaperDiscussionMessage],
        question: String,
        pdfDocument: ExtractedPDFDocument? = nil,
        preferredMode: AIProviderMode = .auto,
        speedProfile: AISpeedProfile = .balanced
    ) async throws -> String {
        let cleanQuestion = question.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty else {
            throw NSError(
                domain: "MemoPilot.PaperChat",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "请输入要讨论的问题"]
            )
        }

        let prompt = buildFollowUpDiscussionPrompt(
            record: record,
            priorHistory: priorHistory,
            question: cleanQuestion,
            pdfDocument: pdfDocument
        )

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoPilot-PaperChat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let codexPath = CodexCLIBridge.findCodexBinary()
        let codexLoggedIn = CodexCLIBridge.isCodexAuthenticated(codexBinary: codexPath)

        let effectiveModelSlug: String = (speedProfile == .flash)
            ? AISpeedProfile.balanced.cursorModelSlug
            : speedProfile.cursorModelSlug

        var cursorAttemptError: Error?
        if preferredMode != .openai {
            if let cursorBin = CodexCLIBridge.findCursorAgentBinary(),
               let cursorKey = CodexCLIBridge.discoverCursorApiKey() {
                do {
                    let output = try await CodexCLIBridge.runProcessCancellable(
                        cursorBin,
                        arguments: [
                            "--api-key", cursorKey,
                            "--trust",
                            "--workspace", tempDir.path,
                            "--model", effectiveModelSlug,
                            "-p",
                            "--mode", "ask",
                            "--",
                            prompt
                        ],
                        workingDirectoryURL: tempDir,
                        timeout: 75.0
                    )
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                    let emptyErr = NSError(
                        domain: "MemoPilot.PaperChat",
                        code: 502,
                        userInfo: [NSLocalizedDescriptionKey: "模型未返回有效回答，请稍后重试。"]
                    )
                    cursorAttemptError = emptyErr
                    if preferredMode == .cursor {
                        throw emptyErr
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    UserDefaults.standard.removeObject(forKey: "MemoPilot.cachedCursorApiKey")
                    cursorAttemptError = error
                    if preferredMode == .cursor {
                        throw error
                    }
                }
            } else if preferredMode == .cursor {
                throw NSError(
                    domain: "MemoPilot.PaperChat",
                    code: 401,
                    userInfo: [NSLocalizedDescriptionKey: "当前已固定选择 Cursor 模式，但未检测到已登录的 Cursor Agent。请在右上角切换为自动模式或登录 Cursor。"]
                )
            }
        }

        guard let codexPath else {
            if let cursorAttemptError { throw cursorAttemptError }
            throw NSError(
                domain: "MemoPilot.PaperChat",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "未检测到可用的 Cursor 连接或 OpenAI Codex CLI。"]
            )
        }

        guard codexLoggedIn else {
            if let cursorAttemptError { throw cursorAttemptError }
            throw NSError(
                domain: "MemoPilot.PaperChat",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "尚未登录 OpenAI Codex 账号，请在右上角连接状态菜单中完成登录。"]
            )
        }

        let outputURL = tempDir.appendingPathComponent("chat_reply.txt")
        let args: [String] = [
            "exec",
            "--ephemeral",
            "-C", tempDir.path,
            "-c", "mcp_servers={}",
            "-c", "model_reasoning_effort=\"\(speedProfile.codexReasoningEffort)\"",
            "--disable", "shell_tool",
            "--disable", "shell_snapshot",
            "--disable", "plugins",
            "--disable", "apps",
            "--disable", "browser_use",
            "--disable", "computer_use",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "-o", outputURL.path,
            "--",
            prompt
        ]

        let processOut = try await CodexCLIBridge.runProcessCancellable(
            codexPath,
            arguments: args,
            workingDirectoryURL: tempDir,
            timeout: 80.0
        )
        let replyText: String
        if FileManager.default.fileExists(atPath: outputURL.path),
           let fileStr = try? String(contentsOf: outputURL, encoding: .utf8),
           !fileStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            replyText = fileStr
        } else {
            replyText = processOut
        }
        let cleanedReply = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedReply.isEmpty else {
            throw NSError(
                domain: "MemoPilot.PaperChat",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "AI 未返回回答内容，请稍后重试。"]
            )
        }
        return cleanedReply
    }

    public static func buildFollowUpDiscussionPrompt(
        record: PaperDigestRecord,
        priorHistory: [PaperDiscussionMessage],
        question: String,
        pdfDocument: ExtractedPDFDocument? = nil
    ) -> String {
        let d = record.digest
        var contextLines: [String] = []
        contextLines.append("论文标题：\(d.primaryDisplayTitle)")
        if !d.paperTitleZH.isEmpty { contextLines.append("中文标题：\(d.paperTitleZH)") }
        if !d.authorsAndAffiliations.isEmpty { contextLines.append("作者与机构：\(d.authorsAndAffiliations)") }
        if !d.venueAndDate.isEmpty { contextLines.append("发表状态：\(d.venueAndDate)") }
        if !d.domainTags.isEmpty { contextLines.append("领域标签：\(d.domainTags.joined(separator: ", "))") }
        if !d.oneLineConclusion.isEmpty { contextLines.append("\n【一句话核心结论】：\n\(d.oneLineConclusion)") }
        if !d.whyItMatters.isEmpty { contextLines.append("\n【为什么值得读】：\n\(d.whyItMatters)") }
        if !d.problemAndBottlenecks.isEmpty {
            contextLines.append("\n【面向的问题与瓶颈】：\n" + d.problemAndBottlenecks.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !d.scopeBoundary.isEmpty { contextLines.append("\n【结论边界与前提】：\n\(d.scopeBoundary)") }
        if !d.methodSteps.isEmpty {
            let steps = d.methodSteps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            contextLines.append("\n【核心方法拆解】：\n\(steps)")
        }
        if !d.keyResults.isEmpty {
            contextLines.append("\n【关键实验与量化证据】：\n" + d.keyResults.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !d.computeAndTradeoffs.isEmpty { contextLines.append("\n【算力与工程代价权衡】：\n\(d.computeAndTradeoffs)") }
        if !d.limitations.isEmpty {
            contextLines.append("\n【局限性与未来方向】：\n" + d.limitations.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !record.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contextLines.append("\n【用户的个人批注】：\n\(record.userNotes)")
        }

        let pdfExcerptsSection: String
        let groundingRule: String
        if let pdfDocument, !pdfDocument.pages.isEmpty {
            let selected = PaperPDFService.selectRelevantPDFContext(
                from: pdfDocument,
                question: question,
                priorHistory: priorHistory,
                maxBudgetChars: 64_000
            )
            pdfExcerptsSection = """

            ================ 原始论文 PDF 原文节选（共 \(pdfDocument.pageCount) 页） ================
            \(selected)
            """
            groundingRule = """
            1. 请同时结合下方的【论文结构化卡片】与【原始论文 PDF 原文节选】（及【历史对话】）深入作答，绝不要调用任何外部工具或联网命令。
            2. 当回答涉及原论文的具体公式细节、超参数设置、网络结构、实验表格数据或附录说明时，请优先从【原始论文 PDF 原文节选】中提取精确数值与定义，并在句末自然标注出处（如「（见 PDF 第 5 页 / Table 2）」）。
            3. 若某个实现细节既不在结构化卡片也不在整份原始 PDF 中（例如作者未开源披露的工程参数），请明确说明「原论文未披露该具体参数」，并给出有理有据的技术推演（绝不捏造实验数字）。
            """
        } else {
            pdfExcerptsSection = "\n================ 原始论文 PDF 原文 ================\n（当前记录暂未挂载原始 PDF 全文，仅基于结构化卡片作答）"
            groundingRule = """
            1. 直接基于下方的【论文结构化卡片】（及【历史对话】）作答，绝不要调用任何外部工具或联网命令。
            2. 若用户追问的超细枝末节未包含在当前结构化卡片中，请诚实说明「当前结构化卡片未包含该具体细节（可在讨论栏挂载原论文 PDF 以检索全文）」，并基于现有机制给出严谨的技术推演（绝不编造实验数字）。
            """
        }

        let recentTurns = priorHistory.suffix(10)
        let historyText: String
        if recentTurns.isEmpty {
            historyText = "（当前为第一轮提问）"
        } else {
            historyText = recentTurns.map { turn in
                let speaker = (turn.role == .user) ? "用户" : "助手"
                return "[\(speaker)]：\(turn.content)"
            }.joined(separator: "\n\n")
        }

        return """
        你是用户的资深学术科研搭档与论文审稿助手。用户正在研读下方这篇工作，并希望围绕论文的方法机制、数学推导、实验设置与局限性继续深入讨论。

        请严格遵守以下回答原则：
        \(groundingRule)
        4. 结论先行、逻辑锋利、言之有物，避免空泛客套话。
        5. 排版清爽易读：可使用简短分段、`• ` 要点列表和 `**加粗**` 突出核心结论；数学符号请直接使用易读纯文本/Unicode（如 x_0、v、σ、1×p×p、→、≈），不要使用 `\\(...\\)` 或 `\\[...\\]` 反斜杠包裹，也不要输出 `#` 一二级大标题。

        ================ 论文结构化卡片 ================
        \(contextLines.joined(separator: "\n"))
        \(pdfExcerptsSection)

        ================ 历史讨论上下文 ================
        \(historyText)

        ================ 用户当前提问 ================
        \(question)
        """
    }
}
