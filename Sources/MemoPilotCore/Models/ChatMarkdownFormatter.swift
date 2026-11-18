import Foundation

public enum ChatRenderBlock: Equatable, Sendable {
    case heading(String)
    case paragraph(String)
    case bulletItem(marker: String, body: String)
    case codeBlock(language: String, code: String)
    case table(headers: [String], rows: [[String]])
}

public enum ChatMarkdownFormatter {
    /// Splits an assistant/user chat reply into structured blocks (fenced code blocks, headings, hanging-indent bullets/numbered items, and paragraphs).
    public static func parseBlocks(_ raw: String) -> [ChatRenderBlock] {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\\(", with: "")
            .replacingOccurrences(of: "\\)", with: "")
            .replacingOccurrences(of: "\\[", with: "")
            .replacingOccurrences(of: "\\]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let lines = normalized.components(separatedBy: "\n")
        var blocks: [ChatRenderBlock] = []

        var inCodeFence = false
        var codeLang = ""
        var codeLines: [String] = []
        var paragraphBuffer: [String] = []
        var tableLines: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let joined = paragraphBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(.paragraph(joined))
            }
            paragraphBuffer.removeAll()
        }

        func flushTable() {
            guard !tableLines.isEmpty else { return }
            if let parsedTable = parseMarkdownTable(tableLines) {
                blocks.append(parsedTable)
            } else {
                let fallback = tableLines.joined(separator: "\n")
                if !fallback.isEmpty {
                    blocks.append(.paragraph(fallback))
                }
            }
            tableLines.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 1. Fenced code block toggle ```
            if trimmed.hasPrefix("```") {
                if inCodeFence {
                    blocks.append(.codeBlock(language: codeLang, code: codeLines.joined(separator: "\n")))
                    inCodeFence = false
                    codeLang = ""
                    codeLines.removeAll()
                } else {
                    flushTable()
                    flushParagraph()
                    inCodeFence = true
                    codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            if inCodeFence {
                codeLines.append(line)
                continue
            }

            // 2. Markdown table row (`| col1 | col2 |`)
            if isLikelyMarkdownTableRow(trimmed) {
                flushParagraph()
                tableLines.append(trimmed)
                continue
            } else if !tableLines.isEmpty {
                flushTable()
            }

            // 3. Empty line flushes current paragraph
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            // 4. Markdown Heading (# / ## / ### / ####)
            if let headingMatch = matchHeading(trimmed) {
                flushParagraph()
                blocks.append(.heading(headingMatch))
                continue
            }

            // 5. Unordered Bullet (- / * / •) — including line 1!
            if let bulletBody = matchUnorderedBullet(trimmed) {
                flushParagraph()
                blocks.append(.bulletItem(marker: "•", body: bulletBody))
                continue
            }

            // 6. Ordered Numbered Item (1. / 2) / ①)
            if let (numMarker, itemBody) = matchOrderedItem(trimmed) {
                flushParagraph()
                blocks.append(.bulletItem(marker: numMarker, body: itemBody))
                continue
            }

            paragraphBuffer.append(trimmed)
        }

        if inCodeFence && !codeLines.isEmpty {
            blocks.append(.codeBlock(language: codeLang, code: codeLines.joined(separator: "\n")))
        }
        flushTable()
        flushParagraph()
        return blocks
    }

    /// Protects math subscripts `(x_t)_{t=1}` / `W_q` and math multiplication `1*p*p` / `λ * L` before `AttributedString(markdown:)` runs,
    /// while preserving genuine `**bold**` and `` `code` `` formatting!
    public static func sanitizeInlineMarkdownPreservingMath(_ raw: String) -> String {
        // Split by inline backticks `...` so code spans are untouched
        let segments = splitPreservingInlineCode(raw)
        var result = ""
        for seg in segments {
            if seg.isCode {
                result += seg.text
            } else {
                var s = seg.text
                // Escape ALL underscores outside inline code so `x_0`, `(x_t)_{t=1}`, `L_total` NEVER trigger CommonMark underscore italics!
                s = s.replacingOccurrences(of: "\\_", with: "_")
                s = s.replacingOccurrences(of: "_", with: "\\_")

                // Temporarily protect `**` bold markers, escape single `*` (like `1*p*p` or `a * b`), then restore `**`!
                let boldSentinel = "\u{0007}BOLD\u{0007}"
                s = s.replacingOccurrences(of: "**", with: boldSentinel)
                s = s.replacingOccurrences(of: "\\*", with: "*")
                s = s.replacingOccurrences(of: "*", with: "\\*")
                s = s.replacingOccurrences(of: boldSentinel, with: "**")
                result += s
            }
        }
        return result
    }

    public static func makeSafeAttributedString(_ raw: String) -> AttributedString {
        let protected = sanitizeInlineMarkdownPreservingMath(raw)
        if let attr = try? AttributedString(
            markdown: protected,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attr
        }
        return AttributedString(raw)
    }

    // MARK: - Helpers

    private static func splitPreservingInlineCode(_ text: String) -> [(isCode: Bool, text: String)] {
        var output: [(Bool, String)] = []
        var current = ""
        var inTicks = false

        for ch in text {
            if ch == "`" {
                if inTicks {
                    current.append(ch)
                    output.append((true, current))
                    current = ""
                    inTicks = false
                } else {
                    if !current.isEmpty {
                        output.append((false, current))
                        current = ""
                    }
                    current.append(ch)
                    inTicks = true
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            output.append((false, current))
        }
        return output
    }

    private static func matchHeading(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix("#") else { return nil }
        var hashes = 0
        for ch in trimmed {
            if ch == "#" { hashes += 1 } else { break }
        }
        guard (1...5).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        let clean = rest.trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? nil : clean
    }

    private static func matchUnorderedBullet(_ trimmed: String) -> String? {
        for prefix in ["• ", "- ", "* "] {
            if trimmed.hasPrefix(prefix) {
                // Make sure `* ` is not actually `**bold**` at start of line
                if prefix == "* " && trimmed.hasPrefix("**") {
                    continue
                }
                let rest = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { return rest }
            }
        }
        return nil
    }

    private static func matchOrderedItem(_ trimmed: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: #"^(\d{1,2}[.)])\s+(.+)$"#),
              let m = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              m.numberOfRanges == 3,
              let r1 = Range(m.range(at: 1), in: trimmed),
              let r2 = Range(m.range(at: 2), in: trimmed) else {
            return nil
        }
        return (String(trimmed[r1]), String(trimmed[r2]))
    }

    private static func isLikelyMarkdownTableRow(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.filter({ $0 == "|" }).count >= 3
    }

    private static func parseMarkdownTable(_ rawLines: [String]) -> ChatRenderBlock? {
        guard rawLines.count >= 2 else { return nil }
        func splitCells(_ row: String) -> [String] {
            var inner = row
            if inner.hasPrefix("|") { inner.removeFirst() }
            if inner.hasSuffix("|") { inner.removeLast() }
            return inner.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func isSeparatorRow(_ cells: [String]) -> Bool {
            !cells.isEmpty && cells.allSatisfy { cell in
                let stripped = cell.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
                return stripped.isEmpty && cell.contains("-")
            }
        }

        let headerCells = splitCells(rawLines[0])
        let secondCells = splitCells(rawLines[1])
        guard !headerCells.isEmpty, isSeparatorRow(secondCells) else { return nil }

        let colCount = headerCells.count
        var bodyRows: [[String]] = []
        for rowLine in rawLines.dropFirst(2) {
            var cells = splitCells(rowLine)
            if isSeparatorRow(cells) { continue }
            if cells.count < colCount {
                cells.append(contentsOf: Array(repeating: "", count: colCount - cells.count))
            } else if cells.count > colCount {
                cells = Array(cells.prefix(colCount))
            }
            bodyRows.append(cells)
        }
        guard !bodyRows.isEmpty else { return nil }
        return .table(headers: headerCells, rows: bodyRows)
    }
}
