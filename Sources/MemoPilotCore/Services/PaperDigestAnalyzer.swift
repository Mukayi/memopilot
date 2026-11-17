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

        var digest = try await Task.detached(priority: .userInitiated) { () throws -> PaperDigest in
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

            var cursorAttemptError: Error?
            if preferredMode != .openai,
               let cursorBin = CodexCLIBridge.findCursorAgentBinary(),
               let cursorKey = CodexCLIBridge.discoverCursorApiKey() {
                let fullPrompt = prompt + "\n\n请只输出一个合法的 JSON 对象（不要调用任何外部工具，不要用 markdown 代码块包裹，不要任何解释文字），严格包含 schema 定义的全部字段：\n\(outputJSONSchema)"
                do {
                    let output = try CodexCLIBridge.runProcess(
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
                    return try PaperDigest.decode(from: output)
                } catch {
                    cursorAttemptError = error
                    if preferredMode == .cursor {
                        throw error
                    }
                }
            }

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

            let processOut = try CodexCLIBridge.runProcess(
                codexPath,
                arguments: args,
                workingDirectoryURL: tempDir,
                timeout: 90.0
            )
            if FileManager.default.fileExists(atPath: outputURL.path),
               let rawJSON = try? String(contentsOf: outputURL, encoding: .utf8),
               !rawJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return try PaperDigest.decode(from: rawJSON)
            }
            return try PaperDigest.decode(from: processOut)
        }.value

        // Post-process & backfill deterministic links/metadata from fetched page
        if digest.sourceURL.isEmpty { digest.sourceURL = fetched.sourceURL }
        if digest.sourceAccountOrSite.isEmpty { digest.sourceAccountOrSite = fetched.siteOrAccountName }
        if digest.sourceArticleTitle.isEmpty { digest.sourceArticleTitle = fetched.articleTitle }

        if digest.paperURL.isEmpty {
            if let arxivLink = fetched.detectedExternalURLs.first(where: { $0.lowercased().contains("arxiv.org/abs/") || $0.lowercased().contains("openreview.net") }) {
                digest.paperURL = arxivLink
            } else if let firstArxivID = fetched.detectedArxivIDs.first {
                digest.paperURL = "https://arxiv.org/abs/\(firstArxivID)"
            }
        }
        if digest.codeURL.isEmpty {
            let lowerSrc = fetched.sourceURL.lowercased()
            if lowerSrc.contains("github.com/") && !lowerSrc.contains(".github.io") {
                digest.codeURL = fetched.sourceURL
            } else if let ghLink = fetched.detectedExternalURLs.first(where: {
                let l = $0.lowercased()
                let isGitHubNoise = l.contains("/login") || l.contains("/signup") || l.contains("/sponsors") || l.contains("/orgs/") || l.contains("/topics/")
                return !isGitHubNoise && ((l.contains("github.com/") && !l.contains(".github.io")) || l.contains("huggingface.co/"))
            }) {
                digest.codeURL = ghLink
            }
        }
        if digest.projectURL.isEmpty {
            if let projLink = fetched.detectedExternalURLs.first(where: { $0.lowercased().contains(".github.io") }) {
                digest.projectURL = projLink
            }
        }
        digest.normalizeDerivedLinks()
        return digest
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
        5. `venueAndDate`：发表会议/期刊或预印本状态与时间（如 "arXiv:2611.17336 · 2026-11-12 预印本" 或 "ICLR 2026 Oral"）。
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
}
