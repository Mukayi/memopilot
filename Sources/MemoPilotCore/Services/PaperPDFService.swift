import Foundation
import PDFKit
import AppKit

public struct PDFPageChunk: Codable, Equatable, Sendable {
    public var pageNumber: Int
    public var text: String

    public init(pageNumber: Int, text: String) {
        self.pageNumber = pageNumber
        self.text = text
    }
}

public struct ExtractedPDFDocument: Codable, Equatable, Sendable {
    public var pageCount: Int
    public var pages: [PDFPageChunk]

    public init(pageCount: Int, pages: [PDFPageChunk]) {
        self.pageCount = pageCount
        self.pages = pages
    }

    public var totalCharacterCount: Int {
        pages.reduce(0) { $0 + $1.text.count }
    }
}

public enum PaperPDFService {
    private static let academicDesktopUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15"
    private static let maxDownloadBytes = 45 * 1024 * 1024 // 45 MB safety cap

    /// Downloads (if remote) or copies (if local) the PDF for `record`, extracts per-page text (with Vision OCR fallback for scanned PDFs),
    /// and caches both `<id>.pdf` and `<id>.pages.json` inside `store.pdfCacheDirectoryURL`.
    public static func ensureCachedPDF(
        for record: PaperDigestRecord,
        store: PaperDigestStore = .shared
    ) async throws -> (pdfPath: String, document: ExtractedPDFDocument) {
        let pdfDestURL = store.cachedPDFFileURL(for: record.id)
        let pagesDestURL = store.cachedPDFPagesFileURL(for: record.id)

        // 1. Return immediately if already cached on disk
        if FileManager.default.fileExists(atPath: pdfDestURL.path),
           FileManager.default.fileExists(atPath: pagesDestURL.path),
           let pagesData = try? Data(contentsOf: pagesDestURL),
           let cachedDoc = try? JSONDecoder().decode(ExtractedPDFDocument.self, from: pagesData),
           !cachedDoc.pages.isEmpty {
            return (pdfDestURL.path, cachedDoc)
        }

        // 2. If user already attached a valid local PDF file at `record.cachedPDFPath`, extract & cache pages
        if let existingLocal = record.cachedPDFPath,
           FileManager.default.fileExists(atPath: existingLocal) {
            if existingLocal != pdfDestURL.path {
                try? FileManager.default.removeItem(at: pdfDestURL)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: existingLocal), to: pdfDestURL)
            }
            let extracted = try extractPages(fromPDFAt: pdfDestURL)
            saveExtractedPages(extracted, to: pagesDestURL)
            return (pdfDestURL.path, extracted)
        }

        // 3. Otherwise download from `record.digest.pdfURL` (or derive from arXiv `paperURL`)
        var candidateURLString = record.digest.pdfURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidateURLString.isEmpty {
            let arxivIDs = WebArticleFetcher.extractArxivIDs(from: record.digest.paperURL + "\n" + record.digest.sourceURL)
            if let firstID = arxivIDs.first {
                candidateURLString = "https://arxiv.org/pdf/\(firstID)"
            }
        }

        guard !candidateURLString.isEmpty,
              let remoteURL = URL(string: candidateURLString) else {
            throw NSError(
                domain: "MemoPilot.PDF",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "当前论文未包含可用的原始 PDF 链接，可点击「关联 PDF」手动挂载本地文件。"]
            )
        }

        let pdfData = try await downloadPDFDataSafely(from: remoteURL)
        try pdfData.write(to: pdfDestURL, options: .atomic)

        do {
            let extracted = try extractPages(fromPDFAt: pdfDestURL)
            saveExtractedPages(extracted, to: pagesDestURL)
            return (pdfDestURL.path, extracted)
        } catch {
            try? FileManager.default.removeItem(at: pdfDestURL)
            throw error
        }
    }

    /// Attaches a user-selected or dragged local `.pdf` file to `recordID`, caching both the PDF and its extracted pages.
    public static func importLocalPDF(
        sourceURL: URL,
        for recordID: UUID,
        store: PaperDigestStore = .shared
    ) throws -> (pdfPath: String, document: ExtractedPDFDocument) {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw NSError(
                domain: "MemoPilot.PDF",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "未找到指定的本地 PDF 文件"]
            )
        }
        let header = (try? FileHandle(forReadingFrom: sourceURL))?.readData(ofLength: 1024) ?? Data()
        guard containsPDFMagicHeader(header) else {
            throw NSError(
                domain: "MemoPilot.PDF",
                code: 415,
                userInfo: [NSLocalizedDescriptionKey: "所选文件不是有效的 PDF 文档"]
            )
        }

        let pdfDestURL = store.cachedPDFFileURL(for: recordID)
        let pagesDestURL = store.cachedPDFPagesFileURL(for: recordID)

        if sourceURL.standardizedFileURL != pdfDestURL.standardizedFileURL {
            try? FileManager.default.removeItem(at: pdfDestURL)
            try FileManager.default.copyItem(at: sourceURL, to: pdfDestURL)
        }

        let extracted = try extractPages(fromPDFAt: pdfDestURL)
        saveExtractedPages(extracted, to: pagesDestURL)
        return (pdfDestURL.path, extracted)
    }

    public static func loadCachedDocumentIfPresent(
        for recordID: UUID,
        store: PaperDigestStore = .shared
    ) -> ExtractedPDFDocument? {
        let pagesURL = store.cachedPDFPagesFileURL(for: recordID)
        guard FileManager.default.fileExists(atPath: pagesURL.path),
              let data = try? Data(contentsOf: pagesURL) else {
            return nil
        }
        return try? JSONDecoder().decode(ExtractedPDFDocument.self, from: data)
    }

    // MARK: - Question-Aware Relevant Page Selector (Handles Both Short & 50+ Page Appendix Papers)

    public static func selectRelevantPDFContext(
        from document: ExtractedPDFDocument,
        question: String,
        priorHistory: [PaperDiscussionMessage],
        maxBudgetChars: Int = 64_000
    ) -> String {
        guard !document.pages.isEmpty else { return "" }

        // If the entire PDF fits comfortably within budget (~8-10 pages), include every page verbatim!
        if document.totalCharacterCount <= maxBudgetChars {
            return document.pages
                .map { "[PDF 第 \($0.pageNumber) 页]\n\($0.text)" }
                .joined(separator: "\n\n")
        }

        // Otherwise, always include Page 1 (Title/Abstract/Intro) + rank remaining pages by query relevance!
        let queryContext = (question + " " + priorHistory.suffix(4).map(\.content).joined(separator: " ")).lowercased()
        let queryTokens = extractSearchTokens(from: queryContext)

        var pageScores: [Int: Double] = [:]
        for chunk in document.pages {
            let lowerPage = chunk.text.lowercased()
            var score: Double = (chunk.pageNumber == 1) ? 1000.0 : ((chunk.pageNumber == 2) ? 35.0 : 0.0)

            for token in queryTokens {
                if lowerPage.contains(token) {
                    // Weight longer/specific tokens (e.g., "table 3", "detailer", "oklab", "495") higher
                    let weight = token.count >= 5 ? 14.0 : (token.count >= 3 ? 8.0 : 3.5)
                    score += weight
                }
            }
            pageScores[chunk.pageNumber] = score
        }

        // Add small neighbor bonus (±1 page) around high-scoring pages so tables/equations split across page breaks stay intact
        var smoothedScores = pageScores
        for chunk in document.pages {
            let p = chunk.pageNumber
            let selfScore = pageScores[p] ?? 0
            if selfScore >= 16.0 && p > 1 {
                smoothedScores[p - 1, default: 0] += selfScore * 0.22
                smoothedScores[p + 1, default: 0] += selfScore * 0.22
            }
        }

        let rankedPages = document.pages.sorted {
            let s1 = smoothedScores[$0.pageNumber] ?? 0
            let s2 = smoothedScores[$1.pageNumber] ?? 0
            if abs(s1 - s2) > 0.01 { return s1 > s2 }
            return $0.pageNumber < $1.pageNumber
        }

        var selectedPageNumbers = Set<Int>()
        var usedChars = 0
        for chunk in rankedPages {
            let entryLen = chunk.text.count + 24
            if usedChars + entryLen <= maxBudgetChars || selectedPageNumbers.isEmpty {
                selectedPageNumbers.insert(chunk.pageNumber)
                usedChars += entryLen
            }
            if usedChars >= maxBudgetChars {
                break
            }
        }

        let orderedChunks = document.pages.filter { selectedPageNumbers.contains($0.pageNumber) }
        let headerNote = "（原论文共 \(document.pageCount) 页，已按问题相关性检索提取以下 \(orderedChunks.count) 页原文内容）\n\n"
        let body = orderedChunks
            .map { "[PDF 第 \($0.pageNumber) 页]\n\($0.text)" }
            .joined(separator: "\n\n")
        return headerNote + body
    }

    private static func extractSearchTokens(from lowerText: String) -> [String] {
        var tokens = Set<String>()

        // 1. Explicit Figure / Table / Equation / Section / Appendix references (e.g. "table 3", "fig. 2", "eq. 4")
        if let refRegex = try? NSRegularExpression(pattern: #"(?:table|tab\.?|figure|fig\.?|equation|eq\.?|section|sec\.?|alg\.?|表|图|公式)\s*\d+[a-z]?"#) {
            let ns = lowerText as NSString
            for m in refRegex.matches(in: lowerText, range: NSRange(location: 0, length: ns.length)) {
                tokens.insert(ns.substring(with: m.range))
            }
        }

        // 2. Latin / alphanumeric technical words & numbers
        let stopWords: Set<String> = ["the", "and", "for", "with", "that", "this", "from", "what", "how", "why", "are", "was", "were", "does", "paper", "model"]
        if let wordRegex = try? NSRegularExpression(pattern: #"[a-z0-9_.-]{2,}"#) {
            let ns = lowerText as NSString
            for m in wordRegex.matches(in: lowerText, range: NSRange(location: 0, length: ns.length)) {
                let w = ns.substring(with: m.range)
                if !stopWords.contains(w) {
                    tokens.insert(w)
                }
            }
        }

        // 3. CJK 2-character bigrams + key English mappings for common Chinese research queries
        let cjkScalars = lowerText.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.map { Character($0) }
        let cjkStopBigrams: Set<String> = ["这篇", "论文", "什么", "怎么", "为什么", "如何", "一下", "可以", "有没有", "哪些", "这个", "工作"]
        if cjkScalars.count >= 2 {
            for i in 0..<(cjkScalars.count - 1) {
                let bg = String([cjkScalars[i], cjkScalars[i + 1]])
                if !cjkStopBigrams.contains(bg) {
                    tokens.insert(bg)
                }
            }
        }

        // Cross-lingual academic term expansion (Chinese question -> English PDF section keywords!)
        let crossMap: [(zh: String, en: [String])] = [
            ("学习率", ["learning rate", "lr", "adam", "optimizer"]),
            ("训练", ["training", "hyperparameter", "batch size", "iterations", "steps"]),
            ("消融", ["ablation", "table"]),
            ("延迟", ["latency", "ms", "fps", "throughput", "speed"]),
            ("显存", ["memory", "gb", "vram", "gpu"]),
            ("数据集", ["dataset", "benchmark", "evaluation", "data"]),
            ("损失", ["loss", "objective", "lpips"]),
            ("附录", ["appendix", "supplementary"]),
            ("局限", ["limitation", "failure", "discussion", "conclusion"]),
            ("结构", ["architecture", "detailer", "backbone", "patch"]),
            ("公式", ["equation", "formulation", "sigma", "noise"])
        ]
        for pair in crossMap where lowerText.contains(pair.zh) {
            for enTerm in pair.en {
                tokens.insert(enTerm)
            }
        }

        return Array(tokens)
    }

    // MARK: - Safe Streamed Download & PDFKit + Vision OCR Extraction

    public static func containsPDFMagicHeader(_ data: Data) -> Bool {
        let slice = data.prefix(1024)
        return slice.range(of: Data("%PDF-".utf8)) != nil
    }

    private static func downloadPDFDataSafely(from url: URL) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 18.0
        config.timeoutIntervalForResource = 42.0
        let session = URLSession(configuration: config)

        var req = URLRequest(url: url)
        req.setValue(academicDesktopUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/pdf,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (asyncBytes, response) = try await session.bytes(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 {
                throw NSError(
                    domain: "MemoPilot.PDF",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "原论文 PDF 链接返回 404（尚未公开或链接有误），可手动关联本地 PDF。"]
                )
            }
            if http.statusCode == 429 || http.statusCode == 403 {
                throw NSError(
                    domain: "MemoPilot.PDF",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "论文站点触发访问频率验证 (\(http.statusCode))，请稍后重试或下载后手动关联本地 PDF。"]
                )
            }
            if http.statusCode >= 400 {
                throw NSError(
                    domain: "MemoPilot.PDF",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "下载原论文 PDF 失败 (HTTP \(http.statusCode))"]
                )
            }
            if http.expectedContentLength > Int64(maxDownloadBytes) {
                throw NSError(
                    domain: "MemoPilot.PDF",
                    code: 413,
                    userInfo: [NSLocalizedDescriptionKey: "原论文 PDF 体积超过 45MB 上限，建议下载压缩版后本地挂载。"]
                )
            }
        }

        var buffer = Data()
        buffer.reserveCapacity(min(max(Int(response.expectedContentLength), 512 * 1024), 12 * 1024 * 1024))

        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count > maxDownloadBytes {
                throw NSError(
                    domain: "MemoPilot.PDF",
                    code: 413,
                    userInfo: [NSLocalizedDescriptionKey: "原论文 PDF 体积超过 45MB 上限"]
                )
            }
        }

        guard containsPDFMagicHeader(buffer) else {
            throw NSError(
                domain: "MemoPilot.PDF",
                code: 415,
                userInfo: [NSLocalizedDescriptionKey: "论文 PDF 链接返回了网页验证页面而非 PDF 文件，请稍后重试或手动关联本地 PDF。"]
            )
        }
        return buffer
    }

    public static func extractPages(fromPDFAt fileURL: URL) throws -> ExtractedPDFDocument {
        guard let pdfDoc = PDFDocument(url: fileURL) else {
            throw NSError(
                domain: "MemoPilot.PDF",
                code: 422,
                userInfo: [NSLocalizedDescriptionKey: "无法打开或解析该 PDF 文件"]
            )
        }
        if pdfDoc.isLocked {
            throw NSError(
                domain: "MemoPilot.PDF",
                code: 423,
                userInfo: [NSLocalizedDescriptionKey: "该 PDF 文档受密码加密保护，无法提取正文"]
            )
        }

        let totalPages = pdfDoc.pageCount
        guard totalPages > 0 else {
            throw NSError(
                domain: "MemoPilot.PDF",
                code: 422,
                userInfo: [NSLocalizedDescriptionKey: "该 PDF 文档页数为 0"]
            )
        }

        var chunks: [PDFPageChunk] = []
        let maxPagesToExtract = min(totalPages, 80)
        for idx in 0..<maxPagesToExtract {
            if let rawPageText = pdfDoc.page(at: idx)?.string {
                let cleaned = normalizePDFPageText(rawPageText)
                if !cleaned.isEmpty {
                    chunks.append(PDFPageChunk(pageNumber: idx + 1, text: cleaned))
                }
            }
        }

        // Scanned image-only PDF fallback: run Apple Vision OCR on the first 8 pages!
        let totalExtractedChars = chunks.reduce(0) { $0 + $1.text.count }
        if totalExtractedChars < 80 {
            chunks.removeAll()
            let ocrPages = min(totalPages, 8)
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MemoPilot-PDFOCR-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            for idx in 0..<ocrPages {
                guard let page = pdfDoc.page(at: idx) else { continue }
                let img = page.thumbnail(of: NSSize(width: 1400, height: 1850), for: .mediaBox)
                let pagePNG = tempDir.appendingPathComponent("page_\(idx + 1).png")
                if let tiff = img.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let pngData = rep.representation(using: .png, properties: [:]) {
                    try? pngData.write(to: pagePNG)
                    let ocrText = normalizePDFPageText(VisionOCRService.recognizeText(at: pagePNG.path))
                    if !ocrText.isEmpty {
                        chunks.append(PDFPageChunk(pageNumber: idx + 1, text: ocrText))
                    }
                }
            }
        }

        guard !chunks.isEmpty else {
            throw NSError(
                domain: "MemoPilot.PDF",
                code: 422,
                userInfo: [NSLocalizedDescriptionKey: "未能从该 PDF 中提取出有效文本"]
            )
        }

        return ExtractedPDFDocument(pageCount: totalPages, pages: chunks)
    }

    private static func normalizePDFPageText(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
        // Rejoin hyphenated line breaks common in two-column LaTeX PDFs (e.g. "diffu-\nsion" -> "diffusion")
        if let hyphRegex = try? NSRegularExpression(pattern: #"([A-Za-z])-\n([a-z])"#) {
            let ns = text as NSString
            text = hyphRegex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "$1$2")
        }
        if let blankRegex = try? NSRegularExpression(pattern: #"\n{3,}"#) {
            let ns = text as NSString
            text = blankRegex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "\n\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func saveExtractedPages(_ doc: ExtractedPDFDocument, to url: URL) {
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
