import Foundation

/// Small CommonMark-ish compiler: headings, lists, tables, fences, quotes,
/// task items, links, images, emphasis, and math/mermaid placeholders.
/// Mermaid and KaTeX are applied in the page by bundled scripts; this pass
/// only emits the HTML they look for. Works with JavaScript off.
public enum MarkdownCompiler {
    public static func compile(_ source: String) -> String {
        // Both replacements are no-op whole-string copies unless a CR is
        // present, and almost no document has one.
        let normalized = contains(source, 0x0D)
            ? source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            : source
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
        // Reversed order so nested parks resolve: an outer park's value can
        // contain a marker for an inner park (math block wrapping a fence).
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
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var blocks: [String] = []
        var current: [Substring] = []

        func flush() {
            // `current` only ever holds lines that failed the blank test, and
            // `split(whereSeparator: \.isNewline)` guarantees no line contains a
            // newline character. So the joined text can neither begin nor end
            // with a newline, nor be all-whitespace: both trims the old code ran
            // here were no-ops that allocated a whole copy each.
            guard !current.isEmpty else { return }
            blocks.append(current.joined(separator: "\n"))
            current = []
        }

        func kind(_ t: String) -> String {
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
            // Trim once and hand the result to `kind`; the old code trimmed the
            // same line twice, allocating a String each time.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                lastKind = ""
                continue
            }
            let next = kind(trimmed)
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
                if s.hasPrefix("> ") { s.removeFirst(2) } else if s.hasPrefix(">") { s.removeFirst() }
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
                return
                    "<li class=\"task\"><input type=\"checkbox\" disabled checked> \(inline(String(body.dropFirst(4))))</li>"
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

    /// Compiled once per process, not per call. `inline()` runs eight regex
    /// passes per invocation; the old code recompiled every pattern on every
    /// pass. NSRegularExpression is documented thread-safe.
    private final class RegexBox: @unchecked Sendable {
        let value: NSRegularExpression
        init(_ pattern: String) {
            value = try! NSRegularExpression(pattern: pattern)
        }
    }

    private static let imageRegex = RegexBox(#"!\[([^\]]*)\]\(([^)]+)\)"#)
    private static let linkRegex = RegexBox(#"\[([^\]]+)\]\(([^)]+)\)"#)
    private static let mathRegex = RegexBox(#"(?<!\$)\$(?!\$)([^$\n]+)\$(?!\$)"#)
    private static let codeRegex = RegexBox(#"`([^`]+)`"#)
    private static let strongStarRegex = RegexBox(#"\*\*([^*]+)\*\*"#)
    private static let strongUnderscoreRegex = RegexBox(#"__([^_]+)__"#)
    private static let emRegex = RegexBox(#"(?<!\*)\*([^*]+)\*(?!\*)"#)
    private static let delRegex = RegexBox(#"~~([^~]+)~~"#)

    /// Zero-allocation UTF-8 scan for a single ASCII byte.
    ///
    /// Every inline pattern below needs a specific ASCII byte to match at all,
    /// so this is a *necessary* condition: when the byte is absent the regex
    /// provably cannot match and skipping the pass is byte-identical to running
    /// it. Running the pass unconditionally cost ~4 allocations even with zero
    /// matches (NSString bridge, output buffer, tail substring, bridge back),
    /// eight times per line.
    private static func contains(_ text: String, _ byte: UInt8) -> Bool {
        for candidate in text.utf8 where candidate == byte { return true }
        return false
    }

    private static func inline(_ raw: String) -> String {
        var text = raw
        // Images then links.
        if contains(text, 0x21), contains(text, 0x5B) {  // "!" and "["
            text = replace(text, regex: imageRegex) { match in
                "<img src=\"\(escape(match[2]))\" alt=\"\(escape(match[1]))\">"
            }
        }
        if contains(text, 0x5B) {  // "["
            text = replace(text, regex: linkRegex) { match in
                "<a href=\"\(escape(match[2]))\">\(escape(match[1]))</a>"
            }
        }
        // Inline math $...$ (not $$)
        if contains(text, 0x24) {  // "$"
            text = replace(text, regex: mathRegex) { match in
                "<span class=\"math-inline\">\(escape(match[1]))</span>"
            }
        }
        if contains(text, 0x60) {  // "`"
            text = replace(text, regex: codeRegex) { match in
                "<code>\(escape(match[1]))</code>"
            }
        }
        if contains(text, 0x2A) {  // "*"
            text = replace(text, regex: strongStarRegex) { match in
                "<strong>\(escape(match[1]))</strong>"
            }
        }
        if contains(text, 0x5F) {  // "_"
            text = replace(text, regex: strongUnderscoreRegex) { match in
                "<strong>\(escape(match[1]))</strong>"
            }
        }
        if contains(text, 0x2A) {  // "*"
            text = replace(text, regex: emRegex) { match in
                "<em>\(escape(match[1]))</em>"
            }
        }
        if contains(text, 0x7E) {  // "~"
            text = replace(text, regex: delRegex) { match in
                "<del>\(escape(match[1]))</del>"
            }
        }
        // Escape leftovers that aren't already tags. Unconditional: every path
        // above either matched and escaped its own captures, or left the text
        // untouched for this pass to escape.
        return escapeLoose(text)
    }

    private static func replace(_ text: String, regex: RegexBox, transform: ([String]) -> String) -> String {
        let ns = text as NSString
        let matches = regex.value.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return text }
        // Slice out of the native Swift string rather than the bridged
        // NSString: `ns.substring(with:)` allocates an NSString and then a
        // second buffer to bridge it back, while short native slices often fit
        // in the inline small-string form and allocate nothing. The bridged
        // path stays as an exact fallback for the one case native slicing
        // cannot express: an NSRange whose edge falls inside a grapheme
        // cluster, which `Range(_:in:)` refuses.
        func slice(_ range: NSRange) -> String {
            if let converted = Range(range, in: text) { return String(text[converted]) }
            return ns.substring(with: range)
        }
        var result = ""
        result.reserveCapacity(text.count + 16)
        var cursor = 0
        for match in matches {
            result += slice(NSRange(location: cursor, length: match.range.location - cursor))
            var groups = [String]()
            groups.reserveCapacity(match.numberOfRanges)
            for i in 0..<match.numberOfRanges {
                let range = match.range(at: i)
                groups.append(range.location == NSNotFound ? "" : slice(range))
            }
            result += transform(groups)
            cursor = match.range.location + match.range.length
        }
        result += slice(NSRange(location: cursor, length: ns.length - cursor))
        return result
    }

    public static func escape(_ string: String) -> String {
        // Single pass, single output buffer: the old four chained
        // replacingOccurrences calls allocated a full copy per pass.
        var result = ""
        result.reserveCapacity(string.count + string.count / 8)
        var i = string.startIndex
        while i < string.endIndex {
            switch string[i] {
            case "&": result.append("&amp;")
            case "<": result.append("&lt;")
            case ">": result.append("&gt;")
            case "\"": result.append("&quot;")
            default: result.append(string[i])
            }
            i = string.index(after: i)
        }
        return result
    }

    /// Escape text outside of already-emitted tags.
    private static func escapeLoose(_ string: String) -> String {
        // Single pass like `escape`, but raw tag runs (<...>) pass through
        // untouched. The old per-character `escape(String(string[i]))`
        // allocated a String per character.
        var result = ""
        result.reserveCapacity(string.count + 16)
        var i = string.startIndex
        while i < string.endIndex {
            if string[i] == "<", let close = string[i...].firstIndex(of: ">") {
                result.append(contentsOf: string[i...close])
                i = string.index(after: close)
            } else {
                switch string[i] {
                case "&": result.append("&amp;")
                case "<": result.append("&lt;")
                case ">": result.append("&gt;")
                case "\"": result.append("&quot;")
                default: result.append(string[i])
                }
                i = string.index(after: i)
            }
        }
        return result
    }
}
