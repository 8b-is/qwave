import Foundation

/// Small CommonMark-ish compiler: headings, lists, tables, fences, quotes,
/// task items, links, images, emphasis, and math/mermaid placeholders.
/// Mermaid and KaTeX are applied in the page by bundled scripts; this pass
/// only emits the HTML they look for. Works with JavaScript off.
public enum MarkdownCompiler {
    public static func compile(_ source: String) -> String {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var store: [String] = []
        func park(_ html: String) -> String {
            store.append(html)
            return "\u{0000}MD\(store.count - 1)\u{0000}"
        }

        var text = extractFences(normalized, park: park)
        text = extractDisplayMath(text, park: park)
        let blocks = splitBlocks(text)
        var html: [String] = []
        html.reserveCapacity(blocks.count)
        for block in blocks {
            html.append(renderBlock(block, park: park))
        }
        var joined = html.joined(separator: "\n")
        for (index, value) in store.enumerated().reversed() {
            joined = joined.replacingOccurrences(of: "\u{0000}MD\(index)\u{0000}", with: value)
        }
        return joined
    }

    // MARK: - Extractors

    private static func extractFences(_ source: String, park: (String) -> String) -> String {
        var result = ""
        var remainder = source[...]
        while let start = remainder.range(of: "```") {
            result += remainder[..<start.lowerBound]
            let afterTicks = remainder[start.upperBound...]
            let langEnd = afterTicks.firstIndex(of: "\n") ?? afterTicks.endIndex
            let lang = afterTicks[..<langEnd].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let bodyStart = langEnd == afterTicks.endIndex ? afterTicks.endIndex : afterTicks.index(after: langEnd)
            let rest = afterTicks[bodyStart...]
            if let end = rest.range(of: "```") {
                let body = String(rest[..<end.lowerBound]).trimmingCharacters(in: .newlines)
                if lang == "mermaid" {
                    result += park("<pre class=\"mermaid\">\(escape(body))</pre>")
                } else {
                    let cls = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
                    result += park("<pre><code\(cls)>\(escape(body))\n</code></pre>")
                }
                remainder = rest[end.upperBound...]
                if remainder.first == "\n" {
                    remainder = remainder.dropFirst()
                }
            } else {
                result += "```"
                remainder = afterTicks
            }
        }
        result += remainder
        return result
    }

    private static func extractDisplayMath(_ source: String, park: (String) -> String) -> String {
        var result = ""
        var remainder = source[...]
        while let start = remainder.range(of: "$$") {
            result += remainder[..<start.lowerBound]
            let rest = remainder[start.upperBound...]
            if let end = rest.range(of: "$$") {
                let body = String(rest[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                result += park("<div class=\"math-display\">\(escape(body))</div>")
                remainder = rest[end.upperBound...]
            } else {
                result += "$$"
                remainder = rest
            }
        }
        result += remainder
        return result
    }

    private static func splitBlocks(_ source: String) -> [String] {
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var blocks: [String] = []
        var current: [String] = []

        func flush() {
            let text = current.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(text)
            }
            current = []
        }

        func kind(_ line: String) -> String {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") { return "heading" }
            if t.hasPrefix(">") { return "quote" }
            if t == "---" || t == "***" || t == "___" { return "hr" }
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") { return "ul" }
            if t.range(of: #"^\d+\. "#, options: .regularExpression) != nil { return "ol" }
            if t.contains("|") { return "table" }
            return "p"
        }

        var lastKind = ""
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                lastKind = ""
                continue
            }
            let next = kind(line)
            if !current.isEmpty, next != lastKind, next != "p" || lastKind != "p" {
                flush()
            }
            current.append(line)
            lastKind = next
        }
        flush()
        return blocks
    }

    // MARK: - Blocks

    private static func renderBlock(_ block: String, park: (String) -> String) -> String {
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\u{0000}MD") { return trimmed }

        if trimmed.hasPrefix("### ") {
            return "<h3>\(inline(String(trimmed.dropFirst(4))))</h3>"
        }
        if trimmed.hasPrefix("## ") {
            return "<h2>\(inline(String(trimmed.dropFirst(3))))</h2>"
        }
        if trimmed.hasPrefix("# ") {
            return "<h1>\(inline(String(trimmed.dropFirst(2))))</h1>"
        }
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            return "<hr>"
        }
        if trimmed.hasPrefix("> ") || trimmed.hasPrefix(">") {
            let quoted = trimmed.split(whereSeparator: \.isNewline).map { line -> String in
                var s = String(line)
                if s.hasPrefix("> ") { s.removeFirst(2) }
                else if s.hasPrefix(">") { s.removeFirst() }
                return s
            }.joined(separator: "\n")
            return "<blockquote>\(renderBlock(quoted, park: park))</blockquote>"
        }
        if isTable(trimmed) {
            return renderTable(trimmed)
        }
        if isList(trimmed) {
            return renderList(trimmed)
        }
        let paragraphs = trimmed.split(separator: "\n").map { inline(String($0)) }.joined(separator: "<br>")
        return "<p>\(paragraphs)</p>"
    }

    private static func isList(_ block: String) -> Bool {
        let first = block.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return first.hasPrefix("- ") || first.hasPrefix("* ") || first.hasPrefix("+ ")
            || first.range(of: #"^\d+\. "#, options: .regularExpression) != nil
    }

    private static func renderList(_ block: String) -> String {
        let lines = block.split(whereSeparator: \.isNewline).map(String.init)
        let ordered = lines.first?.range(of: #"^\d+\. "#, options: .regularExpression) != nil
        let tag = ordered ? "ol" : "ul"
        let items = lines.map { line -> String in
            var body = line
            if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
                body = String(body.dropFirst(2))
            } else if let range = body.range(of: #"^\d+\. "#, options: .regularExpression) {
                body = String(body[range.upperBound...])
            }
            if body.hasPrefix("[ ] ") {
                return "<li class=\"task\"><input type=\"checkbox\" disabled> \(inline(String(body.dropFirst(4))))</li>"
            }
            if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") {
                return "<li class=\"task\"><input type=\"checkbox\" disabled checked> \(inline(String(body.dropFirst(4))))</li>"
            }
            return "<li>\(inline(body))</li>"
        }
        return "<\(tag)>\(items.joined())</\(tag)>"
    }

    private static func isTable(_ block: String) -> Bool {
        let lines = block.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 2, lines[0].contains("|"), lines[1].contains("|") else { return false }
        let sep = lines[1].trimmingCharacters(in: .whitespaces)
        return sep.contains("-") && sep.filter { $0 == "-" || $0 == "|" || $0 == ":" || $0 == " " }.count == sep.count
    }

    private static func renderTable(_ block: String) -> String {
        let lines = block.split(whereSeparator: \.isNewline).map(String.init)
        func cells(_ line: String) -> [String] {
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("|") { s.removeFirst() }
            if s.hasSuffix("|") { s.removeLast() }
            return s.split(separator: "|", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        }
        let header = cells(lines[0])
        let body = lines.dropFirst(2).map(cells)
        var html = "<table><thead><tr>"
        html += header.map { "<th>\(inline($0))</th>" }.joined()
        html += "</tr></thead><tbody>"
        for row in body {
            html += "<tr>"
            html += row.map { "<td>\(inline($0))</td>" }.joined()
            html += "</tr>"
        }
        html += "</tbody></table>"
        return html
    }

    // MARK: - Inline

    private static func inline(_ raw: String) -> String {
        var text = raw
        // Images then links.
        text = replace(text, pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#) { match in
            "<img src=\"\(escape(match[2]))\" alt=\"\(escape(match[1]))\">"
        }
        text = replace(text, pattern: #"\[([^\]]+)\]\(([^)]+)\)"#) { match in
            "<a href=\"\(escape(match[2]))\">\(escape(match[1]))</a>"
        }
        // Inline math $...$ (not $$)
        text = replace(text, pattern: #"(?<!\$)\$(?!\$)([^$\n]+)\$(?!\$)"#) { match in
            "<span class=\"math-inline\">\(escape(match[1]))</span>"
        }
        text = replace(text, pattern: #"`([^`]+)`"#) { match in
            "<code>\(escape(match[1]))</code>"
        }
        text = replace(text, pattern: #"\*\*([^*]+)\*\*"#) { match in
            "<strong>\(escape(match[1]))</strong>"
        }
        text = replace(text, pattern: #"__([^_]+)__"#) { match in
            "<strong>\(escape(match[1]))</strong>"
        }
        text = replace(text, pattern: #"(?<!\*)\*([^*]+)\*(?!\*)"#) { match in
            "<em>\(escape(match[1]))</em>"
        }
        text = replace(text, pattern: #"~~([^~]+)~~"#) { match in
            "<del>\(escape(match[1]))</del>"
        }
        // Escape leftovers that aren't already tags.
        return escapeLoose(text)
    }

    private static func replace(_ text: String, pattern: String, transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = ""
        var cursor = 0
        for match in matches {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            var groups = [String]()
            for i in 0..<match.numberOfRanges {
                let range = match.range(at: i)
                groups.append(range.location == NSNotFound ? "" : ns.substring(with: range))
            }
            result += transform(groups)
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    public static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Escape text outside of already-emitted tags.
    private static func escapeLoose(_ string: String) -> String {
        var result = ""
        var i = string.startIndex
        while i < string.endIndex {
            if string[i] == "<", let close = string[i...].firstIndex(of: ">") {
                result += string[i...close]
                i = string.index(after: close)
            } else {
                result += escape(String(string[i]))
                i = string.index(after: i)
            }
        }
        return result
    }
}
