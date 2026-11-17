import Foundation
import WebKit
import PDFKit

public struct FetchedWebArticle: Sendable, Equatable {
    public var sourceURL: String
    public var siteOrAccountName: String
    public var articleTitle: String
    public var cleanedBodyText: String
    public var detectedExternalURLs: [String]
    public var detectedArxivIDs: [String]
    public var arxivOfficialMetadata: String

    public init(
        sourceURL: String = "",
        siteOrAccountName: String = "",
        articleTitle: String = "",
        cleanedBodyText: String = "",
        detectedExternalURLs: [String] = [],
        detectedArxivIDs: [String] = [],
        arxivOfficialMetadata: String = ""
    ) {
        self.sourceURL = sourceURL
        self.siteOrAccountName = siteOrAccountName
        self.articleTitle = articleTitle
        self.cleanedBodyText = cleanedBodyText
        self.detectedExternalURLs = detectedExternalURLs
        self.detectedArxivIDs = detectedArxivIDs
        self.arxivOfficialMetadata = arxivOfficialMetadata
    }
}

public enum WebArticleFetcher {
    private static let wechatDesktopUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) MicroMessenger/6.8.0 Chrome/122.0.0.0 Safari/537.36"

    /// Extracts the first valid HTTP/HTTPS URL (unescaping `&amp;`, preserving balanced parentheses, stripping trailing CJK punctuation)
    /// or converts bare `arXiv:xxxx.xxxxx` into `https://arxiv.org/abs/...`.
    public static func extractPrimaryURL(from rawInput: String) -> String? {
        let trimmed = rawInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&amp;", with: "&")
        guard !trimmed.isEmpty else { return nil }

        // 1. Standard http/https URL (allowing parentheses inside URLs, stripping unmatched trailing punctuation)
        if let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>\"'，。！？；：（）【】《》]+"#, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let range = Range(match.range, in: trimmed) {
            var urlStr = String(trimmed[range])
            urlStr = trimUnbalancedTrailingPunctuation(urlStr)
            return urlStr
        }

        // 2. Bare arXiv identifier like "arXiv:2502.12345" or "2502.12345v2"
        if let regex = try? NSRegularExpression(pattern: #"(?:arXiv:\s*)?(\d{4}\.\d{4,5}(?:v\d+)?)"#, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           match.numberOfRanges > 1,
           let idRange = Range(match.range(at: 1), in: trimmed),
           trimmed.count < 64 {
            let arxivID = String(trimmed[idRange])
            return "https://arxiv.org/abs/\(arxivID)"
        }

        return nil
    }

    private static func trimUnbalancedTrailingPunctuation(_ rawURL: String) -> String {
        var s = rawURL
        while let last = s.last {
            if [".", ",", ";", "!", "?", "'", "\"", ">"].contains(String(last)) {
                s.removeLast()
            } else if last == ")" {
                let openCount = s.filter { $0 == "(" }.count
                let closeCount = s.filter { $0 == ")" }.count
                if closeCount > openCount {
                    s.removeLast()
                } else {
                    break
                }
            } else if last == "]" {
                let openCount = s.filter { $0 == "[" }.count
                let closeCount = s.filter { $0 == "]" }.count
                if closeCount > openCount {
                    s.removeLast()
                } else {
                    break
                }
            } else {
                break
            }
        }
        return s
    }

    private static func makeSafeURL(from rawString: String) -> URL? {
        if let direct = URL(string: rawString) {
            return direct
        }
        if let comp = URLComponents(string: rawString), let u = comp.url {
            return u
        }
        let encoded = rawString.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(.urlQueryAllowed)) ?? rawString
        return URL(string: encoded)
    }

    public static func fetchAndClean(from rawInput: String) async throws -> FetchedWebArticle {
        guard let rawURLString = extractPrimaryURL(from: rawInput) else {
            let cleanRaw = sanitizeNullBytes(rawInput)
            let urls = extractInterestingURLs(from: cleanRaw)
            let arxivIDs = extractArxivIDs(from: cleanRaw)
            let arxivMeta = await fetchArxivMetadataIfAvailable(ids: arxivIDs)
            return FetchedWebArticle(
                sourceURL: "",
                siteOrAccountName: "手动粘贴文本",
                articleTitle: "",
                cleanedBodyText: truncatePreservingHeadAndTail(cleanRaw, maxChars: 28_000),
                detectedExternalURLs: urls,
                detectedArxivIDs: arxivIDs,
                arxivOfficialMetadata: arxivMeta
            )
        }

        // Normalize direct arXiv PDF links to abstract page for rich HTML metadata fetching
        let fetchTargetURLString: String
        if rawURLString.lowercased().contains("arxiv.org/pdf/"),
           let arxivID = extractArxivIDs(from: rawURLString).first {
            fetchTargetURLString = "https://arxiv.org/abs/\(arxivID)"
        } else {
            fetchTargetURLString = rawURLString
        }

        guard let targetURL = makeSafeURL(from: fetchTargetURLString) else {
            throw NSError(
                domain: "MemoPilot.WebFetch",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "链接格式无效：\(rawURLString)"]
            )
        }

        // Tier 1: Fast HTTP fetch + specialized WeChat / HTML / PDFKit cleaner
        var tier1Error: Error?
        var article: FetchedWebArticle?
        do {
            article = try await fetchViaURLSession(url: targetURL, originalURLString: rawURLString)
        } catch {
            tier1Error = error
        }

        // If Tier 1 explicitly rejected an unsupported binary media type (image/video/zip), surface immediately
        if let nsErr = tier1Error as NSError?, nsErr.domain == "MemoPilot.UnsupportedMedia" {
            throw nsErr
        }

        // Tier 2: Per-call Headless WKWebView fallback if HTTP body was empty, JS-rendered, or hit a verification gate
        if article == nil || (article?.cleanedBodyText.count ?? 0) < 120 || isBlockedVerificationText(article?.cleanedBodyText ?? "") {
            if let rendered = try? await OffscreenWebExtractor.extractRenderedPage(url: targetURL, originalURLString: rawURLString),
               rendered.cleanedBodyText.count > (article?.cleanedBodyText.count ?? 0) {
                article = rendered
            }
        }

        var resolved = article ?? FetchedWebArticle(sourceURL: rawURLString)
        resolved.cleanedBodyText = sanitizeNullBytes(resolved.cleanedBodyText)

        // Append any extra user note typed alongside the URL
        let extraUserNote = sanitizeNullBytes(
            rawInput
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: rawURLString, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if !extraUserNote.isEmpty {
            resolved.cleanedBodyText = "【用户附言】：\(extraUserNote)\n\n" + resolved.cleanedBodyText
        }

        // Tier 3: Cross-enrich with official arXiv API if any arXiv ID was found
        var allArxivIDs = resolved.detectedArxivIDs
        for id in extractArxivIDs(from: resolved.sourceURL + "\n" + rawURLString) where !allArxivIDs.contains(id) {
            allArxivIDs.insert(id, at: 0)
        }
        resolved.detectedArxivIDs = allArxivIDs

        if !allArxivIDs.isEmpty {
            resolved.arxivOfficialMetadata = sanitizeNullBytes(await fetchArxivMetadataIfAvailable(ids: allArxivIDs))
        }

        if resolved.cleanedBodyText.trimmingCharacters(in: .whitespacesAndNewlines).count < 40
            && resolved.arxivOfficialMetadata.isEmpty {
            throw NSError(
                domain: "MemoPilot.WebFetch",
                code: 422,
                userInfo: [NSLocalizedDescriptionKey: "该链接页面受登录或反爬验证保护，未能自动提取正文。您可以复制网页正文粘贴到输入框直接解析。"]
            )
        }

        resolved.cleanedBodyText = truncatePreservingHeadAndTail(resolved.cleanedBodyText, maxChars: 28_000)
        return resolved
    }

    private static func sanitizeNullBytes(_ text: String) -> String {
        text.replacingOccurrences(of: "\0", with: "")
    }

    private static func isBlockedVerificationText(_ text: String) -> Bool {
        let markers = ["环境异常", "完成验证后即可继续访问", "去验证", "wappoc_appmsgcaptcha", "Enable JavaScript and cookies to continue"]
        return markers.contains { text.contains($0) } && text.count < 600
    }

    private static func fetchViaURLSession(url: URL, originalURLString: String) async throws -> FetchedWebArticle {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15.0
        config.timeoutIntervalForResource = 22.0
        let session = URLSession(configuration: config)

        var req = URLRequest(url: url)
        req.setValue(wechatDesktopUA, forHTTPHeaderField: "User-Agent")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw NSError(domain: "MemoPilot.HTTP", code: http.statusCode)
        }

        let finalURL = response.url ?? url
        let resolvedSourceURL = finalURL.absoluteString.isEmpty ? originalURLString : finalURL.absoluteString
        let mime = (response.mimeType ?? "").lowercased()

        // 1. Direct PDF extraction via native macOS PDFKit (handles OpenReview, ACL Anthology, NeurIPS, or redirected PDFs!)
        let isPDFMagic = data.count >= 5 && data.prefix(5).elementsEqual([0x25, 0x50, 0x44, 0x46, 0x2D]) // "%PDF-"
        if isPDFMagic || mime == "application/pdf" {
            guard let pdfDoc = PDFDocument(data: data) else {
                throw NSError(
                    domain: "MemoPilot.UnsupportedMedia",
                    code: 415,
                    userInfo: [NSLocalizedDescriptionKey: "无法解析该 PDF 文档内容，请尝试粘贴对应的论文主页链接。"]
                )
            }
            var pageTexts: [String] = []
            let maxPages = min(pdfDoc.pageCount, 24)
            for i in 0..<maxPages {
                if let pText = pdfDoc.page(at: i)?.string, !pText.isEmpty {
                    pageTexts.append(pText)
                }
            }
            let fullPDFText = sanitizeNullBytes(pageTexts.joined(separator: "\n\n"))
            let pdfTitle = (pdfDoc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? finalURL.lastPathComponent
            let urls = extractInterestingURLs(from: fullPDFText)
            let arxivIDs = extractArxivIDs(from: fullPDFText + "\n" + resolvedSourceURL)
            return FetchedWebArticle(
                sourceURL: resolvedSourceURL,
                siteOrAccountName: "\(finalURL.host ?? "PDF") · 论文 PDF",
                articleTitle: pdfTitle,
                cleanedBodyText: fullPDFText,
                detectedExternalURLs: urls,
                detectedArxivIDs: arxivIDs
            )
        }

        // 2. Reject non-text binary media (images, videos, archives) so binary bytes never turn into UTF-8 garbage
        if mime.hasPrefix("image/") || mime.hasPrefix("video/") || mime.hasPrefix("audio/")
            || mime == "application/zip" || mime == "application/octet-stream" {
            throw NSError(
                domain: "MemoPilot.UnsupportedMedia",
                code: 415,
                userInfo: [NSLocalizedDescriptionKey: "该链接指向二进制媒体文件（\(mime)），请粘贴文章或论文网页链接。"]
            )
        }

        let html = sanitizeNullBytes(
            String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        )
        return parseRawHTML(html, url: finalURL, originalURLString: resolvedSourceURL)
    }

    /// Parses WeChat Official Account HTML (`mp.weixin.qq.com`) as well as general academic/blog HTML (`arxiv.org`, `huggingface.co`, `github.com`, etc.).
    public static func parseRawHTML(_ html: String, url: URL, originalURLString: String) -> FetchedWebArticle {
        let host = (url.host ?? "").lowercased()
        let isWeChat = host.contains("weixin.qq.com")
        let isGitHub = host.contains("github.com")

        // 1. Extract Title (order-independent `<meta>` support)
        let title = firstRegexCapture(#"var\s+msg_title\s*=\s*['"]([^'"]+)['"]"#, in: html)
            ?? extractMetaContent(keys: ["og:title", "citation_title", "twitter:title"], in: html)
            ?? firstRegexCapture(#"<title[^>]*>(.*?)</title>"#, in: html)
            ?? ""

        // 2. Extract Account / Site Name
        let accountRaw: String
        if isWeChat {
            let wxName = firstRegexCapture(#"id=["']js_name["'][^>]*>(.*?)<"#, in: html)
                ?? firstRegexCapture(#"var\s+nickname\s*=\s*htmlDecode\(["']([^"']+)["']\)"#, in: html)
                ?? "微信公众号"
            let cleanWx = decodeHTMLEntities(wxName).trimmingCharacters(in: .whitespacesAndNewlines)
            accountRaw = cleanWx.isEmpty ? "微信公众号" : "微信公众号 · \(cleanWx)"
        } else if host.contains("arxiv.org") {
            accountRaw = "arXiv 预印本"
        } else if host.contains("huggingface.co") {
            accountRaw = "HuggingFace Papers"
        } else if isGitHub {
            accountRaw = "GitHub Repository"
        } else if host.contains("openreview.net") {
            accountRaw = "OpenReview"
        } else {
            let siteMeta = extractMetaContent(keys: ["og:site_name"], in: html)
            accountRaw = decodeHTMLEntities(siteMeta ?? host).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 3. Isolate main content container (`#js_content` for WeChat, `markdown-body` for GitHub, `<article>` / `<main>` otherwise)
        let contentHTML: String
        if isWeChat, let wxChunk = extractWeChatJSContent(from: html) {
            contentHTML = wxChunk
        } else if isGitHub, let ghReadme = firstRegexCapture(#"<article[^>]*class=["'][^"']*markdown-body[^"']*["'][^>]*>([\s\S]*?)</article>"#, in: html) {
            contentHTML = ghReadme
        } else if let articleChunk = firstRegexCapture(#"<article[^>]*>([\s\S]*?)</article>"#, in: html) {
            contentHTML = articleChunk
        } else if let mainChunk = firstRegexCapture(#"<main[^>]*>([\s\S]*?)</main>"#, in: html) {
            contentHTML = mainChunk
        } else {
            contentHTML = html
        }

        // 4. Collect external links from `href="..."` (resolving relative URLs against `url`) before stripping tags
        var externalURLs = extractHrefLinks(from: contentHTML, baseURL: url)

        // 5. Convert WeChat MathJax `data-formula="..."` attributes into `$formula$` BEFORE stripping massive `<svg>` vectors!
        var working = replaceWeChatFormulasWithLaTeX(in: contentHTML)

        // 6. Strip `<svg>`, `<script>`, `<style>`, `<noscript>`, comments
        working = regexReplace(#"<!--[\s\S]*?-->"#, in: working, with: "")
        working = regexReplace(#"<(?:script|style|svg|noscript|iframe)[^>]*>[\s\S]*?</(?:script|style|svg|noscript|iframe)>"#, in: working, with: "")

        // 7. Convert block/heading tags to clean newlines & bullets
        working = regexReplace(#"<br\s*/?>"#, in: working, with: "\n")
        working = regexReplace(#"<li[^>]*>"#, in: working, with: "\n• ")
        working = regexReplace(#"</(?:p|div|section|h1|h2|h3|h4|h5|h6|tr|li|blockquote)>"#, in: working, with: "\n")
        working = regexReplace(#"<[^>]+>"#, in: working, with: "")

        var plainText = sanitizeNullBytes(
            decodeHTMLEntities(working)
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: "\r\n", with: "\n")
        )

        plainText = regexReplace(#"[ \t]+\n"#, in: plainText, with: "\n")
        plainText = regexReplace(#"\n{3,}"#, in: plainText, with: "\n\n")
        plainText = plainText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Include citation_author / abstract meta tags if present
        let citationAuthors = extractAllMetaContents(key: "citation_author", in: html)
        let ogDesc = extractMetaContent(keys: ["citation_abstract", "og:description", "description"], in: html)
        if !citationAuthors.isEmpty {
            plainText = "【网页元信息作者】：\(citationAuthors.joined(separator: ", "))\n" + plainText
        }
        if let ogDesc, plainText.count < 600 {
            plainText += "\n\n【摘要元信息】：\(decodeHTMLEntities(ogDesc))"
        }

        // Merge plain-text URLs
        for u in extractInterestingURLs(from: plainText) where !externalURLs.contains(u) {
            externalURLs.append(u)
        }

        let arxivIDs = extractArxivIDs(from: plainText + "\n" + externalURLs.joined(separator: "\n") + "\n" + originalURLString)

        return FetchedWebArticle(
            sourceURL: originalURLString,
            siteOrAccountName: accountRaw,
            articleTitle: decodeHTMLEntities(title).trimmingCharacters(in: .whitespacesAndNewlines),
            cleanedBodyText: plainText,
            detectedExternalURLs: externalURLs,
            detectedArxivIDs: arxivIDs,
            arxivOfficialMetadata: ""
        )
    }

    private static func extractMetaContent(keys: [String], in html: String) -> String? {
        guard let metaRegex = try? NSRegularExpression(pattern: #"<meta\b[^>]+>"#, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = html as NSString
        let matches = metaRegex.matches(in: html, range: NSRange(location: 0, length: min(ns.length, 120_000)))
        for key in keys {
            let lowerKey = key.lowercased()
            for m in matches {
                let tag = ns.substring(with: m.range)
                if let attrVal = firstRegexCapture(#"(?:property|name)\s*=\s*["']([^"']+)["']"#, in: tag),
                   attrVal.lowercased() == lowerKey,
                   let contentVal = firstRegexCapture(#"content\s*=\s*["']([^"']+)["']"#, in: tag) {
                    return contentVal
                }
            }
        }
        return nil
    }

    private static func extractAllMetaContents(key: String, in html: String) -> [String] {
        guard let metaRegex = try? NSRegularExpression(pattern: #"<meta\b[^>]+>"#, options: [.caseInsensitive]) else {
            return []
        }
        let lowerKey = key.lowercased()
        let ns = html as NSString
        let matches = metaRegex.matches(in: html, range: NSRange(location: 0, length: min(ns.length, 120_000)))
        var values: [String] = []
        for m in matches {
            let tag = ns.substring(with: m.range)
            if let attrVal = firstRegexCapture(#"(?:property|name)\s*=\s*["']([^"']+)["']"#, in: tag),
               attrVal.lowercased() == lowerKey,
               let contentVal = firstRegexCapture(#"content\s*=\s*["']([^"']+)["']"#, in: tag) {
                values.append(decodeHTMLEntities(contentVal))
            }
        }
        return values
    }

    private static func extractWeChatJSContent(from html: String) -> String? {
        guard let startRange = html.range(of: #"id=["']js_content["']"#, options: .regularExpression) else {
            return nil
        }
        let tail = html[startRange.lowerBound...]
        guard let tagClose = tail.firstIndex(of: ">") else { return nil }
        let bodyStart = tail.index(after: tagClose)
        let sub = tail[bodyStart...]
        if let scriptAnchor = sub.range(of: #"<script\b"#, options: [.regularExpression, .caseInsensitive]) {
            return String(sub[..<scriptAnchor.lowerBound])
        }
        return String(sub)
    }

    private static func replaceWeChatFormulasWithLaTeX(in html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<(span|section)\b[^>]*\bdata-formula=["']([^"']+)["'][^>]*>[\s\S]*?</\1>"#,
            options: [.caseInsensitive]
        ) else {
            return html
        }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }

        let mutable = NSMutableString(string: html)
        for match in matches.reversed() {
            let tag = ns.substring(with: match.range(at: 1)).lowercased()
            let rawFormula = decodeHTMLEntities(ns.substring(with: match.range(at: 2)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = (tag == "section") ? "\n$$\(rawFormula)$$\n" : " $\(rawFormula)$ "
            mutable.replaceCharacters(in: match.range, with: replacement)
        }
        return mutable as String
    }

    public static func extractInterestingURLs(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+"#,
            options: [.caseInsensitive]
        ) else { return [] }

        let ns = text as NSString
        var results: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let rawU = ns.substring(with: match.range)
            let u = trimUnbalancedTrailingPunctuation(rawU)
            let lower = u.lowercased()
            let isNoise = lower.contains("mmbiz.qpic.cn")
                || lower.contains("res.wx.qq.com")
                || lower.contains("w3.org/2000/svg")
                || lower.contains("weixin.qq.com/s?")
            if !isNoise && !results.contains(u) {
                results.append(u)
            }
        }
        return Array(results.prefix(24))
    }

    private static func extractHrefLinks(from html: String, baseURL: URL) -> [String] {
        let rawHrefs = allRegexCaptures(#"href=["']([^"'\s<>]+)["']"#, in: html)
        var cleaned: [String] = []
        for h in rawHrefs {
            let unescaped = decodeHTMLEntities(h)
            if unescaped.hasPrefix("#") || unescaped.lowercased().hasPrefix("javascript:") || unescaped.lowercased().hasPrefix("mailto:") {
                continue
            }
            guard let resolved = URL(string: unescaped, relativeTo: baseURL)?.absoluteURL.absoluteString,
                  resolved.lowercased().hasPrefix("http") else {
                continue
            }
            let lower = resolved.lowercased()
            if lower.contains("mmbiz.qpic.cn") || lower.contains("res.wx.qq.com") {
                continue
            }
            if !cleaned.contains(resolved) {
                cleaned.append(resolved)
            }
        }
        return Array(cleaned.prefix(28))
    }

    public static func extractArxivIDs(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:arxiv\.org/(?:abs|pdf|html)/|arXiv:\s*)([A-Za-z\-]+/\d{7}|\d{4}\.\d{4,5}(?:v\d+)?)"#,
            options: [.caseInsensitive]
        ) else { return [] }
        let ns = text as NSString
        var ids: [String] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
            let id = ns.substring(with: m.range(at: 1))
            if !ids.contains(id) {
                ids.append(id)
            }
        }
        return Array(ids.prefix(4))
    }

    private static func fetchArxivMetadataIfAvailable(ids: [String]) async -> String {
        guard let primaryID = ids.first,
              let apiURL = URL(string: "https://export.arxiv.org/api/query?id_list=\(primaryID)") else {
            return ""
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4.5
        config.timeoutIntervalForResource = 5.5
        let session = URLSession(configuration: config)

        guard let (data, resp) = try? await session.data(from: apiURL),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let xml = String(data: data, encoding: .utf8),
              let entryBlock = firstRegexCapture(#"<entry>([\s\S]*?)</entry>"#, in: xml) else {
            return ""
        }

        let title = firstRegexCapture(#"<title>([\s\S]*?)</title>"#, in: entryBlock)?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty, title.lowercased() != "error" else { return "" }

        let summary = firstRegexCapture(#"<summary>([\s\S]*?)</summary>"#, in: entryBlock)?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let published = firstRegexCapture(#"<published>(.*?)</published>"#, in: entryBlock) ?? ""
        let comment = firstRegexCapture(#"<arxiv:comment[^>]*>([\s\S]*?)</arxiv:comment>"#, in: entryBlock) ?? ""
        let authors = allRegexCaptures(#"<name>(.*?)</name>"#, in: entryBlock)

        var lines: [String] = [
            "arXiv ID: \(primaryID)",
            "Official Title: \(decodeHTMLEntities(title))"
        ]
        if !authors.isEmpty {
            lines.append("Official Authors: \(authors.joined(separator: ", "))")
        }
        if !published.isEmpty {
            lines.append("Published UTC: \(published)")
        }
        if !comment.isEmpty {
            lines.append("Author Comment / Venue: \(decodeHTMLEntities(comment))")
        }
        if !summary.isEmpty {
            lines.append("Official Abstract: \(decodeHTMLEntities(summary))")
        }
        return lines.joined(separator: "\n")
    }

    public static func truncatePreservingHeadAndTail(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        let headCount = Int(Double(maxChars) * 0.68)
        let tailCount = maxChars - headCount
        let head = String(text.prefix(headCount))
        let tail = String(text.suffix(tailCount))
        return "\(head)\n\n...[中间部分因篇幅省略]...\n\n\(tail)"
    }

    // MARK: - Regex & HTML Entity Helpers

    private static func firstRegexCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else {
            return nil
        }
        return ns.substring(with: match.range(at: 1))
    }

    private static func allRegexCaptures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            m.numberOfRanges > 1 ? ns.substring(with: m.range(at: 1)) : nil
        }
    }

    private static func regexReplace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let ns = text as NSString
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }

    public static func decodeHTMLEntities(_ text: String) -> String {
        var result = text

        // 1. Hex numeric entities (e.g. &#x2014;)
        if let hexRegex = try? NSRegularExpression(pattern: #"&#[xX]([0-9A-Fa-f]+);"#) {
            let ns = result as NSString
            let matches = hexRegex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            let mutable = NSMutableString(string: result)
            for m in matches.reversed() {
                let hex = ns.substring(with: m.range(at: 1))
                if let code = UInt32(hex, radix: 16), code > 0, let scalar = UnicodeScalar(code) {
                    mutable.replaceCharacters(in: m.range, with: String(scalar))
                }
            }
            result = mutable as String
        }

        // 2. Decimal numeric entities (e.g. &#8212;)
        if let decRegex = try? NSRegularExpression(pattern: #"&#([0-9]+);"#) {
            let ns = result as NSString
            let matches = decRegex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            let mutable = NSMutableString(string: result)
            for m in matches.reversed() {
                let dec = ns.substring(with: m.range(at: 1))
                if let code = UInt32(dec, radix: 10), code > 0, let scalar = UnicodeScalar(code) {
                    mutable.replaceCharacters(in: m.range, with: String(scalar))
                }
            }
            result = mutable as String
        }

        // 3. Named entities (`&amp;` decoded LAST to prevent double-unescaping)
        return result
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "&times;", with: "×")
            .replacingOccurrences(of: "&le;", with: "≤")
            .replacingOccurrences(of: "&ge;", with: "≥")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - Tier 2 Per-Call Headless WKWebView Dynamic Extractor (Concurrency-Safe)

@MainActor
private enum OffscreenWebExtractor {
    private final class PageLoadSession: NSObject, WKNavigationDelegate {
        var webView: WKWebView?
        private var continuation: CheckedContinuation<Void, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var didResume = false

        func load(url: URL) async -> WKWebView {
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 900))
            wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
            wv.navigationDelegate = self
            self.webView = wv

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                self.continuation = cont
                wv.load(URLRequest(url: url))

                timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.webView?.stopLoading()
                    self?.finish()
                }
            }
            wv.navigationDelegate = nil
            return wv
        }

        private func finish() {
            guard !didResume else { return }
            didResume = true
            timeoutTask?.cancel()
            timeoutTask = nil
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finish()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            finish()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            finish()
        }
    }

    static func extractRenderedPage(url: URL, originalURLString: String) async throws -> FetchedWebArticle {
        let session = PageLoadSession()
        let wv = await session.load(url: url)
        try? await Task.sleep(nanoseconds: 450_000_000)

        let js = """
        (function() {
            const title = document.title || '';
            const mainEl = document.querySelector('#js_content, article.markdown-body, article, main') || document.body;
            const text = mainEl ? mainEl.innerText : '';
            const links = Array.from(document.querySelectorAll('a[href]'))
                .map(a => a.href)
                .filter(h => h.startsWith('http'));
            return { title: title, text: text, links: links.slice(0, 30) };
        })()
        """
        let raw = try? await wv.evaluateJavaScript(js)
        let finalURL = wv.url ?? url
        let resolvedSource = finalURL.absoluteString.isEmpty ? originalURLString : finalURL.absoluteString

        guard let dict = raw as? [String: Any] else {
            throw NSError(domain: "MemoPilot.WKWebView", code: -1)
        }
        let title = (dict["title"] as? String) ?? ""
        let text = ((dict["text"] as? String) ?? "").replacingOccurrences(of: "\0", with: "")
        var links = (dict["links"] as? [String]) ?? []
        for u in WebArticleFetcher.extractInterestingURLs(from: text) where !links.contains(u) {
            links.append(u)
        }

        return FetchedWebArticle(
            sourceURL: resolvedSource,
            siteOrAccountName: finalURL.host ?? "网页来源",
            articleTitle: title.trimmingCharacters(in: .whitespacesAndNewlines),
            cleanedBodyText: text.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedExternalURLs: links,
            detectedArxivIDs: WebArticleFetcher.extractArxivIDs(from: text + "\n" + links.joined(separator: "\n") + "\n" + resolvedSource)
        )
    }
}
