import Foundation

public enum PaperDigestFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "全部"
    case starred = "星标"
    case hasCode = "含代码"
    case syncedNotes = "已存备忘"

    public var id: String { rawValue }
}

public struct PaperDigest: Codable, Equatable, Sendable {
    public var paperTitleEN: String
    public var paperTitleZH: String
    public var shortAlias: String
    public var authorsAndAffiliations: String
    public var venueAndDate: String
    public var sourceAccountOrSite: String
    public var sourceArticleTitle: String
    public var sourceURL: String
    public var paperURL: String
    public var pdfURL: String
    public var codeURL: String
    public var projectURL: String
    public var domainTags: [String]
    public var oneLineConclusion: String
    public var whyItMatters: String
    public var problemAndBottlenecks: [String]
    public var scopeBoundary: String
    public var methodSteps: [String]
    public var keyResults: [String]
    public var computeAndTradeoffs: String
    public var limitations: [String]

    public init(
        paperTitleEN: String = "",
        paperTitleZH: String = "",
        shortAlias: String = "",
        authorsAndAffiliations: String = "",
        venueAndDate: String = "",
        sourceAccountOrSite: String = "",
        sourceArticleTitle: String = "",
        sourceURL: String = "",
        paperURL: String = "",
        pdfURL: String = "",
        codeURL: String = "",
        projectURL: String = "",
        domainTags: [String] = [],
        oneLineConclusion: String = "",
        whyItMatters: String = "",
        problemAndBottlenecks: [String] = [],
        scopeBoundary: String = "",
        methodSteps: [String] = [],
        keyResults: [String] = [],
        computeAndTradeoffs: String = "",
        limitations: [String] = []
    ) {
        self.paperTitleEN = paperTitleEN
        self.paperTitleZH = paperTitleZH
        self.shortAlias = shortAlias
        self.authorsAndAffiliations = authorsAndAffiliations
        self.venueAndDate = venueAndDate
        self.sourceAccountOrSite = sourceAccountOrSite
        self.sourceArticleTitle = sourceArticleTitle
        self.sourceURL = sourceURL
        self.paperURL = paperURL
        self.pdfURL = pdfURL
        self.codeURL = codeURL
        self.projectURL = projectURL
        self.domainTags = domainTags
        self.oneLineConclusion = oneLineConclusion
        self.whyItMatters = whyItMatters
        self.problemAndBottlenecks = problemAndBottlenecks
        self.scopeBoundary = scopeBoundary
        self.methodSteps = methodSteps
        self.keyResults = keyResults
        self.computeAndTradeoffs = computeAndTradeoffs
        self.limitations = limitations
        normalizeDerivedLinks()
    }

    private enum CodingKeys: String, CodingKey {
        case paperTitleEN
        case paperTitleZH
        case shortAlias
        case authorsAndAffiliations
        case venueAndDate
        case sourceAccountOrSite
        case sourceArticleTitle
        case sourceURL
        case paperURL
        case pdfURL
        case codeURL
        case projectURL
        case domainTags
        case oneLineConclusion
        case whyItMatters
        case problemAndBottlenecks
        case scopeBoundary
        case methodSteps
        case keyResults
        case computeAndTradeoffs
        case limitations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paperTitleEN = Self.decodeStr(c, .paperTitleEN)
        paperTitleZH = Self.decodeStr(c, .paperTitleZH)
        shortAlias = Self.decodeStr(c, .shortAlias)
        authorsAndAffiliations = Self.decodeStr(c, .authorsAndAffiliations)
        venueAndDate = Self.decodeStr(c, .venueAndDate)
        sourceAccountOrSite = Self.decodeStr(c, .sourceAccountOrSite)
        sourceArticleTitle = Self.decodeStr(c, .sourceArticleTitle)
        sourceURL = Self.decodeStr(c, .sourceURL)
        paperURL = Self.decodeStr(c, .paperURL)
        pdfURL = Self.decodeStr(c, .pdfURL)
        codeURL = Self.decodeStr(c, .codeURL)
        projectURL = Self.decodeStr(c, .projectURL)
        domainTags = Self.decodeStrList(c, .domainTags)
        oneLineConclusion = Self.decodeStr(c, .oneLineConclusion)
        whyItMatters = Self.decodeStr(c, .whyItMatters)
        problemAndBottlenecks = Self.decodeStrList(c, .problemAndBottlenecks)
        scopeBoundary = Self.decodeStr(c, .scopeBoundary)
        methodSteps = Self.decodeStrList(c, .methodSteps)
        keyResults = Self.decodeStrList(c, .keyResults)
        computeAndTradeoffs = Self.decodeStr(c, .computeAndTradeoffs)
        limitations = Self.decodeStrList(c, .limitations)
        normalizeDerivedLinks()
    }

    private static func decodeStr(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String {
        ((try? c.decodeIfPresent(String.self, forKey: key)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeStrList(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [String] {
        if let arr = try? c.decodeIfPresent([String].self, forKey: key) {
            return arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let single = try? c.decodeIfPresent(String.self, forKey: key) {
            return single
                .components(separatedBy: CharacterSet.newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    public mutating func normalizeDerivedLinks() {
        // Deduplicate domain tags while preserving order
        var seenTags = Set<String>()
        domainTags = domainTags.filter { tag in
            let key = tag.lowercased()
            if seenTags.contains(key) { return false }
            seenTags.insert(key)
            return true
        }

        // Extract arXiv ID from paperURL or pdfURL (handles /abs/, /pdf/, /html/ and strips #fragment or ?query)
        let combinedArxivSource = !paperURL.isEmpty ? paperURL : pdfURL
        if combinedArxivSource.lowercased().contains("arxiv.org/"),
           let regex = try? NSRegularExpression(pattern: #"arxiv\.org/(?:abs|pdf|html)/([A-Za-z\-]+/\d{7}|\d{4}\.\d{4,5}(?:v\d+)?)"#, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: combinedArxivSource, range: NSRange(combinedArxivSource.startIndex..., in: combinedArxivSource)),
           match.numberOfRanges > 1,
           let idRange = Range(match.range(at: 1), in: combinedArxivSource) {
            let arxivID = String(combinedArxivSource[idRange])
            if paperURL.isEmpty || paperURL.lowercased().contains("arxiv.org/pdf/") {
                paperURL = "https://arxiv.org/abs/\(arxivID)"
            }
            if pdfURL.isEmpty {
                pdfURL = "https://arxiv.org/pdf/\(arxivID)"
            }
        }
    }

    public var primaryDisplayTitle: String {
        if !paperTitleEN.isEmpty {
            if !shortAlias.isEmpty && !paperTitleEN.localizedCaseInsensitiveContains(shortAlias) {
                return "\(shortAlias): \(paperTitleEN)"
            }
            return paperTitleEN
        }
        if !paperTitleZH.isEmpty { return paperTitleZH }
        if !sourceArticleTitle.isEmpty { return sourceArticleTitle }
        return "未命名论文解析"
    }

    public var hasOpenSourceCode: Bool {
        !codeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var compactVenueBadgeText: String {
        var s = venueAndDate.trimmingCharacters(in: .whitespacesAndNewlines)
        for noiseMarker in ["，未提供", "，文中未", "，尚未", "（未提供", "（文中未", "(未提供"] {
            if let r = s.range(of: noiseMarker) {
                s = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return s
    }

    public static func extractPaperJSONObject(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        var candidates: [String] = []
        var depth = 0
        var inString = false
        var isEscaped = false
        var startIdx: String.Index?

        var idx = trimmed.startIndex
        while idx < trimmed.endIndex {
            let ch = trimmed[idx]
            if isEscaped {
                isEscaped = false
            } else if ch == "\\" && inString {
                isEscaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" {
                    if depth == 0 { startIdx = idx }
                    depth += 1
                } else if ch == "}" && depth > 0 {
                    depth -= 1
                    if depth == 0, let s = startIdx {
                        candidates.append(String(trimmed[s...idx]))
                        startIdx = nil
                    }
                }
            }
            idx = trimmed.index(after: idx)
        }

        for candidate in candidates.reversed() {
            if let data = candidate.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               (obj["paperTitleEN"] != nil || obj["oneLineConclusion"] != nil || obj["methodSteps"] != nil) {
                return candidate
            }
        }
        return ParsedPlan.extractJSONObject(from: raw)
    }

    public static func decode(from rawOutput: String) throws -> PaperDigest {
        let jsonString = extractPaperJSONObject(from: rawOutput)
        guard let data = jsonString.data(using: .utf8) else {
            throw NSError(
                domain: "MemoPilot.PaperDigest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法将 AI 输出转换为 UTF-8 数据"]
            )
        }
        let decoded = try JSONDecoder().decode(PaperDigest.self, from: data)
        if decoded.paperTitleEN.isEmpty
            && decoded.paperTitleZH.isEmpty
            && decoded.oneLineConclusion.isEmpty
            && decoded.methodSteps.isEmpty {
            throw NSError(
                domain: "MemoPilot.PaperDigest",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "AI 未返回有效的论文结构化字段，请重试或切换 AI 通道。"]
            )
        }
        return decoded
    }
}

public struct PaperDiscussionMessage: Codable, Identifiable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    public var id: UUID
    public var role: Role
    public var content: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

public struct PaperDigestRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var isPinned: Bool
    public var isArchivedToNotes: Bool
    public var appleNoteExternalID: String?
    public var exportedMarkdownPath: String?
    public var cachedPDFPath: String?
    public var cachedPDFPageCount: Int?
    public var userNotes: String
    public var discussionMessages: [PaperDiscussionMessage]
    public var digest: PaperDigest

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isPinned: Bool = false,
        isArchivedToNotes: Bool = false,
        appleNoteExternalID: String? = nil,
        exportedMarkdownPath: String? = nil,
        cachedPDFPath: String? = nil,
        cachedPDFPageCount: Int? = nil,
        userNotes: String = "",
        discussionMessages: [PaperDiscussionMessage] = [],
        digest: PaperDigest
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.isArchivedToNotes = isArchivedToNotes
        self.appleNoteExternalID = appleNoteExternalID
        self.exportedMarkdownPath = exportedMarkdownPath
        self.cachedPDFPath = cachedPDFPath
        self.cachedPDFPageCount = cachedPDFPageCount
        self.userNotes = userNotes
        self.discussionMessages = discussionMessages
        self.digest = digest
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? createdAt
        isPinned = (try? c.decodeIfPresent(Bool.self, forKey: .isPinned)) ?? false
        isArchivedToNotes = (try? c.decodeIfPresent(Bool.self, forKey: .isArchivedToNotes)) ?? false
        appleNoteExternalID = try? c.decodeIfPresent(String.self, forKey: .appleNoteExternalID)
        exportedMarkdownPath = try? c.decodeIfPresent(String.self, forKey: .exportedMarkdownPath)
        cachedPDFPath = try? c.decodeIfPresent(String.self, forKey: .cachedPDFPath)
        cachedPDFPageCount = try? c.decodeIfPresent(Int.self, forKey: .cachedPDFPageCount)
        userNotes = (try? c.decodeIfPresent(String.self, forKey: .userNotes)) ?? ""
        discussionMessages = (try? c.decodeIfPresent([PaperDiscussionMessage].self, forKey: .discussionMessages)) ?? []
        digest = (try? c.decodeIfPresent(PaperDigest.self, forKey: .digest)) ?? PaperDigest()
    }

    public var sidebarTitle: String {
        if !digest.shortAlias.isEmpty && !digest.paperTitleZH.isEmpty {
            return "\(digest.shortAlias)｜\(digest.paperTitleZH)"
        }
        if !digest.paperTitleZH.isEmpty { return digest.paperTitleZH }
        if !digest.paperTitleEN.isEmpty { return digest.paperTitleEN }
        if !digest.sourceArticleTitle.isEmpty { return digest.sourceArticleTitle }
        return "论文/推送解析"
    }

    public func matches(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return true }
        let fields: [String] = [
            digest.paperTitleEN,
            digest.paperTitleZH,
            digest.shortAlias,
            digest.authorsAndAffiliations,
            digest.venueAndDate,
            digest.sourceAccountOrSite,
            digest.sourceArticleTitle,
            digest.sourceURL,
            digest.paperURL,
            digest.codeURL,
            digest.oneLineConclusion,
            digest.whyItMatters,
            digest.scopeBoundary,
            digest.computeAndTradeoffs,
            userNotes
        ] + digest.domainTags + digest.problemAndBottlenecks + digest.methodSteps + digest.keyResults + digest.limitations + discussionMessages.map(\.content)

        return fields.contains { $0.lowercased().contains(trimmed) }
    }

    public func suggestedMarkdownFilename() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let datePrefix = df.string(from: createdAt)
        let rawName = !digest.shortAlias.isEmpty
            ? "\(digest.shortAlias)-\(digest.paperTitleZH.isEmpty ? digest.paperTitleEN : digest.paperTitleZH)"
            : (!digest.paperTitleZH.isEmpty ? digest.paperTitleZH : digest.primaryDisplayTitle)

        let invalidChars = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = rawName
            .components(separatedBy: invalidChars)
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let truncated = String(cleaned.prefix(56)).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(datePrefix)-\(truncated.isEmpty ? "论文解析" : truncated).md"
    }

    private static func escapeYAML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    public func toMarkdown(includeFrontmatter: Bool = true) -> String {
        var lines: [String] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"

        if includeFrontmatter {
            lines.append("---")
            lines.append("title: \"\(Self.escapeYAML(digest.primaryDisplayTitle))\"")
            if !digest.shortAlias.isEmpty {
                lines.append("alias: \"\(Self.escapeYAML(digest.shortAlias))\"")
            }
            lines.append("date: \(df.string(from: createdAt))")
            if !digest.sourceURL.isEmpty { lines.append("source_url: \"\(Self.escapeYAML(digest.sourceURL))\"") }
            if !digest.paperURL.isEmpty { lines.append("paper_url: \"\(Self.escapeYAML(digest.paperURL))\"") }
            if !digest.codeURL.isEmpty { lines.append("code_url: \"\(Self.escapeYAML(digest.codeURL))\"") }
            if !digest.domainTags.isEmpty {
                let tagList = digest.domainTags.map { "\"\(Self.escapeYAML($0))\"" }.joined(separator: ", ")
                lines.append("tags: [\(tagList)]")
            }
            lines.append("---")
            lines.append("")
        }

        lines.append("# \(digest.primaryDisplayTitle)")
        if !digest.paperTitleZH.isEmpty && digest.paperTitleZH != digest.primaryDisplayTitle {
            lines.append("> **中文标题**：\(digest.paperTitleZH)")
        }
        lines.append("")

        // Metadata Block
        lines.append("## 基本信息")
        if !digest.authorsAndAffiliations.isEmpty {
            lines.append("- **作者与机构**：\(digest.authorsAndAffiliations)")
        }
        if !digest.venueAndDate.isEmpty {
            lines.append("- **发表状态**：\(digest.venueAndDate)")
        }
        if !digest.sourceAccountOrSite.isEmpty || !digest.sourceArticleTitle.isEmpty {
            let srcLabel = [digest.sourceAccountOrSite, digest.sourceArticleTitle]
                .filter { !$0.isEmpty }
                .joined(separator: "｜")
                .replacingOccurrences(of: "[", with: "【")
                .replacingOccurrences(of: "]", with: "】")
            if !digest.sourceURL.isEmpty {
                lines.append("- **推送来源**：[\(srcLabel)](\(digest.sourceURL))")
            } else {
                lines.append("- **推送来源**：\(srcLabel)")
            }
        }
        if !digest.paperURL.isEmpty {
            lines.append("- **论文链接**：[\(digest.paperURL)](\(digest.paperURL))")
        }
        if !digest.pdfURL.isEmpty {
            lines.append("- **PDF 直达**：[\(digest.pdfURL)](\(digest.pdfURL))")
        }
        if !digest.codeURL.isEmpty {
            lines.append("- **开源代码**：[\(digest.codeURL)](\(digest.codeURL))")
        } else {
            lines.append("- **开源代码**：暂未开源 / 文中未提及")
        }
        if !digest.projectURL.isEmpty {
            lines.append("- **项目主页**：[\(digest.projectURL)](\(digest.projectURL))")
        }
        if !digest.domainTags.isEmpty {
            lines.append("- **领域标签**：" + digest.domainTags.map { "`\($0)`" }.joined(separator: " "))
        }
        lines.append("")

        // One-line conclusion & Why it matters
        if !digest.oneLineConclusion.isEmpty {
            lines.append("## 一句话结论")
            lines.append(digest.oneLineConclusion)
            lines.append("")
        }

        if !digest.whyItMatters.isEmpty {
            lines.append("## 为什么值得读")
            lines.append(digest.whyItMatters)
            lines.append("")
        }

        // Problem & Boundary
        if !digest.problemAndBottlenecks.isEmpty || !digest.scopeBoundary.isEmpty {
            lines.append("## 面向的问题与结论边界")
            for item in digest.problemAndBottlenecks {
                lines.append("- \(item)")
            }
            if !digest.scopeBoundary.isEmpty {
                lines.append("- **范围与边界**：\(digest.scopeBoundary)")
            }
            lines.append("")
        }

        // Method
        if !digest.methodSteps.isEmpty {
            lines.append("## 核心方法拆解")
            for (idx, step) in digest.methodSteps.enumerated() {
                lines.append("\(idx + 1). \(step)")
            }
            lines.append("")
        }

        // Key Results & Trade-offs
        if !digest.keyResults.isEmpty || !digest.computeAndTradeoffs.isEmpty {
            lines.append("## 关键实验结果与代价权衡")
            for res in digest.keyResults {
                lines.append("- \(res)")
            }
            if !digest.computeAndTradeoffs.isEmpty {
                lines.append("- **算力/显存与工程代价**：\(digest.computeAndTradeoffs)")
            }
            lines.append("")
        }

        // Limitations
        if !digest.limitations.isEmpty {
            lines.append("## 局限性与未来方向")
            for lim in digest.limitations {
                lines.append("- \(lim)")
            }
            lines.append("")
        }

        if !userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("## 个人批注与思考")
            lines.append(userNotes.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }

        if !discussionMessages.isEmpty {
            lines.append("## 延伸讨论记录")
            for msg in discussionMessages {
                let speaker = (msg.role == .user) ? "**提问**" : "**解答**"
                let indentedBody = msg.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: "\n  ")
                lines.append("- \(speaker)：\(indentedBody)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
