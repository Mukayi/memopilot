import Foundation
import WebKit

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

    /// Extracts the first valid HTTP/HTTPS URL (or converts bare `arXiv:xxxx.xxxxx` into `https://arxiv.org/abs/...`).
    public static func extractPrimaryURL(from rawInput: String) -> String? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. Standard http/https URL (stripping trailing CJK punctuation or closing brackets)
        if let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>\"'，。！？；：（）【】《》\)\]]+"#, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let range = Range(match.range, in: trimmed) {
            var urlStr = String(trimmed[range])
            while let last = urlStr.last, [".", ",", ";", ")", "]", ">"].contains(String(last)) {
                urlStr.removeLast()
            }
            return urlStr
        }

        // 2. Bare arXiv identifier like "arXiv:2502.12345" or "2502.12345v1"
        if let regex = try? NSRegularExpression(pattern: #"(?:arXiv:\s*)?(\d{4}\.\d{4,5}(?:v\d+)?)"#, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           match.numberOfRanges > 1,
           let idRange = Range(match.range(at: 1), in: trimmed),
           trimmed.count < 60 {
            let arxivID = String(trimmed[idRange])
            return "https://arxiv.org/abs/\(arxivID)"
        }

        return nil
    }

    public static func fetchAndClean(from rawInput: String) async throws -> FetchedWebArticle {
        guard let rawURLString = extractPrimaryURL(from: rawInput) else {
            // User pasted raw article text without a URL
            let urls = extractInterestingURLs(from: rawInput)
            let arxivIDs = extractArxivIDs(from: rawInput)
            let arxivMeta = await fetchArxivMetadataIfAvailable(ids: arxivIDs)
            return FetchedWebArticle(
                sourceURL: "",
                siteOrAccountName: "手动粘贴文本",
                articleTitle: "",
                cleanedBodyText: truncatePreservingHeadAndTail(rawInput, maxChars: 28_000),
                detectedExternalURLs: urls,
                detectedArxivIDs: arxivIDs,
                arxivOfficialMetadata: arxivMeta
            )
        }

        // Normalize direct arXiv PDF links to abstract page for rich HTML metadata fetching
        let fetchTargetURLString: String
        if rawURLString.contains("arxiv.org/pdf/") {
            fetchTargetURLString = rawURLString
                .replacingOccurrences(of: "arxiv.org/pdf/", with: "arxiv.org/abs/")
                .replacingOccurrences(of: ".pdf", with: "")
        } else {
            fetchTargetURLString = rawURLString
        }

        guard let targetURL = URL(string: fetchTargetURLString) else {
            throw NSError(
                domain: "MemoPilot.WebFetch",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "链接格式无效：\(rawURLString)"]
            )
        }

        // Tier 1: Fast HTTP fetch + specialized WeChat / HTML cleaner
        var article = (try? await fetchViaURLSession(url: targetURL, originalURLString: rawURLString))

        // Tier 2: Headless WKWebView fallback if HTTP body was empty, JS-rendered, or hit a verification gate
        if article == nil || (article?.cleanedBodyText.count ?? 0) < 120 || isBlockedVerificationText(article?.cleanedBodyText ?? "") {
            if let rendered = try? await OffscreenWebExtractor.shared.extractRenderedPage(url: targetURL, originalURLString: rawURLString),
               rendered.cleanedBodyText.count > (article?.cleanedBodyText.count ?? 0) {
                article = rendered
            }
        }

        var resolved = article ?? FetchedWebArticle(sourceURL: rawURLString)

        // Append any extra user note typed alongside the URL
        let extraUserNote = rawInput
            .replacingOccurrences(of: rawURLString, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !extraUserNote.isEmpty {
            resolved.cleanedBodyText = "【用户附言】：\(extraUserNote)\n\n" + resolved.cleanedBodyText
        }

        // Tier 3: Cross-enrich with official arXiv API if any arXiv ID was found
        var allArxivIDs = resolved.detectedArxivIDs
        for id in extractArxivIDs(from: rawURLString) where !allArxivIDs.contains(id) {
            allArxivIDs.insert(id, at: 0)
        }
        resolved.detectedArxivIDs = allArxivIDs

        if !allArxivIDs.isEmpty {
            resolved.arxivOfficialMetadata = await fetchArxivMetadataIfAvailable(ids: allArxivIDs)
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

    private static func isBlockedVerificationText(_ text: String) -> Bool {
        let markers = ["环境异常", "完成验证后即可继续访问", "去验证", "wappoc_appmsgcaptcha", "Enable JavaScript and cookies to continue"]
        return markers.contains { text.contains($0) } && text.count < 600
    }

    private static func fetchViaURLSession(url: URL, originalURLString: String) async throws -> FetchedWebArticle {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15.0
        config.timeoutIntervalForResource = 20.0
        let session = URLSession(configuration: config)

        var req = URLRequest(url: url)
        req.setValue(wechatDesktopUA, forHTTPHeaderField: "User-Agent")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw NSError(domain: "MemoPilot.HTTP", code: http.statusCode)
        }

        let html = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)

        return parseRawHTML(html, url: url, originalURLString: originalURLString)
    }

    /// Parses WeChat Official Account HTML (`mp.weixin.qq.com`) as well as general academic/blog HTML (`arxiv.org`, `huggingface.co`, `github.com`, etc.).
    public static func parseRawHTML(_ html: String, url: URL, originalURLString: String) -> FetchedWebArticle {
        let host = (url.host ?? "").lowercased()
        let isWeChat = host.contains("weixin.qq.com")

        // 1. Extract Title
        let title = firstRegexCapture(#"var\s+msg_title\s*=\s*['"]([^'"]+)['"]"#, in: html)
            ?? firstRegexCapture(#"<meta\s+property=["']og:title["']\s+content=["']([^"']+)["']"#, in: html)
            ?? firstRegexCapture(#"<meta\s+name=["']citation_title["']\s+content=["']([^"']+)["']"#, in: html)
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
        } else if host.contains("github.com") {
            accountRaw = "GitHub Repository"
        } else if host.contains("openreview.net") {
            accountRaw = "OpenReview"
        } else {
            let siteMeta = firstRegexCapture(#"<meta\s+property=["']og:site_name["']\s+content=["']([^"']+)["']"#, in: html)
            accountRaw = decodeHTMLEntities(siteMeta ?? host).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 3. Isolate main content container (`#js_content` for WeChat, `<article>` / `<main>` if present)
        let contentHTML: String
        if isWeChat, let wxChunk = extractWeChatJSContent(from: html) {
            contentHTML = wxChunk
        } else if let articleChunk = firstRegexCapture(#"<article[^>]*>(.*?)</article>"#, in: html) {
            contentHTML = articleChunk
        } else if let mainChunk = firstRegexCapture(#"<main[^>]*>(.*?)</main>"#, in: html) {
            contentHTML = mainChunk
        } else {
            contentHTML = html
        }

        // 4. Collect external links from `href="..."` before stripping tags
        var externalURLs = extractHrefLinks(from: contentHTML)

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

        var plainText = decodeHTMLEntities(working)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")

        // Collapse excessive blank lines
        plainText = regexReplace(#"[ \t]+\n"#, in: plainText, with: "\n")
        plainText = regexReplace(#"\n{3,}"#, in: plainText, with: "\n\n")
        plainText = plainText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Also include og:description / citation_abstract if body was short (e.g. arXiv abstract page)
        let citationAuthors = allRegexCaptures(#"<meta\s+name=["']citation_author["']\s+content=["']([^"']+)["']"#, in: html)
        let ogDesc = firstRegexCapture(#"<meta\s+(?:property|name)=["'](?:og:description|description|citation_abstract)["']\s+content=["']([^"']+)["']"#, in: html)
        if !citationAuthors.isEmpty {
            plainText = "【网页元信息作者】：\(citationAuthors.joined(separator: ", "))\n" + plainText
        }
        if let ogDesc, plainText.count < 500 {
            plainText += "\n\n【摘要元信息】：\(decodeHTMLEntities(ogDesc))"
        }

        // Merge plain-text URLs (e.g. WeChat articles cannot link external URLs in `<a>` so authors paste plain-text `https://arxiv.org/...`!)
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
            var u = ns.substring(with: match.range)
            while let last = u.last, [".", ",", ";", ")", "]", "'", "\""].contains(String(last)) {
                u.removeLast()
            }
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

    private static func extractHrefLinks(from html: String) -> [String] {
        let rawHrefs = allRegexCaptures(#"href=["'](https?://[^"'\s<>]+)["']"#, in: html)
        var cleaned: [String] = []
        for h in rawHrefs {
            let u = decodeHTMLEntities(h)
            let lower = u.lowercased()
            if lower.contains("mmbiz.qpic.cn") || lower.contains("res.wx.qq.com") || lower.contains("javascript:") {
                continue
            }
            if !cleaned.contains(u) {
                cleaned.append(u)
            }
        }
        return Array(cleaned.prefix(24))
    }

    public static func extractArxivIDs(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:arxiv\.org/(?:abs|pdf|html)/|arXiv:\s*)(\d{4}\.\d{4,5})(?:v\d+)?"#,
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

    /// Preserves both the beginning (paper metadata, problem, method) and the end (experiments, limitations, future work)
    /// when an article exceeds `maxChars`.
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
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
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

        // Numeric entities like &#x2014; or &#8212;
        if let hexRegex = try? NSRegularExpression(pattern: #"&#x([0-9A-Fa-f]+);"#) {
            let ns = result as NSString
            let matches = hexRegex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            let mutable = NSMutableString(string: result)
            for m in matches.reversed() {
                let hex = ns.substring(with: m.range(at: 1))
                if let code = UInt32(hex, radix: 16), let scalar = UnicodeScalar(code) {
                    mutable.replaceCharacters(in: m.range, with: String(scalar))
                }
            }
            result = mutable as String
        }
        return result
    }
}

// MARK: - Tier 2 Headless WKWebView Dynamic Extractor

@MainActor
private final class OffscreenWebExtractor: NSObject, WKNavigationDelegate {
    static let shared = OffscreenWebExtractor()

    private var activeWebView: WKWebView?
    private var navContinuation: CheckedContinuation<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func extractRenderedPage(url: URL, originalURLString: String) async throws -> FetchedWebArticle {
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 900))
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        wv.navigationDelegate = self
        self.activeWebView = wv

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.navContinuation = cont
            wv.load(URLRequest(url: url))

            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finishNav()
            }
        }
        wv.navigationDelegate = nil
        try? await Task.sleep(nanoseconds: 500_000_000)

        let js = """
        (function() {
            const title = document.title || '';
            const mainEl = document.querySelector('#js_content, article, main') || document.body;
            const text = mainEl ? mainEl.innerText : '';
            const links = Array.from(document.querySelectorAll('a[href]'))
                .map(a => a.href)
                .filter(h => h.startsWith('http'));
            return { title: title, text: text, links: links.slice(0, 30) };
        })()
        """
        let raw = try? await wv.evaluateJavaScript(js)
        self.activeWebView = nil

        guard let dict = raw as? [String: Any] else {
            throw NSError(domain: "MemoPilot.WKWebView", code: -1)
        }
        let title = (dict["title"] as? String) ?? ""
        let text = (dict["text"] as? String) ?? ""
        var links = (dict["links"] as? [String]) ?? []
        for u in WebArticleFetcher.extractInterestingURLs(from: text) where !links.contains(u) {
            links.append(u)
        }

        return FetchedWebArticle(
            sourceURL: originalURLString,
            siteOrAccountName: url.host ?? "网页来源",
            articleTitle: title.trimmingCharacters(in: .whitespacesAndNewlines),
            cleanedBodyText: text.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedExternalURLs: links,
            detectedArxivIDs: WebArticleFetcher.extractArxivIDs(from: text + "\n" + links.joined(separator: "\n"))
        )
    }

    private func finishNav() {
        timeoutTask?.cancel()
        timeoutTask = nil
        navContinuation?.resume()
        navContinuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNav()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishNav()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishNav()
    }
}
